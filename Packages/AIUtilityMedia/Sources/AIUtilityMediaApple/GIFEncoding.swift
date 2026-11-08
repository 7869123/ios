#if canImport(ImageIO) && canImport(CoreGraphics)
import Foundation
import CoreGraphics
import ImageIO
import AIUtilityMedia

/// Sequential GIF writer shared by `makeGIF(fromVideo:)` and the later Ugoira assembly: frames are
/// appended one at a time, each with its own delay in whole centiseconds. Delays a GIF cannot show
/// faithfully (under 2 cs, which viewers stretch) are rejected with `.unsupportedFormat` rather than
/// silently changed. The frame count is fixed up front, as ImageIO requires.
final class GIFFileEncoder {
    let url: URL
    private let destination: CGImageDestination
    private let expectedFrames: Int
    private(set) var delays: [Int] = []

    init(url: URL, frameCount: Int, loopCount: Int) throws(MediaError) {
        guard frameCount > 0, loopCount >= 0 else { throw .invalidInput }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, frameCount, nil)
        else { throw .storageUnavailable }
        let fileProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loopCount]] as CFDictionary
        CGImageDestinationSetProperties(destination, fileProperties)
        self.url = url; self.destination = destination; self.expectedFrames = frameCount
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

    func finish() throws(MediaError) {
        guard delays.count == expectedFrames else { throw .invalidState }
        guard CGImageDestinationFinalize(destination) else { throw .storageUnavailable }
    }
}

/// Reads a written GIF back so results report what the file really contains.
enum GIFInspector {
    struct Summary: Equatable {
        let frameCount: Int
        let delaysCentiseconds: [Int]
        let width: Int
        let height: Int
        var totalCentiseconds: Int { delaysCentiseconds.reduce(0, +) }
    }

    static func inspect(_ url: URL) -> Summary? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
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
#endif
