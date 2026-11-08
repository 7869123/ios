import Foundation
import AIUtilityMedia

extension ImageOutputFormat {
    init?(typeIdentifier: String) {
        switch typeIdentifier {
        case "public.png": self = .png
        case "public.jpeg": self = .jpeg
        default: return nil
        }
    }
}

#if canImport(ImageIO) && canImport(CoreGraphics)
import CoreGraphics
import ImageIO

/// Joins images in input order after applying each image's orientation. Inputs are never modified;
/// only one decoded input is held at a time next to the output canvas.
public func stitchImages(_ images: [Data], options: StitchOptions = .init()) async throws(MediaError) -> ImageResult {
    try ProcessingValidation.check(options, imageCount: images.count)
    let totalBytes = images.reduce(Int64(0)) { $0 + Int64($1.count) }
    guard totalBytes <= options.limits.maxInputBytes else { throw .resourceLimitExceeded }

    var sources: [ImageIOSupport.Source] = []
    for data in images {
        guard !Task.isCancelled else { throw .cancelled }
        sources.append(try ImageIOSupport.open(data, limits: options.limits))
    }
    let geometry = try StitchGeometry.layout(sizes: sources.map { (width: $0.width, height: $0.height) },
                                             layout: options.layout, spacing: options.spacing)
    try ImageIOSupport.checkPixels(width: geometry.width, height: geometry.height, limits: options.limits)
    let context = try ImageIOSupport.context(width: geometry.width, height: geometry.height, background: options.background)
    for (source, frame) in zip(sources, geometry.frames) {
        guard !Task.isCancelled else { throw .cancelled }
        let image = try ImageIOSupport.orientedImage(source)
        // Core Graphics has a bottom-left origin.
        context.draw(image, in: CGRect(x: frame.x, y: geometry.height - frame.y - frame.height,
                                       width: frame.width, height: frame.height))
    }
    guard let canvas = context.makeImage() else { throw .resourceLimitExceeded }
    let data = try ImageIOSupport.encode(canvas, type: options.format.typeIdentifier,
                                         quality: options.format == .jpeg ? options.jpegQuality : nil)
    guard !Task.isCancelled else { throw .cancelled }
    guard Int64(data.count) <= options.limits.maxOutputBytes else { throw .resourceLimitExceeded }
    return ImageResult(data: data, format: options.format, width: geometry.width, height: geometry.height)
}

/// Produces new image bytes; the input `Data` is a value and is never changed. Results report honestly
/// whether bytes changed and whether removable metadata was actually removed.
public func rewriteFingerprint(_ image: Data, options: FingerprintOptions) async throws(MediaError) -> FingerprintResult {
    try ProcessingValidation.check(options, inputBytes: image.count)
    let source = try ImageIOSupport.open(image, limits: options.limits)
    let hadMetadata = MetadataInspector.hasRemovableMetadata(source.cgSource)
    let output: Data
    let outputType: String
    switch options.method {
    case .stripMetadata:
        output = try ImageIOSupport.losslessStrip(source)
        outputType = source.typeIdentifier
        // Never report a strip that left identifying metadata behind.
        guard let check = CGImageSourceCreateWithData(output as CFData, nil),
              !MetadataInspector.hasRemovableMetadata(check) else { throw .unsupportedFormat }
    case .reencode:
        let format = options.format ?? ImageOutputFormat(typeIdentifier: source.typeIdentifier) ?? .png
        let decoded = try ImageIOSupport.orientedImage(source)
        output = try ImageIOSupport.encode(decoded, type: format.typeIdentifier,
                                           quality: format == .jpeg ? options.jpegQuality : nil)
        outputType = format.typeIdentifier
    case .subtlePixelNoise:
        let format = options.format ?? .png
        let decoded = try ImageIOSupport.orientedImage(source)
        let noisy = try PixelNoise.apply(to: decoded, seed: options.noiseSeed)
        output = try ImageIOSupport.encode(noisy, type: format.typeIdentifier,
                                           quality: format == .jpeg ? options.jpegQuality : nil)
        outputType = format.typeIdentifier
    }
    guard !Task.isCancelled else { throw .cancelled }
    guard !output.isEmpty, Int64(output.count) <= options.limits.maxOutputBytes else { throw .resourceLimitExceeded }
    let stillHasMetadata = CGImageSourceCreateWithData(output as CFData, nil).map(MetadataInspector.hasRemovableMetadata) ?? true
    return FingerprintResult(data: output, typeIdentifier: outputType, bytesChanged: output != image,
                             metadataRemoved: hadMetadata && !stillHasMetadata)
}

