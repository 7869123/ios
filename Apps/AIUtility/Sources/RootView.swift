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
    var body: some View {
        if sizeClass == .regular {
            NavigationSplitView {
                List(Workspace.allCases, selection: $selected) { item in
                    Label(item.title, systemImage: item.icon).tag(item)
                }
                .navigationTitle("AIUtility")
                .safeAreaInset(edge: .bottom) {
                    HStack(spacing: 8) {
                        SlantBar().fill(UtilityTheme.brandGradient).frame(width: 18, height: 5)
                        Text("TOOLS FOR YOUR DAY").font(.caption.monospaced()).foregroundStyle(.secondary)
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
