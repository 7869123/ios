import Foundation
import AIUtilityMedia

#if canImport(AVFoundation) && canImport(ImageIO) && canImport(CoreGraphics)
import AVFoundation
import CoreGraphics
import ImageIO

/// Converts a clip of a local video (already copied into the app sandbox by the UI) into a new GIF in
/// `outputDirectory`. Frames are taken at exactly `start + n / fps` with the track's orientation
/// applied, scaled down to `maxWidth` (never up), without audio. The input file is only read.
/// On error or cancellation the partial file is removed and no result is returned.
public func makeGIF(fromVideo url: URL, outputDirectory: URL, options: GIFOptions) async throws(MediaError) -> GIFResult {
    try ProcessingValidation.check(options)
    guard url.isFileURL, outputDirectory.isFileURL else { throw .invalidURL }
    let inputValues = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard inputValues?.isRegularFile == true, let inputSize = inputValues?.fileSize else { throw .notFound }
    guard Int64(inputSize) <= options.limits.maxInputBytes else { throw .resourceLimitExceeded }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: outputDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue
    else { throw .storageUnavailable }

    let asset = AVURLAsset(url: url)
    let clipEnd = options.start + options.duration
    let pixelSize: (width: Int, height: Int)
    do {
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, clipEnd <= duration + 0.001 else { throw MediaError.invalidInput }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw MediaError.unsupportedFormat }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let oriented = CGRect(origin: .zero, size: natural).applying(transform)
        let width = Double(abs(oriented.width)), height = Double(abs(oriented.height))
        guard width >= 1, height >= 1 else { throw MediaError.unsupportedFormat }
        let scale = min(1, Double(options.maxWidth) / width)
        pixelSize = (max(1, Int((width * scale).rounded())), max(1, Int((height * scale).rounded())))
    } catch let error as MediaError {
        throw error
    } catch {
        throw Task.isCancelled ? .cancelled : .unsupportedFormat
    }
    try ImageIOSupport.checkPixels(width: pixelSize.width, height: pixelSize.height, limits: options.limits)

    let plan = GIFTimeline.plan(duration: options.duration, fps: options.fps)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    generator.maximumSize = CGSize(width: pixelSize.width, height: pixelSize.height)

    let name = UUID().uuidString.lowercased()
    let partial = outputDirectory.appendingPathComponent(".\(name).gif.partial")
    let finalURL = outputDirectory.appendingPathComponent("\(name).gif")
    do {
        try await encodeFrames(generator: generator, plan: plan, options: options, size: pixelSize, to: partial)
        guard !Task.isCancelled else { throw MediaError.cancelled }

        // Report what the file really holds, not what was requested.
        guard let summary = GIFInspector.inspect(partial),
              summary.frameCount == plan.count,
              summary.delaysCentiseconds == plan.map(\.delayCentiseconds),
              summary.width == pixelSize.width, summary.height == pixelSize.height
        else { throw MediaError.unsupportedFormat }
        let bytes = Int64((try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard bytes > 0 else { throw MediaError.outputMissing }
        guard bytes <= options.limits.maxOutputBytes else { throw MediaError.resourceLimitExceeded }
        do { try FileManager.default.moveItem(at: partial, to: finalURL) } catch { throw MediaError.storageUnavailable }
        return GIFResult(url: finalURL, bytes: bytes, width: summary.width, height: summary.height,
                         frameCount: summary.frameCount, totalDuration: Double(summary.totalCentiseconds) / 100)
    } catch {
        try? FileManager.default.removeItem(at: partial)
        throw (error as? MediaError) ?? .storageUnavailable
    }
}

/// Encodes every planned frame into `url`. The encoder lives only inside this function, so it is
/// released before the caller cleans up: an unfinished ImageIO destination can still write its file
/// when it is deallocated, which would otherwise leave a partial GIF behind after cancellation.
private func encodeFrames(generator: AVAssetImageGenerator, plan: [GIFTimeline.Frame], options: GIFOptions,
                          size: (width: Int, height: Int), to url: URL) async throws(MediaError) {
    let encoder = try GIFFileEncoder(url: url, frameCount: plan.count, loopCount: options.loopCount)
    for frame in plan {
        guard !Task.isCancelled else { throw .cancelled }
        let time = CMTime(seconds: options.start + frame.offset, preferredTimescale: 600)
        let image: CGImage
        do { image = try await generator.image(at: time).image }
        catch { throw Task.isCancelled ? .cancelled : .unsupportedFormat }
        try encoder.append(try fitted(image, to: size), delayCentiseconds: frame.delayCentiseconds)
    }
    try encoder.finish()
}

/// Redraws a frame at exactly the output size when the generator's rounding differs.
private func fitted(_ image: CGImage, to size: (width: Int, height: Int)) throws(MediaError) -> CGImage {
    if image.width == size.width, image.height == size.height { return image }
    let context = try ImageIOSupport.context(width: size.width, height: size.height, background: nil)
    context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
    guard let result = context.makeImage() else { throw .resourceLimitExceeded }
    return result
}

#else

public func makeGIF(fromVideo url: URL, outputDirectory: URL, options: GIFOptions) async throws(MediaError) -> GIFResult {
    try ProcessingValidation.check(options)
    throw .unsupportedPlatform
}

#endif
