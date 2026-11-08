import SwiftUI

enum Workspace: String, CaseIterable, Identifiable {
    case home, screenshot, subtitles, media, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "工作台"; case .screenshot: "截图翻译"; case .subtitles: "字幕翻译"; case .media: "媒体工具"; case .settings: "设置"
        }
    }
    var icon: String {
        switch self {
        case .home: "house"; case .screenshot: "viewfinder"; case .subtitles: "captions.bubble"; case .media: "square.grid.2x2"; case .settings: "slider.horizontal.3"
        }
    }
}

@MainActor struct RootView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selected: Workspace? = .home
    @State private var windowSize: CGSize = .zero
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var lastPortrait: Bool?
    var body: some View {
        content
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { windowSize = proxy.size; updateColumns(for: proxy.size) }
                        .onChange(of: proxy.size) { _, size in windowSize = size; updateColumns(for: size) }
                }
                .ignoresSafeArea()
            }
            .environment(\.windowSize, windowSize)
    }
    @ViewBuilder private var content: some View {
        if sizeClass == .regular {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                List(Workspace.allCases, selection: $selected) { item in
                    Label(item.title, systemImage: item.icon).tag(item).legibleOnWallpaper()
                }
                .scrollContentBackground(.hidden)
                .background { SidebarBackdrop() }
                .navigationTitle("AIUtility")
                .safeAreaInset(edge: .bottom) {
                    HStack(spacing: 8) {
                        SlantBar().fill(UtilityTheme.brandGradient).frame(width: 18, height: 5)
                        Text("TOOLS FOR YOUR DAY").font(.caption.monospaced()).foregroundStyle(UtilityTheme.inkSecondary)
                    }.padding()
                }
            } detail: {
                let item = selected ?? .home
                NavigationStack { page(item).navigationTitle(item == .home ? "" : item.title).navigationBarTitleDisplayMode(.inline) }
                    .id(item)
            }
        } else {
            TabView(selection: Binding(get: { selected ?? .home }, set: { selected = $0 })) {
                ForEach(Workspace.allCases) { item in
                    NavigationStack { page(item).navigationTitle(item == .home ? "" : item.title).navigationBarTitleDisplayMode(.inline) }
                        .tabItem { Label(item.title, systemImage: item.icon) }
                        .tag(item)
                }
            }
        }
    }
    /// iPad portrait (taller than wide) starts with the sidebar hidden so content and wallpaper get
    /// the full width; the toolbar button still shows it. Landscape shows it again. Only applied when
    /// the orientation actually changes, so a manual toggle is kept until the next rotation.
    private func updateColumns(for size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let portrait = size.height > size.width
        let wanted: NavigationSplitViewVisibility = portrait ? .detailOnly : .all
        if portrait != lastPortrait { columnVisibility = wanted; lastPortrait = portrait }
    }
    @ViewBuilder private func page(_ item: Workspace) -> some View {
        switch item {
        case .home: HomeView(open: { selected = $0 })
        case .screenshot: ScreenshotView()
        case .subtitles: SubtitleView()
        case .media: MediaToolsView()
        case .settings: SettingsView()
        }
    }
}

/// Sidebar background: the same window-aligned wallpaper, under a light glass layer that follows
/// 界面透明度 (a little more opaque than cards, since the list rows are plain system text).
private struct SidebarBackdrop: View {
    @Environment(AppearanceStore.self) private var appearance: AppearanceStore?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        let style = reduceTransparency ? GlassStyle.reducedTransparency
            : GlassStyle(transparency: appearance?.panelTransparency ?? AppearanceStore.defaultPanelTransparency)
        ZStack {
            WorkspaceBackdrop()
            Rectangle().fill(.ultraThinMaterial).opacity(style.materialOpacity).ignoresSafeArea()
            Color.white.opacity(min(1, style.whiteTint + 0.2)).ignoresSafeArea()
        }
        .accessibilityHidden(true)
    }
}