enum ImageIOSupport {
    struct Source {
        let cgSource: CGImageSource
        /// Oriented (display) size.
        let width: Int
        let height: Int
        let orientation: Int
        let typeIdentifier: String
    }

    static func open(_ data: Data, limits: MediaProcessingLimits) throws(MediaError) -> Source {
        guard !data.isEmpty else { throw .invalidInput }
        guard Int64(data.count) <= limits.maxInputBytes else { throw .resourceLimitExceeded }
        let noCache = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, noCache),
              CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source) as String?,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, noCache) as? [CFString: Any],
              let rawW = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let rawH = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              rawW > 0, rawH > 0
        else { throw .unsupportedFormat }
        try checkPixels(width: rawW, height: rawH, limits: limits)
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swapped = (5...8).contains(orientation)
        return Source(cgSource: source, width: swapped ? rawH : rawW, height: swapped ? rawW : rawH,
                      orientation: (1...8).contains(orientation) ? orientation : 1, typeIdentifier: type)
    }

    static func checkPixels(width: Int, height: Int, limits: MediaProcessingLimits) throws(MediaError) {
        let pixels = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !pixels.overflow, pixels.partialValue <= limits.maxPixels else {
            throw .resourceLimitExceeded
        }
    }

    /// Full-size decode with the EXIF orientation applied (ImageIO's own transform, no size cap).
    static func orientedImage(_ source: Source) throws(MediaError) -> CGImage {
        let image: CGImage?
        if source.orientation == 1 {
            image = CGImageSourceCreateImageAtIndex(source.cgSource, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        } else {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceShouldCacheImmediately: true]
            image = CGImageSourceCreateThumbnailAtIndex(source.cgSource, 0, options as CFDictionary)
        }
        guard let image, image.width == source.width, image.height == source.height else { throw .unsupportedFormat }
        return image
    }

    static func context(width: Int, height: Int, background: RGBAColor?) throws(MediaError) -> CGContext {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw .resourceLimitExceeded }
        context.interpolationQuality = .high
        if let background {
            context.setFillColor(CGColor(srgbRed: background.red, green: background.green,
                                         blue: background.blue, alpha: background.alpha))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return context
    }

    /// Encodes a decoded image; only the properties given here are written (no source metadata).
    static func encode(_ image: CGImage, type: String, quality: Double?) throws(MediaError) -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, type as CFString, 1, nil)
        else { throw .unsupportedFormat }
        var properties: [CFString: Any] = [:]
        if let quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw .unsupportedFormat }
        return output as Data
    }

    /// Container-level copy without re-encoding pixels: metadata replaced by an empty set that keeps
    /// only the orientation needed for correct display; GPS and XMP excluded. Formats ImageIO cannot
    /// copy losslessly fail with `.unsupportedFormat` instead of silently re-encoding.
    static func losslessStrip(_ source: Source) throws(MediaError) -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, source.typeIdentifier as CFString, 1, nil)
        else { throw .unsupportedFormat }
        let metadata = CGImageMetadataCreateMutable()
        if source.orientation != 1 {
            _ = CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary,
                                                             kCGImagePropertyTIFFOrientation,
                                                             NSNumber(value: source.orientation))
        }
        let options: [CFString: Any] = [kCGImageDestinationMetadata: metadata,
                                        kCGImageDestinationMergeMetadata: false,
                                        kCGImageMetadataShouldExcludeGPS: true,
                                        kCGImageMetadataShouldExcludeXMP: true]
        // CGImageDestinationCopyImageSource writes the destination itself; Finalize must not be called.
        guard CGImageDestinationCopyImageSource(destination, source.cgSource, options as CFDictionary, nil),
              output.length > 0 else { throw .unsupportedFormat }
        return output as Data
    }
}

