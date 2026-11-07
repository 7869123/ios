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
    static let planned = Color(red: 0.42, green: 0.49, blue: 0.56)      // #6B7D8F
    static let poc = Color(red: 0.80, green: 0.47, blue: 0.05)          // #CC780D
    /// Kept for existing call sites: the tint colour.
    static let cyan = brandStrong

    static let radiusCard: CGFloat = 18
    static let radiusIcon: CGFloat = 12
    static let spacing: CGFloat = 16
    static let pagePadding: CGFloat = 24
    static let pageMaxWidth: CGFloat = 1080

    static let brandGradient = LinearGradient(colors: [brand, aqua], startPoint: .topLeading, endPoint: .bottomTrailing)
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
struct WorkspaceBackdrop: View {
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
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
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
            .background(UtilityTheme.surface, in: RoundedRectangle(cornerRadius: UtilityTheme.radiusCard))
            .overlay(RoundedRectangle(cornerRadius: UtilityTheme.radiusCard).strokeBorder(UtilityTheme.stroke))
            .overlay(alignment: .topLeading) {
                SlantBar().fill(UtilityTheme.brandGradient).frame(width: 40, height: 4).padding(.leading, 20)
            }
            .shadow(color: UtilityTheme.brand.opacity(0.06), radius: 12, y: 4)
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
