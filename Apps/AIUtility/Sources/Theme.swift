import SwiftUI

/// Design tokens. Values are documented in UIUX_SPEC.md; change them there and here together.
/// Native iOS structure, original bright blue / white / aqua look.
enum UtilityTheme {
    /// Fills, decorative bars, gradients (not for small text on white).
    static let brand = Color(red: 0.10, green: 0.56, blue: 0.89)        // #1A8FE3
    /// Text, icons and tint on white surfaces (WCAG AA on white).
    static let brandStrong = Color(red: 0.04, green: 0.44, blue: 0.76)  // #0B6FC2
    static let aqua = Color(red: 0.24, green: 0.80, blue: 0.90)         // #3CCBE6
    static let ink = Color(red: 0.08, green: 0.16, blue: 0.24)          // #14283C
    static let canvas = Color(red: 0.95, green: 0.97, blue: 0.99)       // #F2F8FD
    static let surface = Color.white
    static let stroke = brand.opacity(0.16)
    static let planned = Color(red: 0.36, green: 0.42, blue: 0.48)      // #5B6B7B (5.5:1 on white)
    static let poc = Color(red: 0.66, green: 0.37, blue: 0.0)           // #A85F00 (4.9:1 on white)
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
    var body: some View {
        Group {
            if let wallpaper, let image = wallpaper.image {
                WindowAlignedWallpaper(image: image, layout: wallpaper.layout, scrim: wallpaper.scrim)
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
            LinearGradient(colors: [UtilityTheme.canvas, .white], startPoint: .top, endPoint: .bottom)
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
    @Environment(AppearanceStore.self) private var appearance: AppearanceStore?
    func body(content: Content) -> some View {
        let style = reduceTransparency
            ? GlassStyle.reducedTransparency
            : GlassStyle(transparency: appearance?.panelTransparency ?? AppearanceStore.defaultPanelTransparency)
        content
            .shadow(color: .white.opacity(0.85 * style.legibilityBoost), radius: 1.5)
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial).opacity(style.materialOpacity)
                    shape.fill(Color.white.opacity(style.whiteTint))
                }
            }
            .overlay(shape.strokeBorder(Color.white.opacity(0.6 + 0.3 * style.legibilityBoost), lineWidth: 1))
            .overlay(shape.stroke(UtilityTheme.ink.opacity(0.06 + 0.10 * style.legibilityBoost), lineWidth: 0.5))
    }
}

extension View {
    func glassSurface<S: InsettableShape>(_ shape: S) -> some View { modifier(GlassSurface(shape: shape)) }
}

/// Text inputs on glass panels: a light semi-opaque base and hairline border so the tappable area
/// stays visible at any panel transparency; solid white with Reduce Transparency.
struct UtilityFieldStyle: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color.white.opacity(reduceTransparency ? 1 : 0.72), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(UtilityTheme.ink.opacity(0.14), lineWidth: 1))
    }
}

extension View {
    func utilityField() -> some View { modifier(UtilityFieldStyle()) }
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
    case available, poc, planned
    var title: String {
        switch self { case .available: "可用"; case .poc: "PoC · 未经真机验证"; case .planned: "规划中" }
    }
    var color: Color {
        switch self { case .available: UtilityTheme.brandStrong; case .poc: UtilityTheme.poc; case .planned: UtilityTheme.planned }
    }
}

struct StatusChip: View {
    let status: FeatureStatus
    var body: some View {
        Text(status.title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(status.color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(status.color.opacity(0.10), in: Capsule())
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
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
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
    }
}