/// Detects metadata that can identify a person, device, place or time. Purely technical fields that
/// ImageIO writes itself (pixel dimensions, colour space, orientation) are not counted.
enum MetadataInspector {
    private static let identifyingKeys: [String: Set<String>] = [
        "{Exif}": ["DateTimeOriginal", "DateTimeDigitized", "SubsecTimeOriginal", "SubsecTimeDigitized",
                   "OffsetTime", "OffsetTimeOriginal", "OffsetTimeDigitized", "UserComment", "MakerNote",
                   "CameraOwnerName", "BodySerialNumber", "LensMake", "LensModel", "LensSerialNumber",
                   "ImageUniqueID", "LensSpecification"],
        "{TIFF}": ["Make", "Model", "Software", "Artist", "Copyright", "DateTime", "HostComputer", "ImageDescription"],
        "{PNG}": ["Author", "Comment", "Copyright", "CreationTime", "Description", "Disclaimer", "Software", "Source",
                  "Title", "Warning"],
    ]
    /// Dictionaries whose mere presence (non-empty) counts as identifying metadata.
    private static let wholeDictionaries = ["{GPS}", "{IPTC}", "{ExifAux}", "{MakerApple}", "{MakerCanon}",
                                            "{MakerNikon}", "{MakerMinolta}", "{MakerFuji}", "{MakerOlympus}",
                                            "{MakerPentax}", "{CIFF}", "{8BIM}", "{DNG}"]

    static func hasRemovableMetadata(_ source: CGImageSource) -> Bool {
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return false }
        for name in wholeDictionaries {
            if let dictionary = properties[name] as? [String: Any], !dictionary.isEmpty { return true }
        }
        for (name, keys) in identifyingKeys {
            if let dictionary = properties[name] as? [String: Any], !keys.isDisjoint(with: dictionary.keys) { return true }
        }
        // Any XMP tag beyond orientation (for example a description or creator).
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
           let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] {
            for tag in tags {
                let name = CGImageMetadataTagCopyName(tag) as String? ?? ""
                let prefix = CGImageMetadataTagCopyPrefix(tag) as String? ?? ""
                if prefix == "tiff" && name == "Orientation" { continue }
                if prefix == "exif" && ["PixelXDimension", "PixelYDimension", "ColorSpace"].contains(name) { continue }
                if prefix == "tiff" && ["XResolution", "YResolution", "ResolutionUnit"].contains(name) { continue }
                if ["xmp", "dc", "photoshop", "Iptc4xmpCore", "exifEX", "aux", "xmpRights", "xmpMM"].contains(prefix) { return true }
            }
        }
        return false
    }
}

/// Deterministic ±1 changes to one colour channel of about one pixel in eight; alpha untouched and
/// premultiplied values kept within alpha. Fully transparent pixels stay unchanged.
enum PixelNoise {
    static func apply(to image: CGImage, seed: UInt64) throws(MediaError) -> CGImage {
        let width = image.width, height = image.height
        let context = try ImageIOSupport.context(width: width, height: height, background: nil)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let base = context.data else { throw .resourceLimitExceeded }
        let rowBytes = context.bytesPerRow
        let pixels = base.bindMemory(to: UInt8.self, capacity: rowBytes * height)
        var random = SplitMix64(seed: seed)
        for row in 0..<height {
            if row % 64 == 0, Task.isCancelled { throw .cancelled }
            for column in 0..<width {
                let value = random.next()
                guard value & 7 == 0 else { continue }
                let offset = row * rowBytes + column * 4
                let alpha = pixels[offset + 3]
                let index = offset + Int((value >> 3) % 3)
                let current = pixels[index]
                let up = (value >> 8) & 1 == 1
                if up, current < alpha { pixels[index] = current + 1 }
                else if current > 0 { pixels[index] = current - 1 }
                else if current < alpha { pixels[index] = current + 1 }
            }
        }
        guard let result = context.makeImage() else { throw .resourceLimitExceeded }
        return result
    }
}

#else

public func stitchImages(_ images: [Data], options: StitchOptions = .init()) async throws(MediaError) -> ImageResult {
    try ProcessingValidation.check(options, imageCount: images.count)
    throw .unsupportedPlatform
}

public func rewriteFingerprint(_ image: Data, options: FingerprintOptions) async throws(MediaError) -> FingerprintResult {
    try ProcessingValidation.check(options, inputBytes: image.count)
    throw .unsupportedPlatform
}

#endif
