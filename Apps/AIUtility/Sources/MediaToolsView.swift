import SwiftUI
import AIUtilityMedia

/// Media hub. Statuses are honest: local tools run on device; site downloads and reverse search are
/// implemented but only tested against offline samples, so they are marked 未实测.
struct MediaTool: Identifiable {
    enum Page: String, Hashable, CaseIterable { case downloads, stitch, gif, fingerprint, search }
    let id: String
    let title: String
    let icon: String
    let detail: String
    let status: FeatureStatus
    let page: Page
    static let downloads: [MediaTool] = [
        .init(id: "downloads", title: "链接下载", icon: "arrow.down.circle",
              detail: "粘贴 B站 / X / Pixiv 链接，排队逐个下载；Pixiv 动图转 GIF", status: .untested, page: .downloads),
    ]
    static let local: [MediaTool] = [
        .init(id: "stitch", title: "多图拼接", icon: "rectangle.split.1x2", detail: "纵向、横向或网格，按选择顺序", status: .available, page: .stitch),
        .init(id: "gif", title: "视频转 GIF", icon: "film.stack", detail: "选片段、帧率与宽度，在设备上转换", status: .available, page: .gif),
        .init(id: "fingerprint", title: "图片文件指纹", icon: "touchid", detail: "去除元数据、重新编码或轻微像素扰动", status: .available, page: .fingerprint),
    ]
    static let search: [MediaTool] = [
        .init(id: "search", title: "反向搜图", icon: "magnifyingglass", detail: "搜图 Bot 酱（无需 Key）或 SauceNAO（需自备 Key）",
              status: .untested, page: .search),
    ]
}

