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

/// Which appearance a wallpaper belongs to. Light and dark each keep their own image, layout and scrim.
enum WallpaperScheme: String, CaseIterable, Identifiable, Sendable {
    case light, dark
    var id: String { rawValue }
    var title: String { self == .light ? "浅色" : "深色" }
    init(_ colorScheme: ColorScheme) { self = colorScheme == .dark ? .dark : .light }
}

/// One appearance's wallpaper: custom image, bundled default or plain backdrop, plus layout and scrim.
struct WallpaperSlot {
    var mode: WallpaperMode
    var image: UIImage?
    var layout: WallpaperLayout
    var scrim: Double
}

/// Wallpaper state for light and dark appearance: custom image (local JPEG in Application Support),
/// bundled default (DefaultWallpaper / DefaultWallpaperNight), or none. Layout and scrim live in
/// UserDefaults. The light slot keeps the original keys and file name, so existing settings carry over.
/// Settings edit one slot at a time (`editing`); the backdrop shows the slot of the current appearance.
@Observable @MainActor final class WallpaperStore {
    private(set) var slots: [WallpaperScheme: WallpaperSlot] = [:]
    /// The slot the settings page and editor change.
    var editing: WallpaperScheme = .light

    // The editing slot, so the editor and settings code read one wallpaper as before.
    var mode: WallpaperMode { slot(editing).mode }
    var image: UIImage? { slot(editing).image }
    var layout: WallpaperLayout { slot(editing).layout }
    /// Overlay over the wallpaper (white in light, black in dark appearance) that keeps text readable.
    var scrim: Double { slot(editing).scrim }
    var hasBundledDefault: Bool { Self.bundledURL(editing) != nil }

    nonisolated static let scrimRange: ClosedRange<Double> = 0...1
    /// Default wallpaper mask (外观 → 壁纸遮罩强度).
    nonisolated static let defaultScrim = 0.18
    /// Keeps the bundled illustrations' faces in frame in both orientations.
    static func bundledLayout(_ scheme: WallpaperScheme) -> WallpaperLayout {
        scheme == .light ? WallpaperLayout(focusX: 0.5, focusY: 0.33, zoom: 1) : WallpaperLayout(focusX: 0.5, focusY: 0.3, zoom: 1)
    }

    private let defaults = UserDefaults.standard

    init() {
        for scheme in WallpaperScheme.allCases { slots[scheme] = Self.load(scheme, defaults: defaults) }
    }

    func slot(_ scheme: WallpaperScheme) -> WallpaperSlot {
        slots[scheme] ?? WallpaperSlot(mode: .plain, image: nil, layout: WallpaperLayout(), scrim: Self.defaultScrim)
    }

    private static func load(_ scheme: WallpaperScheme, defaults: UserDefaults) -> WallpaperSlot {
        let keys = Keys(scheme)
        let stored = defaults.string(forKey: keys.mode).flatMap(WallpaperMode.init(rawValue:))
        let customImage = (try? Data(contentsOf: fileURL(scheme))).flatMap(UIImage.init(data:))
        var slot = WallpaperSlot(mode: .plain, image: nil, layout: WallpaperLayout(), scrim: defaultScrim)
        switch stored {
        case .custom? where customImage != nil, nil where customImage != nil:
            slot.mode = .custom; slot.image = customImage
        case .plain?: slot.mode = .plain
        default:
            // First launch, or custom file missing: fall back to the bundled default if present.
            if let bundled = bundledImage(scheme) {
                slot.mode = .bundled; slot.image = bundled
                if stored != .bundled { slot.layout = bundledLayout(scheme); return slot }
            }
        }
        if defaults.object(forKey: keys.focusX) != nil {
            slot.layout = WallpaperLayout(focusX: defaults.double(forKey: keys.focusX),
                                          focusY: defaults.double(forKey: keys.focusY),
                                          zoom: max(1, defaults.double(forKey: keys.zoom)))
        }
        if defaults.object(forKey: keys.scrim) != nil { slot.scrim = defaults.double(forKey: keys.scrim) }
        return slot
    }

    /// Saves a newly chosen image (already prepared with `prepare`) with its layout, for the editing slot.
    func save(imageData: Data, layout: WallpaperLayout, scrim: Double) throws {
        guard let decoded = UIImage(data: imageData) else { throw WallpaperError.unreadable }
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try imageData.write(to: Self.fileURL(editing), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        slots[editing]?.image = decoded
        setMode(.custom)
        update(layout: layout, scrim: scrim)
    }

    func update(layout: WallpaperLayout, scrim: Double) {
        let keys = Keys(editing)
        let clamped = min(Self.scrimRange.upperBound, max(Self.scrimRange.lowerBound, scrim))
        slots[editing]?.layout = layout
        slots[editing]?.scrim = clamped
        defaults.set(layout.focusX, forKey: keys.focusX)
        defaults.set(layout.focusY, forKey: keys.focusY)
        defaults.set(layout.zoom, forKey: keys.zoom)
        defaults.set(clamped, forKey: keys.scrim)
    }

    /// Deletes the editing slot's custom image and shows its bundled default (or the plain backdrop).
    func restoreDefault() {
        try? FileManager.default.removeItem(at: Self.fileURL(editing))
        if let bundled = Self.bundledImage(editing) {
            slots[editing]?.image = bundled
            setMode(.bundled)
            update(layout: Self.bundledLayout(editing), scrim: Self.defaultScrim)
        } else {
            usePlainBackdrop()
        }
    }

    /// Plain designed backdrop for the editing slot; deletes its custom image.
    func usePlainBackdrop() {
        try? FileManager.default.removeItem(at: Self.fileURL(editing))
        slots[editing]?.image = nil
        setMode(.plain)
    }

    private func setMode(_ mode: WallpaperMode) {
        slots[editing]?.mode = mode
        defaults.set(mode.rawValue, forKey: Keys(editing).mode)
    }

    private static func bundledURL(_ scheme: WallpaperScheme) -> URL? {
        Bundle.main.url(forResource: scheme == .light ? "DefaultWallpaper" : "DefaultWallpaperNight", withExtension: "jpg")
    }

    private static func bundledImage(_ scheme: WallpaperScheme) -> UIImage? {
        bundledURL(scheme)
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

    /// Light keeps the original key names; dark uses a "wallpaper.dark." prefix.
    private struct Keys {
        let focusX, focusY, zoom, scrim, mode: String
        init(_ scheme: WallpaperScheme) {
            let p = scheme == .light ? "wallpaper." : "wallpaper.dark."
            focusX = p + "focusX"; focusY = p + "focusY"; zoom = p + "zoom"; scrim = p + "scrim"; mode = p + "mode"
        }
    }
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Wallpaper", isDirectory: true)
    }
    private static func fileURL(_ scheme: WallpaperScheme) -> URL {
        directory.appendingPathComponent(scheme == .light ? "wallpaper.jpg" : "wallpaper-dark.jpg")
    }
}

private struct WindowSizeKey: EnvironmentKey { static let defaultValue: CGSize = .zero }
extension EnvironmentValues {
    /// Size of the window hosting this view, measured by RootView (zero before the first layout).
    var windowSize: CGSize {
        get { self[WindowSizeKey.self] }
        set { self[WindowSizeKey.self] = newValue }
    }
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
    @Environment(\.windowSize) private var windowSize
    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            let window = windowSize == .zero ? WindowMetrics.size : windowSize
            ZStack(alignment: .topLeading) {
                WallpaperCanvas(image: image, layout: layout, container: window)
                    .offset(x: -frame.minX, y: -frame.minY)
                UtilityTheme.halo.opacity(scrim)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
        }
    }
}
