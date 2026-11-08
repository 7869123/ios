import SwiftUI
import AIUtilityMedia

/// Media hub. Statuses are honest: local tools run on device; site downloads and reverse search are
/// implemented but only tested against offline samples, so they are marked 未实测.
struct MediaTool: Identifiable {
    enum Page { case downloads, stitch, gif, fingerprint, search }
    let id: String
    let title: String
    let icon: String
    let detail: String
    let status: FeatureStatus
    let page: Page
    static let downloads: [MediaTool] = [
        .init(id: "downloads", title: "链接下载", icon: "arrow.down.circle",
              detail: "粘贴 B站 / X / Pixiv 链接，排队逐个下载；动图暂不支持", status: .untested, page: .downloads),
    ]
    static let local: [MediaTool] = [
        .init(id: "stitch", title: "多图拼接", icon: "rectangle.split.1x2", detail: "纵向、横向或网格，按选择顺序", status: .available, page: .stitch),
        .init(id: "gif", title: "视频转 GIF", icon: "film.stack", detail: "选片段、帧率与宽度，在设备上转换", status: .available, page: .gif),
        .init(id: "fingerprint", title: "图片文件指纹", icon: "touchid", detail: "去除元数据、重新编码或轻微像素扰动", status: .available, page: .fingerprint),
    ]
    static let search: [MediaTool] = [
        .init(id: "search", title: "SauceNAO 搜图", icon: "magnifyingglass", detail: "需要自己的 SauceNAO Key；搜图 Bot 酱规划中",
              status: .untested, page: .search),
    ]
}

@MainActor struct MediaToolsView: View {
    @EnvironmentObject private var media: MediaModel

    var body: some View {
        WorkspacePage {
            PageHeader(title: "媒体工具箱", subtitle: "下载、图片处理与搜图")
            section("下载", MediaTool.downloads)
            section("本地工具", MediaTool.local)
            section("搜图", MediaTool.search)
            Text("“未实测”表示功能已实现，但只用离线样例测试过，还没有连接真实站点验证。只处理公开内容，不绕过登录、付费或地区限制。")
                .font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
                .legibleOnWallpaper()
        }
        .task { await media.start() }
    }

    private func section(_ title: String, _ tools: [MediaTool]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SlantBar().fill(UtilityTheme.brand).frame(width: 16, height: 14)
                Text(title).font(.title3.bold()).foregroundStyle(UtilityTheme.ink)
            }
            .legibleOnWallpaper()
            .accessibilityAddTraits(.isHeader)
            ForEach(tools) { tool in
                NavigationLink { destination(tool) } label: {
                    FeatureTile(title: tool.title, detail: tool.detail, icon: tool.icon, status: tool.status)
                }
                .buttonStyle(PressableCardStyle())
            }
        }
    }

    @ViewBuilder private func destination(_ tool: MediaTool) -> some View {
        Group {
            switch tool.page {
            case .downloads: DownloadsView(media: media)
            case .stitch: StitchToolView()
            case .gif: GIFToolView()
            case .fingerprint: FingerprintToolView()
            case .search: SearchToolView()
            }
        }
        .navigationTitle(tool.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Downloads

@MainActor struct DownloadsView: View {
    @ObservedObject var media: MediaModel
    @State private var link = ""
    @State private var busy = false
    @State private var shared: SharedFile?

    var body: some View {
        WorkspacePage {
            PageHeader(title: "链接下载", subtitle: "一次只下载一个任务，其余排队")
            UtilityCard {
                HStack { Text("添加链接").font(.headline); Spacer(); StatusChip(status: .untested) }
                TextField("https://www.bilibili.com/video/… / x.com/…/status/… / pixiv.net/artworks/…", text: $link)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .utilityField()
                HStack {
                    Button {
                        Task {
                            busy = true
                            if await media.enqueue(link) { link = "" }
                            busy = false
                        }
                    } label: { Label("加入队列", systemImage: "plus.circle.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || link.trimmingCharacters(in: .whitespaces).isEmpty)
                    if busy { ProgressView() }
                }
                Text("B站：公开 MP4（通常 ≤720P），多 P 用 ?p= 指定一集。X：图片原图与视频。Pixiv：原图，动图（Ugoira）暂不支持。")
                    .font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
                if let error = media.lastError ?? media.startupError {
                    Label(error.userMessage, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(UtilityTheme.danger)
                }
            }
            UtilityCard {
                HStack {
                    Text("任务与历史").font(.headline)
                    Spacer()
                    Button("清空历史") { Task { await media.clearHistory() } }
                        .font(.footnote).disabled(media.snapshot?.tasks.isEmpty ?? true)
                }
                let tasks = (media.snapshot?.tasks ?? []).sorted { $0.createdAt > $1.createdAt }
                if tasks.isEmpty {
                    Text("还没有任务。").font(.subheadline).foregroundStyle(UtilityTheme.inkSecondary)
                } else {
                    ForEach(tasks) { task in row(task) }
                }
            }
        }
        .sheet(item: $shared) { file in ShareSheet(items: [file.url]) }
    }

    private func row(_ task: DownloadSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(task.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Spacer()
                Text(task.source.map(Self.sourceName) ?? "").font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
            }
            HStack(spacing: 8) {
                Text(Self.stateText(task.state)).font(.caption).foregroundStyle(Self.stateColor(task.state))
                if let fraction = Self.fraction(task.state) { ProgressView(value: fraction).frame(maxWidth: 160) }
                Spacer()
                actions(task)
            }
            .font(.caption)
            Divider()
        }
    }

    @ViewBuilder private func actions(_ task: DownloadSnapshot) -> some View {
        switch task.state {
        case .queued, .resolving, .running, .waitingToRetry, .processing:
            Button("取消") { Task { await media.cancel(task.id) } }
        case .failed, .cancelled, .interrupted:
            Button("重试") { Task { await media.retry(task.id) } }
        case .completed(let files):
            if let file = files.first {
                Button("导出") { Task { if let url = await media.fileURL(file) { shared = SharedFile(url: url) } } }
            }
            Button("删除文件", role: .destructive) { Task { await media.delete(task.id) } }
        default:
            EmptyView()
        }
    }

    static func sourceName(_ source: MediaSource) -> String {
        switch source { case .bilibili: "B站"; case .x: "X"; case .pixiv: "Pixiv"; case .direct: "直链" }
    }
    static func fraction(_ state: DownloadState) -> Double? {
        switch state { case .running(let p), .processing(let p): p.fraction; default: nil }
    }
    static func stateText(_ state: DownloadState) -> String {
        switch state {
        case .queued(let position): "排队中（第 \(position + 1) 位）"
        case .resolving: "解析中"
        case .running: "下载中"
        case .waitingToRetry(let attempt, _): "等待重试（第 \(attempt) 次）"
        case .processing: "处理中"
        case .committing: "保存中"
        case .cancelling: "取消中"
        case .interrupted: "已中断"
        case .completed(let files): "已完成 · \(files.count) 个文件"
        case .duplicate: "与已完成的任务重复"
        case .deletionIncomplete: "文件未完全删除"
        case .failed(let error): "失败：" + error.userMessage
        case .cancelled: "已取消"
        }
    }
    static func stateColor(_ state: DownloadState) -> Color {
        switch state {
        case .failed, .deletionIncomplete: UtilityTheme.danger
        case .completed: UtilityTheme.brandStrong
        default: UtilityTheme.inkSecondary
        }
    }
}
