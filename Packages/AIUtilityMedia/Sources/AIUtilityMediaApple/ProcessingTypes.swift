import Foundation
import AIUtilityMedia

// P2 local media tools: value types shared by every platform. The implementations live behind
// `canImport(ImageIO)` / `canImport(AVFoundation)`; other platforms throw `.unsupportedPlatform`
// instead of returning empty or fake output.

/// Order is always the input order: vertical top to bottom, horizontal left to right,
/// grid row by row from left to right.
public enum StitchLayout: Sendable, Hashable {
    case vertical, horizontal, grid(columns: Int)
}

public enum ImageOutputFormat: String, Sendable, Hashable, CaseIterable {
    case png, jpeg
    var typeIdentifier: String { self == .png ? "public.png" : "public.jpeg" }
}

/// Straight (non-premultiplied) sRGB colour, each component 0...1.
public struct RGBAColor: Sendable, Hashable {
    public var red: Double, green: Double, blue: Double, alpha: Double
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
    public static let white = RGBAColor(red: 1, green: 1, blue: 1)
    public static let clear = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)
    var isValid: Bool { [red, green, blue, alpha].allSatisfy { $0.isFinite && (0...1).contains($0) } }
}

/// Upper bounds checked before any large allocation. Defaults suit an iPad-class device; callers
/// may lower them. Exceeding one fails with `.resourceLimitExceeded` instead of truncating.
public struct MediaProcessingLimits: Sendable, Hashable {
    /// Total bytes of all encoded inputs (images) or of the input video file.
    public var maxInputBytes: Int64
    public var maxImageCount: Int
    /// Pixels of any single decoded image and of the output canvas or GIF frame.
    public var maxPixels: Int
    public var maxOutputBytes: Int64
    public var maxGIFFrames: Int
    public var maxGIFDuration: Double
    public init(maxInputBytes: Int64 = 200 * 1024 * 1024, maxImageCount: Int = 32, maxPixels: Int = 80_000_000,
                maxOutputBytes: Int64 = 200 * 1024 * 1024, maxGIFFrames: Int = 600, maxGIFDuration: Double = 60) {
        self.maxInputBytes = maxInputBytes; self.maxImageCount = maxImageCount; self.maxPixels = maxPixels
        self.maxOutputBytes = maxOutputBytes; self.maxGIFFrames = maxGIFFrames; self.maxGIFDuration = maxGIFDuration
    }
}

public struct StitchOptions: Sendable, Hashable {
    public var layout: StitchLayout
    /// Gap between images in output pixels; must be >= 0.
    public var spacing: Int
    public var background: RGBAColor
    public var format: ImageOutputFormat
    /// JPEG only, 0...1.
    public var jpegQuality: Double
    public var limits: MediaProcessingLimits
    public init(layout: StitchLayout = .vertical, spacing: Int = 0, background: RGBAColor = .white,
                format: ImageOutputFormat = .png, jpegQuality: Double = 0.92, limits: MediaProcessingLimits = .init()) {
        self.layout = layout; self.spacing = spacing; self.background = background
        self.format = format; self.jpegQuality = jpegQuality; self.limits = limits
    }
}

public struct ImageResult: Sendable, Hashable {
    public let data: Data
    public let format: ImageOutputFormat
    public let width: Int
    public let height: Int
}

public struct GIFOptions: Sendable, Hashable {
    /// Clip start in seconds (>= 0) and length (> 0); the clip must lie inside the video.
    public var start: Double
    public var duration: Double
    /// Frames per second. GIF delays are whole centiseconds; frame times stay on the true
    /// `start + n / fps` timeline and each delay is the difference of rounded timestamps.
    public var fps: Int
    /// Output width cap in pixels; smaller videos are never upscaled.
    public var maxWidth: Int
    /// 0 = loop forever.
    public var loopCount: Int
    public var limits: MediaProcessingLimits
    public init(start: Double = 0, duration: Double, fps: Int = 10, maxWidth: Int = 480, loopCount: Int = 0,
                limits: MediaProcessingLimits = .init()) {
        self.start = start; self.duration = duration; self.fps = fps
        self.maxWidth = maxWidth; self.loopCount = loopCount; self.limits = limits
    }
}

