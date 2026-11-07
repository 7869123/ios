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

/// Local-only wallpaper: a downscaled JPEG in Application Support plus layout in UserDefaults.
@Observable @MainActor final class WallpaperStore {
    private(set) var image: UIImage?
    private(set) var layout = WallpaperLayout()
    /// White overlay opacity over the wallpaper, keeps text readable.
    private(set) var scrim: Double = 0.55
    static let scrimRange: ClosedRange<Double> = 0.2...0.85

    private let defaults = UserDefaults.standard

    init() {
        if let data = try? Data(contentsOf: Self.fileURL) { image = UIImage(data: data) }
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

    func remove() {
        try? FileManager.default.removeItem(at: Self.fileURL)
        image = nil
        layout = WallpaperLayout()
        for key in [Keys.focusX, Keys.focusY, Keys.zoom] { defaults.removeObject(forKey: key) }
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
