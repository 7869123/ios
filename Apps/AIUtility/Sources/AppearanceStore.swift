import SwiftUI
import Observation

/// User appearance preference: how see-through panels (cards, tiles, chip buttons, hero) are.
/// `panelTransparency` 0...1 — higher means more of the wallpaper shows through. Persisted.
/// The wallpaper scrim is the separate `WallpaperStore.scrim`.
@Observable @MainActor final class AppearanceStore {
    nonisolated static let defaultPanelTransparency = 0.9
    private(set) var panelTransparency: Double

    private let defaults = UserDefaults.standard
    private static let key = "appearance.panelTransparency"

    init() {
        panelTransparency = defaults.object(forKey: Self.key) != nil
            ? min(1, max(0, defaults.double(forKey: Self.key)))
            : Self.defaultPanelTransparency
    }

    func setPanelTransparency(_ value: Double) {
        panelTransparency = min(1, max(0, value))
        defaults.set(panelTransparency, forKey: Self.key)
    }

    func restoreDefaults() { setPanelTransparency(Self.defaultPanelTransparency) }
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
    /// 0 until 0.6, then ramps to 1: strength of legibility aids (text halo, hero text shading).
    var legibilityBoost: Double { min(1, max(0, (transparency - 0.6) / 0.4)) }

    static let reducedTransparency = GlassStyle(transparency: 0)
}

/// Settings card «外观»: live sliders for panel transparency and the wallpaper scrim, plus reset.
@MainActor struct AppearanceSettingsCard: View {
    @Environment(AppearanceStore.self) private var appearance
    @Environment(WallpaperStore.self) private var wallpaper
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        UtilityCard {
            Text("外观").font(.headline)
            percentSlider(
                title: "界面透明度",
                caption: "卡片、按钮和面板的透明程度。数值越高，壁纸透过面板越明显。",
                value: Binding(get: { appearance.panelTransparency }, set: { appearance.setPanelTransparency($0) })
            )
            percentSlider(
                title: "壁纸遮罩强度",
                caption: wallpaper.mode == .plain ? "当前为纯色背景，遮罩不生效。" : "壁纸上方的白色遮罩。数值越高，壁纸越淡、文字越清晰。",
                value: Binding(get: { wallpaper.scrim }, set: { wallpaper.update(layout: wallpaper.layout, scrim: $0) })
            )
            .disabled(wallpaper.mode == .plain)
            if reduceTransparency {
                Label("系统已开启「降低透明度」，面板暂时以不透明方式显示；关闭后恢复此处设置。", systemImage: "accessibility")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button {
                appearance.restoreDefaults()
                wallpaper.update(layout: wallpaper.layout, scrim: WallpaperStore.defaultScrim)
            } label: { Label("恢复默认外观", systemImage: "arrow.counterclockwise") }
                .buttonStyle(.bordered)
            Text("默认：界面透明度 \(Int(AppearanceStore.defaultPanelTransparency * 100))%，壁纸遮罩 \(Int(WallpaperStore.defaultScrim * 100))%。调整立即生效并自动保存。")
                .font(.caption).foregroundStyle(.secondary)
        }
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
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }
}
