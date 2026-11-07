import SwiftUI

enum Workspace: String, CaseIterable, Identifiable {
    case screenshot, subtitles, media, settings
    var id: String { rawValue }
    var title: String {
        switch self { case .screenshot: "截图翻译"; case .subtitles: "字幕翻译"; case .media: "媒体工具"; case .settings: "设置" }
    }
    var icon: String {
        switch self { case .screenshot: "viewfinder"; case .subtitles: "captions.bubble"; case .media: "square.grid.2x2"; case .settings: "slider.horizontal.3" }
    }
}

@MainActor struct RootView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selected: Workspace? = .screenshot
    var body: some View {
        if sizeClass == .regular {
            NavigationSplitView {
                List(Workspace.allCases, selection: $selected) { item in
                    Label(item.title, systemImage: item.icon).tag(item)
                }
                .navigationTitle("AIUtility")
                .safeAreaInset(edge: .bottom) { Text("TOOLS FOR YOUR DAY").font(.caption.monospaced()).foregroundStyle(.secondary).padding() }
            } detail: {
                NavigationStack { page(selected ?? .screenshot).navigationTitle((selected ?? .screenshot).title) }
            }
        } else {
            TabView {
                ForEach(Workspace.allCases) { item in
                    NavigationStack { page(item).navigationTitle(item.title) }
                        .tabItem { Label(item.title, systemImage: item.icon) }
                }
            }
        }
    }
    @ViewBuilder private func page(_ item: Workspace) -> some View {
        switch item {
        case .screenshot: ScreenshotView()
        case .subtitles: SubtitleView()
        case .media: MediaToolsView()
        case .settings: SettingsView()
        }
    }
}
