import SwiftUI

/// Design tokens. Values are documented in UIUX_SPEC.md; change them there and here together.
/// Native iOS structure, original bright blue / white / aqua look.
enum UtilityTheme {
    /// Light value / dark value, resolved by the trait collection (follows the app's colour scheme).
    static func adaptive(_ light: (Double, Double, Double), _ dark: (Double, Double, Double)) -> Color {
        Color(UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
    /// Fills, decorative bars, gradients (not for small text on white).
    static let brand = Color(red: 0.10, green: 0.56, blue: 0.89)        // #1A8FE3
    /// Text, icons and tint: #0B6FC2 on light surfaces, #5BB6F7 on dark ones (both WCAG AA).
    static let brandStrong = adaptive((0.04, 0.44, 0.76), (0.36, 0.71, 0.97))
    static let aqua = Color(red: 0.24, green: 0.80, blue: 0.90)         // #3CCBE6
    /// Primary text: #14283C / #E8EEF5.
    static let ink = adaptive((0.08, 0.16, 0.24), (0.91, 0.93, 0.96))
    /// Secondary text: darker than system .secondary so it stays readable over wallpapers.
    static let inkSecondary = ink.opacity(0.85)
    /// Plain backdrop: #F2F8FD / #0E1824.
    static let canvas = adaptive((0.95, 0.97, 0.99), (0.05, 0.09, 0.14))
    /// Opaque surface: white / #16222F.
    static let surface = adaptive((1, 1, 1), (0.09, 0.13, 0.18))
    /// Glass tint behind cards, fields and chips: white / #0F1A26.
    static let glassTint = adaptive((1, 1, 1), (0.06, 0.10, 0.15))
    /// Halo that keeps text readable over a wallpaper and the wallpaper scrim: white / black.
    static let halo = adaptive((1, 1, 1), (0, 0, 0))
    static let stroke = brand.opacity(0.16)
    static let planned = adaptive((0.36, 0.42, 0.48), (0.62, 0.68, 0.74))   // #5B6B7B / #9EADBC
    static let poc = adaptive((0.66, 0.37, 0.0), (0.95, 0.66, 0.31))        // #A85F00 / #F2A850
    static let danger = adaptive((0.70, 0.15, 0.12), (1.0, 0.48, 0.44))     // #B3261E / #FF7A70
    /// Disabled primary buttons: a solid mid grey in both schemes, so they stay visible on glass.
    static let disabledFill = Color(red: 0.42, green: 0.48, blue: 0.55)
    /// Kept for existing call sites: the tint colour.
    static let cyan = brandStrong

    static let radiusCard: CGFloat = 18
    static let radiusIcon: CGFloat = 12
    static let spacing: CGFloat = 16
    static let pagePadding: CGFloat = 24
    static let pageMaxWidth: CGFloat = 1080

    /// Decorative only (accent bars, halos): white text on it does not meet contrast.
    static let brandGradient = LinearGradient(colors: [brand, aqua], startPoint: .topLeading, endPoint: .bottomTrailing)
    /// Behind white text or glyphs: white is 5.2:1 on brandStrong and 3.5:1 on brand.
    static let deepGradient = LinearGradient(colors: [brandStrong, brand], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Slanted accent bar: a parallelogram used as the signature decoration on cards and headers.
struct SlantBar: Shape {
    var slant: CGFloat = 0.35
    func path(in rect: CGRect) -> Path {
        let offset = rect.height * slant
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + offset, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - offset, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Page backdrop: soft vertical gradient, a fine diagonal line field in the top-trailing corner
/// and two translucent halos. Purely decorative and hidden from accessibility.
/// A user wallpaper, when set, replaces the default backdrop (see WallpaperStore).
struct WorkspaceBackdrop: View {
    @Environment(WallpaperStore.self) private var wallpaper: WallpaperStore?
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        let slot = wallpaper?.slot(WallpaperScheme(colorScheme))
        Group {
            if let slot, let image = slot.image {
                WindowAlignedWallpaper(image: image, layout: slot.layout, scrim: slot.scrim)
            } else {
                DefaultBackdrop()
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

private struct DefaultBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [UtilityTheme.canvas, UtilityTheme.surface], startPoint: .top, endPoint: .bottom)
            Canvas { context, size in
                let spacing: CGFloat = 14
                let origin = CGPoint(x: size.width * 0.55, y: 0)
                var lines = Path()
                var x = origin.x
                while x < size.width + 260 {
                    lines.move(to: CGPoint(x: x, y: 0))
                    lines.addLine(to: CGPoint(x: x - 260, y: 260))
                    x += spacing
                }
                context.stroke(lines, with: .color(UtilityTheme.brand.opacity(0.06)), lineWidth: 1)
                let halo = Path(ellipseIn: CGRect(x: size.width - 300, y: -140, width: 420, height: 420))
                context.fill(halo, with: .color(UtilityTheme.aqua.opacity(0.10)))
                let halo2 = Path(ellipseIn: CGRect(x: -160, y: size.height * 0.55, width: 360, height: 360))
                context.fill(halo2, with: .color(UtilityTheme.brand.opacity(0.06)))
            }
        }
    }
}

/// Translucent "frosted glass" surface for cards, tiles and chips. How see-through it is comes from
/// the user's 界面透明度 (AppearanceStore → GlassStyle): white tint and blur material both fade as
/// transparency rises. Edges stay visible through a white inner line plus a faint dark outer line, and
/// dark text gains a soft white halo at high transparency. Reduce Transparency forces solid white.
struct GlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.glassTransparencyCap) private var cap
    @Environment(AppearanceStore.self) private var appearance: AppearanceStore?
    func body(content: Content) -> some View {
        let setting = appearance?.panelTransparency ?? AppearanceStore.defaultPanelTransparency
        let style = reduceTransparency ? GlassStyle.reducedTransparency : GlassStyle(transparency: min(setting, cap))
        let dark = colorScheme == .dark
        content
            // Two-pass halo (white, or black in dark mode) keeps text readable over busy wallpaper.
            .shadow(color: UtilityTheme.halo.opacity(0.95 * style.legibilityBoost), radius: 1)
            .shadow(color: UtilityTheme.halo.opacity(0.75 * style.legibilityBoost), radius: 3)
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial).opacity(style.materialOpacity)
                    shape.fill(UtilityTheme.glassTint.opacity(style.whiteTint))
                }
            }
            .overlay(shape.strokeBorder(Color.white.opacity(dark ? 0.10 + 0.08 * style.legibilityBoost : 0.6 + 0.3 * style.legibilityBoost), lineWidth: 1))
            .overlay(shape.stroke((dark ? Color.black : UtilityTheme.ink).opacity(0.06 + 0.10 * style.legibilityBoost), lineWidth: 0.5))
    }
}