public struct GIFResult: Sendable, Hashable {
    /// New file inside the requested output directory; the input video is never touched.
    public let url: URL
    public let bytes: Int64
    public let width: Int
    public let height: Int
    /// Read back from the written file, not taken from the request.
    public let frameCount: Int
    public let totalDuration: Double
}

public enum FingerprintMethod: Sendable, Hashable {
    /// Decode (applying orientation) and encode again; bytes change, pixels may change slightly for JPEG.
    case reencode
    /// Lossless container copy without EXIF/GPS/IPTC/XMP; pixels are not re-encoded.
    case stripMetadata
    /// Small deterministic noise on pixel values; requires `allowPixelChanges`.
    case subtlePixelNoise
}

public struct FingerprintOptions: Sendable, Hashable {
    public var method: FingerprintMethod
    /// nil keeps the input's format when it can be written (PNG/JPEG), otherwise PNG.
    /// Ignored by `.stripMetadata`, which always keeps the container format.
    public var format: ImageOutputFormat?
    public var jpegQuality: Double
    public var allowPixelChanges: Bool
    /// Seed for `.subtlePixelNoise`, so results are reproducible.
    public var noiseSeed: UInt64
    public var limits: MediaProcessingLimits
    public init(method: FingerprintMethod, format: ImageOutputFormat? = nil, jpegQuality: Double = 0.92,
                allowPixelChanges: Bool = false, noiseSeed: UInt64 = 0x5EED, limits: MediaProcessingLimits = .init()) {
        self.method = method; self.format = format; self.jpegQuality = jpegQuality
        self.allowPixelChanges = allowPixelChanges; self.noiseSeed = noiseSeed; self.limits = limits
    }
}

public struct FingerprintResult: Sendable, Hashable {
    public let data: Data
    /// Container type identifier of the output, e.g. "public.jpeg".
    public let typeIdentifier: String
    /// False when the output is byte-identical to the input (already normalised); not an error.
    public let bytesChanged: Bool
    /// True only when the input carried removable metadata and the output no longer does.
    public let metadataRemoved: Bool
}

// MARK: - Validation shared by all platforms

enum ProcessingValidation {
    static func check(_ options: StitchOptions, imageCount: Int) throws(MediaError) {
        guard imageCount > 0, options.spacing >= 0, options.background.isValid,
              (0...1).contains(options.jpegQuality) else { throw .invalidInput }
        if case .grid(let columns) = options.layout, columns <= 0 { throw .invalidInput }
        guard imageCount <= options.limits.maxImageCount else { throw .resourceLimitExceeded }
    }

    static func check(_ options: GIFOptions) throws(MediaError) {
        guard options.start.isFinite, options.duration.isFinite, options.start >= 0, options.duration > 0,
              options.fps > 0, options.fps <= 50, options.maxWidth > 0, options.loopCount >= 0 else { throw .invalidInput }
        guard options.duration <= options.limits.maxGIFDuration,
              GIFTimeline.plan(duration: options.duration, fps: options.fps).count <= options.limits.maxGIFFrames
        else { throw .resourceLimitExceeded }
        // A clip shorter than 0.02 s cannot be expressed as a GIF frame.
        guard !GIFTimeline.plan(duration: options.duration, fps: options.fps).isEmpty else { throw .unsupportedFormat }
    }

    static func check(_ options: FingerprintOptions, inputBytes: Int) throws(MediaError) {
        guard inputBytes > 0, (0...1).contains(options.jpegQuality) else { throw .invalidInput }
        if options.method == .subtlePixelNoise, !options.allowPixelChanges { throw .invalidInput }
        guard Int64(inputBytes) <= options.limits.maxInputBytes else { throw .resourceLimitExceeded }
    }
}

/// Frame plan for a clip: offsets `n / fps` strictly before the clip end, each with a delay in whole
/// centiseconds taken from rounded cumulative timestamps, so frames stay on the true timeline and the
/// total equals the clip length (to 0.01 s). GIF viewers stretch delays under 2 cs, so a trailing frame
/// that would get less is dropped and its time given to the previous frame instead.
enum GIFTimeline {
    struct Frame: Equatable { let offset: Double; let delayCentiseconds: Int }

