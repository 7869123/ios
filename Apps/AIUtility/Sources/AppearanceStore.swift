import SwiftUI
import Observation

/// User appearance preference: how see-through panels (cards, tiles, chip buttons, hero) are.
/// `panelTransparency` 0...1 — higher means more of the wallpaper shows through. Persisted.
/// The wallpaper scrim is the separate `WallpaperStore.scrim`.
@Observable @MainActor final class AppearanceStore {
    /// 跟随系统 / 始终浅色 / 始终深色.
    enum ColorMode: String, CaseIterable, Identifiable, Sendable {
        case system, light, dark
        var id: String { rawValue }
        var title: String { switch self { case .system: "跟随系统"; case .light: "浅色"; case .dark: "深色" } }
    }

    nonisolated static let defaultPanelTransparency = 0.9
    private(set) var panelTransparency: Double
    private(set) var colorMode: ColorMode

    private let defaults = UserDefaults.standard
    private static let key = "appearance.panelTransparency"
    private static let modeKey = "appearance.colorMode"

    init() {
        panelTransparency = defaults.object(forKey: Self.key) != nil
            ? min(1, max(0, defaults.double(forKey: Self.key)))
            : Self.defaultPanelTransparency
        colorMode = defaults.string(forKey: Self.modeKey).flatMap(ColorMode.init(rawValue:)) ?? .system
        #if DEBUG
        // CI review screenshots only: `-AIUtilityAppearance light|dark` (not saved).
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-AIUtilityAppearance"), index + 1 < args.count,
           let forced = ColorMode(rawValue: args[index + 1]) { colorMode = forced }
        #endif
    }

    /// nil follows the system setting.
    var preferredColorScheme: ColorScheme? {
        switch colorMode { case .system: nil; case .light: .light; case .dark: .dark }
    }

    func setColorMode(_ mode: ColorMode) {
        colorMode = mode
        defaults.set(mode.rawValue, forKey: Self.modeKey)
    }

    func setPanelTransparency(_ value: Double) {
        panelTransparency = min(1, max(0, value))
        defaults.set(panelTransparency, forKey: Self.key)
    }

    func restoreDefaults() {
        setPanelTransparency(Self.defaultPanelTransparency)
        setColorMode(.system)
    }
}

/// Pure mapping from the transparency setting to rendering parameters, so every surface uses one
/// semantic. Defaults (t = 0.9): white tint 0.10, material 0.25, hero 0.78.
struct GlassStyle: Equatable, Sendable {
    let transparency: Double

    /// White overlay opacity: solid white at 0, none at 1.
    var whiteTint: Double { 1 - transparency }
    /// Blur material opacity: fades out faster than the tint so high settings stay see-through.
    var materialOpacity: Double { min(1, (1 - transparency) * 2.5) }
    /// Hero banner gradient opacity: 1 at 0, 0.78 at the default 0.9, 0.5 at 1.
    var heroOpacity: Double {
        transparency <= 0.9 ? 1 - 0.22 * (transparency / 0.9) : 0.78 - 2.8 * (transparency - 0.9)
    }
    /// 0 until 0.5, then ramps to full strength at 0.8: legibility aids (text halo, hero text shading).
    var legibilityBoost: Double { min(1, max(0, (transparency - 0.5) / 0.3)) }

    static let reducedTransparency = GlassStyle(transparency: 0)
}

/// Settings card «外观»: live sliders for panel transparency and the wallpaper scrim, plus reset.
@MainActor struct AppearanceSettingsCard: View {
    @Environment(AppearanceStore.self) private var appearance
    @Environment(WallpaperStore.self) private var wallpaper
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        UtilityCard {
            Text("外观").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text("显示模式").font(.subheadline.bold())
                Picker("显示模式", selection: Binding(get: { appearance.colorMode }, set: { appearance.setColorMode($0) })) {
                    ForEach(AppearanceStore.ColorMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("跟随系统时，iPad / iPhone 切到深色外观后，App 会换成深色界面和夜晚壁纸。")
                    .font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
            }
            percentSlider(
                title: "界面透明度",
                caption: "卡片、按钮和面板的透明程度。数值越高，壁纸透过面板越明显。",
                value: Binding(get: { appearance.panelTransparency }, set: { appearance.setPanelTransparency($0) })
            )
            percentSlider(
                title: "壁纸遮罩强度",
                caption: wallpaper.mode == .plain ? "当前为纯色背景，遮罩不生效。"
                    : "当前显示的\(wallpaper.editing.title)模式壁纸上方的遮罩（浅色为白色、深色为黑色）。数值越高，壁纸越淡、文字越清晰。",
                value: Binding(get: { wallpaper.scrim }, set: { wallpaper.update(layout: wallpaper.layout, scrim: $0) })
            )
            .disabled(wallpaper.mode == .plain)
            if reduceTransparency {
                Label("系统已开启「降低透明度」，面板暂时以不透明方式显示；关闭后恢复此处设置。", systemImage: "accessibility")
                    .font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
            }
            Button {
                appearance.restoreDefaults()
                wallpaper.update(layout: wallpaper.layout, scrim: WallpaperStore.defaultScrim)
            } label: { Label("恢复默认外观", systemImage: "arrow.counterclockwise") }
                .buttonStyle(.bordered)
            Text("默认：跟随系统，界面透明度 \(Int(AppearanceStore.defaultPanelTransparency * 100))%，壁纸遮罩 \(Int(WallpaperStore.defaultScrim * 100))%。调整立即生效并自动保存。")
                .font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
        }
        // The scrim slider edits the wallpaper that is showing now.
        .onAppear { wallpaper.editing = WallpaperScheme(colorScheme) }
    }

    private func percentSlider(title: String, caption: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline.bold())
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))%").font(.subheadline.monospacedDigit()).foregroundStyle(UtilityTheme.brandStrong)
            }
            Slider(value: value, in: 0...1) { Text(title) } minimumValueLabel: { Text("0%").font(.caption2) } maximumValueLabel: { Text("100%").font(.caption2) }
                .accessibilityValue("\(Int((value.wrappedValue * 100).rounded()))%")
            Text(caption).font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
        }
    }
}
