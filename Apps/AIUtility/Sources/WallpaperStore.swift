import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers
import Observation

/// Where the wallpaper sits: the image point (focusX, focusY in 0...1) placed at the container centre,
/// scaled to aspect-fill the container times `zoom`, and always clamped so the image covers the container.
/// Stored as fractions so one setting adapts to portrait, landscape and split-view sizes.
struct WallpaperLayout: Equatable, Sendable {
    var focusX: Double = 0.5
    var focusY: Double = 0.5
    var zoom: Double = 1
    static let zoomRange: ClosedRange<Double> = 1...4

    func imageFrame(imageSize: CGSize, container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let scale = max(container.width / imageSize.width, container.height / imageSize.height) * zoom
        let width = imageSize.width * scale, height = imageSize.height * scale
        let x = min(0, max(container.width - width, container.width / 2 - focusX * width))
        let y = min(0, max(container.height - height, container.height / 2 - focusY * height))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Moves the image by a translation in container points.
    func dragged(by translation: CGSize, imageSize: CGSize, container: CGSize) -> WallpaperLayout {
        let frame = imageFrame(imageSize: imageSize, container: container)
        guard frame.width > 0, frame.height > 0 else { return self }
        var next = self
        next.focusX = (container.width / 2 - frame.minX - translation.width) / frame.width
        next.focusY = (container.height / 2 - frame.minY - translation.height) / frame.height
        return next.clamped(imageSize: imageSize, container: container)
    }

    func zoomed(to value: Double, imageSize: CGSize, container: CGSize) -> WallpaperLayout {
        var next = self
        next.zoom = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, value))
        return next.clamped(imageSize: imageSize, container: container)
    }

    /// Keeps the focus inside the range where the image still covers the container.
    func clamped(imageSize: CGSize, container: CGSize) -> WallpaperLayout {
        guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else { return self }
        let scale = max(container.width / imageSize.width, container.height / imageSize.height) * zoom
        let halfW = container.width / 2 / (imageSize.width * scale)
        let halfH = container.height / 2 / (imageSize.height * scale)
        var next = self
        next.focusX = min(1 - halfW, max(halfW, focusX))
        next.focusY = min(1 - halfH, max(halfH, focusY))
        return next
    }
}

enum WallpaperError: Error {
    case unreadable, encodeFailed
}

enum WallpaperMode: String, Sendable {
    /// User-chosen image stored locally.
    case custom
    /// Bundled DefaultWallpaper.jpg (user-supplied 2026-11-07, see UIUX_SPEC.md for usage limits).
    case bundled
    /// Plain designed backdrop, no image.
    case plain
}

/// Wallpaper state: custom image (local JPEG in Application Support), bundled default, or none.
/// Layout and scrim live in UserDefaults.
@Observable @MainActor final class WallpaperStore {
    private(set) var mode: WallpaperMode = .bundled
    private(set) var image: UIImage?
    private(set) var layout = WallpaperLayout()
    /// White overlay opacity over the wallpaper, keeps text readable.
    private(set) var scrim: Double = 0.55
    static let scrimRange: ClosedRange<Double> = 0.2...0.85
    /// Keeps the bundled illustration's face in frame in both orientations.
    static let bundledLayout = WallpaperLayout(focusX: 0.5, focusY: 0.33, zoom: 1)
    static let bundledScrim = 0.35

    private let defaults = UserDefaults.standard

    var hasBundledDefault: Bool { Self.bundledURL != nil }
    private static let bundledURL = Bundle.main.url(forResource: "DefaultWallpaper", withExtension: "jpg")

    init() {
        let stored = defaults.string(forKey: Keys.mode).flatMap(WallpaperMode.init(rawValue:))
        let customImage = (try? Data(contentsOf: Self.fileURL)).flatMap(UIImage.init(data:))
        switch stored {
        case .custom? where customImage != nil, nil where customImage != nil:
            mode = .custom; image = customImage
        case .plain?: mode = .plain
        default:
            // First launch, or custom file missing: fall back to the bundled default if present.
            if let bundled = Self.bundledImage() {
                mode = .bundled; image = bundled
                if stored != .bundled { layout = Self.bundledLayout; scrim = Self.bundledScrim; return }
            } else {
                mode = .plain
            }
        }
        if defaults.object(forKey: Keys.focusX) != nil {
            layout = WallpaperLayout(focusX: defaults.double(forKey: Keys.focusX),
                                     focusY: defaults.double(forKey: Keys.focusY),
                                     zoom: max(1, defaults.double(forKey: Keys.zoom)))
        }
        if defaults.object(forKey: Keys.scrim) != nil { scrim = defaults.double(forKey: Keys.scrim) }
    }