    static func plan(duration: Double, fps: Int) -> [Frame] {
        guard duration.isFinite, duration > 0, fps > 0 else { return [] }
        var offsets: [Double] = []
        var n = 0
        while true {
            let offset = Double(n) / Double(fps)
            // Tolerate floating error so 1.0 s at 10 fps gives 10 frames, not 11.
            if offset >= duration - 1e-9 { break }
            offsets.append(offset); n += 1
        }
        func cs(_ seconds: Double) -> Int { Int((seconds * 100).rounded()) }
        var frames: [Frame] = []
        for (index, offset) in offsets.enumerated() {
            let end = index + 1 < offsets.count ? offsets[index + 1] : duration
            frames.append(Frame(offset: offset, delayCentiseconds: cs(end) - cs(offset)))
        }
        while frames.count > 1, let last = frames.last, last.delayCentiseconds < 2 {
            frames.removeLast()
            let previous = frames.removeLast()
            frames.append(Frame(offset: previous.offset, delayCentiseconds: previous.delayCentiseconds + last.delayCentiseconds))
        }
        if frames.count == 1, frames[0].delayCentiseconds < 2 { return [] }
        return frames
    }
}

/// Deterministic SplitMix64, so pixel noise is reproducible for a given seed.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Pixel rectangle with a top-left origin.
struct PixelRect: Equatable, Sendable { let x: Int, y: Int, width: Int, height: Int }

/// Canvas size and per-image placement for `stitchImages`, using oriented pixel sizes.
/// vertical/horizontal centre each image across the other axis; grid uses cells of the largest
/// width and height and centres each image in its cell.
enum StitchGeometry {
    struct Layout: Equatable { let width: Int, height: Int; let frames: [PixelRect] }

    static func layout(sizes: [(width: Int, height: Int)], layout: StitchLayout, spacing: Int) throws(MediaError) -> Layout {
        guard !sizes.isEmpty, spacing >= 0, sizes.allSatisfy({ $0.width > 0 && $0.height > 0 }) else { throw .invalidInput }
        let maxW = sizes.map { $0.width }.max() ?? 0, maxH = sizes.map { $0.height }.max() ?? 0
        func add(_ a: Int, _ b: Int) throws(MediaError) -> Int {
            let sum = a.addingReportingOverflow(b)
            guard !sum.overflow else { throw .resourceLimitExceeded }
            return sum.partialValue
        }
        switch layout {
        case .vertical:
            var y = 0, frames: [PixelRect] = []
            for (index, size) in sizes.enumerated() {
                if index > 0 { y = try add(y, spacing) }
                frames.append(PixelRect(x: (maxW - size.width) / 2, y: y, width: size.width, height: size.height))
                y = try add(y, size.height)
            }
            return Layout(width: maxW, height: y, frames: frames)
        case .horizontal:
            var x = 0, frames: [PixelRect] = []
            for (index, size) in sizes.enumerated() {
                if index > 0 { x = try add(x, spacing) }
                frames.append(PixelRect(x: x, y: (maxH - size.height) / 2, width: size.width, height: size.height))
                x = try add(x, size.width)
            }
            return Layout(width: x, height: maxH, frames: frames)
        case .grid(let requested):
            guard requested > 0 else { throw .invalidInput }
            let columns = min(requested, sizes.count)
            let rows = (sizes.count + columns - 1) / columns
            let stepW = try add(maxW, spacing), stepH = try add(maxH, spacing)
            let width = columns.multipliedReportingOverflow(by: stepW)
            let height = rows.multipliedReportingOverflow(by: stepH)
            guard !width.overflow, !height.overflow else { throw .resourceLimitExceeded }
            var frames: [PixelRect] = []
            for (index, size) in sizes.enumerated() {
                frames.append(PixelRect(x: (index % columns) * stepW + (maxW - size.width) / 2,
                                        y: (index / columns) * stepH + (maxH - size.height) / 2,
                                        width: size.width, height: size.height))
            }
            return Layout(width: width.partialValue - spacing, height: height.partialValue - spacing, frames: frames)
        }
    }
}
