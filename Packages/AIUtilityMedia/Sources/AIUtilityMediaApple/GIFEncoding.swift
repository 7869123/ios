#if canImport(ImageIO) && canImport(CoreGraphics)
import Foundation
import CoreGraphics
import ImageIO
import AIUtilityMedia

/// Sequential GIF encoder shared by `makeGIF(fromVideo:)` and the later Ugoira assembly: frames are
/// appended one at a time, each with its own delay in whole centiseconds. Delays a GIF cannot show
/// faithfully (under 2 cs, which viewers stretch) are rejected with `.unsupportedFormat` rather than
/// silently changed. The frame count is fixed up front, as ImageIO requires.
///
/// Encodes into memory: nothing touches the disk until the caller writes the finished bytes, so a
/// cancelled or failed encode cannot leave a partial or temporary file behind (an unfinished ImageIO
/// file destination was observed leaving one in CI).
final class GIFEncoder {
    private let output = NSMutableData()
    private let destination: CGImageDestination
    private let expectedFrames: Int
    private(set) var delays: [Int] = []

    init(frameCount: Int, loopCount: Int) throws(MediaError) {
        guard frameCount > 0, loopCount >= 0 else { throw .invalidInput }
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, "com.compuserve.gif" as CFString,
                                                                 frameCount, nil)
        else { throw .unsupportedFormat }
        let fileProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loopCount]] as CFDictionary
        CGImageDestinationSetProperties(destination, fileProperties)
        self.destination = destination; self.expectedFrames = frameCount
    }

    func append(_ image: CGImage, delayCentiseconds: Int) throws(MediaError) {
        guard delayCentiseconds >= 2 else { throw .unsupportedFormat }
        guard delays.count < expectedFrames else { throw .invalidState }
        let seconds = Double(delayCentiseconds) / 100
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: seconds,
                                                               kCGImagePropertyGIFUnclampedDelayTime: seconds]] as CFDictionary
        CGImageDestinationAddImage(destination, image, frameProperties)
        delays.append(delayCentiseconds)
    }

    /// Finalises and returns the GIF bytes.
    func finish() throws(MediaError) -> Data {
        guard delays.count == expectedFrames else { throw .invalidState }
        guard CGImageDestinationFinalize(destination), output.length > 0 else { throw .unsupportedFormat }
        return output as Data
    }
}

/// Reads GIF bytes back so results report what the output really contains.
enum GIFInspector {
    struct Summary: Equatable {
        let frameCount: Int
        let delaysCentiseconds: [Int]
        let width: Int
        let height: Int
        var totalCentiseconds: Int { delaysCentiseconds.reduce(0, +) }
    }

    static func inspect(_ url: URL) -> Summary? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return inspect(data)
    }

    static func inspect(_ data: Data) -> Summary? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == "com.compuserve.gif" else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        var delays: [Int] = []
        var width = 0, height = 0
        for index in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] else { return nil }
            let delay = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
                ?? (gif[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue ?? 0
            delays.append(Int((delay * 100).rounded()))
            if index == 0 {
                width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
                height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            }
        }
        return Summary(frameCount: count, delaysCentiseconds: delays, width: width, height: height)
    }
}

/// Redraws a frame at exactly the output size when the generator's rounding differs.
func fitted(_ image: CGImage, to size: (width: Int, height: Int)) throws(MediaError) -> CGImage {
    if image.width == size.width, image.height == size.height { return image }
    let context = try ImageIOSupport.context(width: size.width, height: size.height, background: nil)
    context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
    guard let result = context.makeImage() else { throw .resourceLimitExceeded }
    return result
}
#endif