extension View {
    func glassSurface<S: InsettableShape>(_ shape: S) -> some View { modifier(GlassSurface(shape: shape)) }
}

/// Upper bound for panel transparency in a subtree. Form-heavy pages (tools, settings) cap it so
/// small text stays readable over the wallpaper; the home page keeps the full setting.
private struct GlassTransparencyCapKey: EnvironmentKey { static let defaultValue = 1.0 }
extension EnvironmentValues {
    var glassTransparencyCap: Double {
        get { self[GlassTransparencyCapKey.self] }
        set { self[GlassTransparencyCapKey.self] = newValue }
    }
}

/// Main action button that stays clearly visible on glass when disabled (solid grey, white text).
struct PrimaryActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isEnabled ? AnyShapeStyle(UtilityTheme.deepGradient) : AnyShapeStyle(UtilityTheme.disabledFill))
            }
            .opacity(configuration.isPressed ? 0.85 : 1)
            .accessibilityAddTraits(.isButton)
    }
}

/// Text inputs on glass panels: a light semi-opaque base and hairline border so the tappable area
/// stays visible at any panel transparency; solid white with Reduce Transparency.
struct UtilityFieldStyle: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(UtilityTheme.glassTint.opacity(reduceTransparency ? 1 : 0.72), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(UtilityTheme.ink.opacity(0.14), lineWidth: 1))
    }
}

extension View {
    func utilityField() -> some View { modifier(UtilityFieldStyle()) }
}

/// Text placed directly on the page backdrop (headers, section titles): when a wallpaper image is
/// showing, add a layered white halo so dark text reads over any part of the picture. No effect on
/// the plain backdrop.
struct LegibleOnWallpaper: ViewModifier {
    @Environment(WallpaperStore.self) private var wallpaper: WallpaperStore?
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        let on = wallpaper?.slot(WallpaperScheme(colorScheme)).image != nil
        content
            .shadow(color: UtilityTheme.halo.opacity(on ? 0.95 : 0), radius: 1)
            .shadow(color: UtilityTheme.halo.opacity(on ? 0.85 : 0), radius: 4)
            .shadow(color: UtilityTheme.halo.opacity(on ? 0.55 : 0), radius: 10)
    }
}

extension View {
    func legibleOnWallpaper() -> some View { modifier(LegibleOnWallpaper()) }
}

/// Press feedback for tappable cards: slight scale and dim; no scale when Reduce Motion is on.
struct PressableCardStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .brightness(configuration.isPressed ? -0.03 : 0)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

enum FeatureStatus {
    /// `untested`: implemented and tested offline, not yet checked against the live service.
    case available, untested, poc, planned
    var title: String {
        switch self { case .available: "可用"; case .untested: "未实测"; case .poc: "PoC 阶段"; case .planned: "规划中" }
    }
    var color: Color {
        switch self {
        case .available: UtilityTheme.brandStrong
        case .untested, .poc: UtilityTheme.poc
        case .planned: UtilityTheme.planned
        }
    }
}

struct StatusChip: View {
    let status: FeatureStatus
    var body: some View {
        // Opaque-ish white base + coloured hairline so the chip reads over any wallpaper.
        Text(status.title)
            .font(.caption2.weight(.bold))
            .foregroundStyle(status.color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(UtilityTheme.glassTint.opacity(0.85), in: Capsule())
            .overlay(Capsule().strokeBorder(status.color.opacity(0.45), lineWidth: 1))
            .fixedSize()
    }
}

@MainActor struct UtilityCard<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: UtilityTheme.spacing) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .glassSurface(RoundedRectangle(cornerRadius: UtilityTheme.radiusCard))
            .overlay(alignment: .topLeading) {
                SlantBar().fill(UtilityTheme.brandGradient).frame(width: 40, height: 4).padding(.leading, 20)
            }
            .shadow(color: UtilityTheme.brand.opacity(0.05), radius: 10, y: 3)
    }
}

@MainActor struct PageHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AIUTILITY / WORKSPACE").font(.caption.monospaced().weight(.semibold)).foregroundStyle(UtilityTheme.brandStrong)
            Text(title).font(.largeTitle.bold()).foregroundStyle(UtilityTheme.ink)
            Text(subtitle).font(.subheadline).foregroundStyle(UtilityTheme.inkSecondary)
        }
        .legibleOnWallpaper()
        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
    }
}

@MainActor struct WorkspacePage<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) { content }
                .frame(maxWidth: 900).padding(20).frame(maxWidth: .infinity)
        }
        .background { WorkspaceBackdrop() }
        .scrollDismissesKeyboard(.interactively)
        .environment(\.glassTransparencyCap, 0.75)
    }
}