@MainActor struct MediaToolsView: View {
    @EnvironmentObject private var media: MediaModel
    /// Set only by the DEBUG review-screenshot launch argument, to open one tool page directly.
    @State private var autoOpen: MediaTool.Page?
    @State private var autoOpened = false

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
        .navigationDestination(item: $autoOpen) { page in
            if let tool = (MediaTool.downloads + MediaTool.local + MediaTool.search).first(where: { $0.page == page }) {
                destination(tool)
            }
        }
        .onAppear {
            #if DEBUG
            if !autoOpened, let page = ReviewLaunch.mediaPage { autoOpened = true; autoOpen = page }
            #endif
        }
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
    /// Kept across launches: the option is part of a task's identity, so re-pasting a link after a restart
    /// must use the same setting to continue that task.
    @AppStorage("pixivKeepUgoiraArchive") private var keepArchive = false
    @State private var shared: SharedFile?
    @State private var confirmClear = false

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
                            if await media.enqueue(link, keepUgoiraArchive: keepArchive) { link = "" }
                            busy = false
                        }
                    } label: { Label("加入队列", systemImage: "plus.circle.fill") }
                    .buttonStyle(PrimaryActionStyle())
                    .disabled(busy || link.trimmingCharacters(in: .whitespaces).isEmpty)
                    if busy { ProgressView() }
                }
                Toggle("Pixiv 动图同时保留原始帧压缩包", isOn: $keepArchive).font(.subheadline)
                Text("B站：公开 MP4（通常 ≤720P），多 P 用 ?p= 指定一集。X：图片原图与视频。Pixiv：原图；动图在本机转成 GIF，每帧时长按 GIF 精度（10 毫秒）对齐，短于 20 毫秒的帧按 20 毫秒播放。可以直接粘贴 App 分享出来的整段文字。下载时请留在 AIUtility 里：切到其他 App 约半分钟后传输会中断，需要重试。")
                    .font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
                if let error = media.lastError ?? media.startupError {
                    Label(error.userMessage, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(UtilityTheme.danger)
                }
                if let notice = media.notice {
                    Label(notice, systemImage: "info.circle").font(.footnote).foregroundStyle(UtilityTheme.inkSecondary)
                }
                if let blocking = media.snapshot?.blockingError {
                    // The queue stops after a failed cleanup until it is retried (or the app restarts).
                    VStack(alignment: .leading, spacing: 6) {
                        Label("队列已暂停：\(blocking.userMessage)", systemImage: "pause.circle").font(.footnote)
                            .foregroundStyle(UtilityTheme.danger)
                        Button("重试清理并继续") { Task { await media.retryCleanup() } }.buttonStyle(.bordered)
                    }
                }
            }
            UtilityCard {
                HStack {
                    Text("任务与历史").font(.headline)
                    Spacer()
                    Button("清空历史") { confirmClear = true }
                        .font(.footnote).disabled(media.snapshot?.tasks.isEmpty ?? true)
                        .confirmationDialog("清空历史", isPresented: $confirmClear, titleVisibility: .visible) {
                            Button("删除已下载的文件并清空", role: .destructive) { Task { await media.clearHistory(deletingFiles: true) } }
                            Button("只清空记录，保留已下载的文件") { Task { await media.clearHistory(deletingFiles: false) } }
                            Button("取消", role: .cancel) {}
                        } message: {
                            Text("失败、已取消和已中断的记录会被移除，正在进行和排队的任务不受影响。保留的已下载任务仍可导出或单独删除。")
                        }
                }
                let tasks = (media.snapshot?.tasks ?? []).sorted { $0.createdAt > $1.createdAt }
                if tasks.isEmpty {
                    Text("还没有任务。").font(.subheadline).foregroundStyle(UtilityTheme.inkSecondary)
                } else {
                    ForEach(tasks) { task in row(task) }
                }
            }
        }
        .sheet(item: $shared) { file in ShareSheet(items: file.urls) }
    }

    private func row(_ task: DownloadSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(Self.title(task)).font(.subheadline.weight(.semibold)).lineLimit(2)
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
            // Pictures and videos share in one sheet (all pages / images). A kept Ugoira zip gets its own button: mixed
            // with a GIF, the share sheet may drop "Save Image", since a zip cannot go to Photos.
            let pictures = files.filter { !$0.fileName.lowercased().hasSuffix(".zip") }
            let archives = files.filter { $0.fileName.lowercased().hasSuffix(".zip") }
            if !pictures.isEmpty {
                Button(archives.isEmpty ? (pictures.count > 1 ? "全部导出" : "导出") : "导出 GIF") {
                    Task { await export(pictures, title: task.title) }
                }
            }
            if !archives.isEmpty {
                Button("导出压缩包") { Task { await export(archives, title: task.title) } }
            }
            Button("删除文件", role: .destructive) { Task { await media.delete(task.id) } }
        case .deletionIncomplete(let files):
            if !files.isEmpty { Button("导出剩余") { Task { await export(files, title: task.title) } } }
            Button("重新删除", role: .destructive) { Task { await media.delete(task.id) } }
        default:
            EmptyView()
        }
    }

    private func export(_ files: [DownloadedFile], title: String) async {
        if let urls = await media.exportURLs(files, title: title) { shared = SharedFile(urls: urls) }
    }

    /// Real titles are known only after a link is resolved in this run (never stored on disk); until then the row
    /// shows the source and when it was added.
    static func title(_ task: DownloadSnapshot) -> String {
        guard task.title == DownloadSnapshot.genericTitle else { return task.title }
        let added = task.createdAt.formatted(date: .abbreviated, time: .shortened)
        return "\(task.source.map(sourceName) ?? "链接") · \(added) 添加"
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

#if DEBUG
/// CI review screenshots only: `-AIUtilityPage <downloads|stitch|gif|fingerprint|search>`.
enum ReviewLaunch {
    /// Raw value of `-AIUtilityPage`: a media tool page, or settings-translation / settings-provider / settings-cards /
    /// screenshot-region for the translation pages.
    static var page: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-AIUtilityPage"), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
    static var mediaPage: MediaTool.Page? { page.flatMap(MediaTool.Page.init(rawValue:)) }
    static var settingsPage: String? { page.flatMap { $0.hasPrefix("settings-") ? $0 : nil } }
    static var screenshotRegion: Bool { page == "screenshot-region" }
}
#endif