    /// Saves a newly chosen image (already prepared with `prepare`) with its layout.
    func save(imageData: Data, layout: WallpaperLayout, scrim: Double) throws {
        guard let decoded = UIImage(data: imageData) else { throw WallpaperError.unreadable }
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try imageData.write(to: Self.fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        image = decoded
        setMode(.custom)
        update(layout: layout, scrim: scrim)
    }

    func update(layout: WallpaperLayout, scrim: Double) {
        self.layout = layout
        self.scrim = min(Self.scrimRange.upperBound, max(Self.scrimRange.lowerBound, scrim))
        defaults.set(layout.focusX, forKey: Keys.focusX)
        defaults.set(layout.focusY, forKey: Keys.focusY)
        defaults.set(layout.zoom, forKey: Keys.zoom)
        defaults.set(self.scrim, forKey: Keys.scrim)
    }

    /// Deletes any custom image and shows the bundled default (or the plain backdrop if none is bundled).
    func restoreDefault() {
        try? FileManager.default.removeItem(at: Self.fileURL)
        if let bundled = Self.bundledImage() {
            image = bundled
            setMode(.bundled)
            update(layout: Self.bundledLayout, scrim: Self.bundledScrim)
        } else {
            usePlainBackdrop()
        }
    }

    /// Plain designed backdrop; deletes any custom image.
    func usePlainBackdrop() {
        try? FileManager.default.removeItem(at: Self.fileURL)
        image = nil
        setMode(.plain)
    }

    private func setMode(_ mode: WallpaperMode) {
        self.mode = mode
        defaults.set(mode.rawValue, forKey: Keys.mode)
    }

    private static func bundledImage() -> UIImage? {
        bundledURL
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap(UIImage.init(data:))
    }

    /// Decodes any ImageIO-supported image (JPEG, PNG, HEIC…), applies EXIF orientation, downsizes the
    /// long edge to `maxPixel` and re-encodes as JPEG. Metadata such as GPS is not copied.
    nonisolated static func prepare(_ data: Data, maxPixel: Int = 3000) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw WallpaperError.unreadable }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw WallpaperError.unreadable }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw WallpaperError.encodeFailed }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw WallpaperError.encodeFailed }
        return output as Data
    }

    private enum Keys {
        static let focusX = "wallpaper.focusX", focusY = "wallpaper.focusY", zoom = "wallpaper.zoom", scrim = "wallpaper.scrim"
        static let mode = "wallpaper.mode"
    }
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Wallpaper", isDirectory: true)
    }
    private static var fileURL: URL { directory.appendingPathComponent("wallpaper.jpg") }
}

/// Current window size (follows rotation, Split View and Stage Manager).
@MainActor enum WindowMetrics {
    static var size: CGSize {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.windows.first?.bounds.size ?? scene?.screen.bounds.size ?? CGSize(width: 744, height: 1133)
    }
}

/// Draws the wallpaper laid out for `container`.
struct WallpaperCanvas: View {
    let image: UIImage
    let layout: WallpaperLayout
    let container: CGSize
    var body: some View {
        let frame = layout.imageFrame(imageSize: image.size, container: container)
        Image(uiImage: image)
            .resizable()
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
            .frame(width: container.width, height: container.height, alignment: .topLeading)
            .clipped()
    }
}

/// Wallpaper laid out against the whole window, then cut to this view's position, so every page
/// (and the iPad detail column) shows the same window-aligned picture the editor previewed.
struct WindowAlignedWallpaper: View {
    let image: UIImage
    let layout: WallpaperLayout
    let scrim: Double
    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            let window = WindowMetrics.size
            ZStack(alignment: .topLeading) {
                WallpaperCanvas(image: image, layout: layout, container: window)
                    .offset(x: -frame.minX, y: -frame.minY)
                Color.white.opacity(scrim)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
        }
    }
}
