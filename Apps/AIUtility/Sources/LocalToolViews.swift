import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AIUtilityMedia
import AIUtilityMediaApple

// Local media tools. Inputs are copied in from the photo picker; originals in the library are never
// changed. Results are shared through the system share sheet (save to Photos or Files from there).

/// A picked video copied into the app's temporary folder, as the GIF tool requires a sandbox file.
struct PickedVideo: Transferable, Sendable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AIUtilityImports", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let target = directory.appendingPathComponent(UUID().uuidString + "." + ext)
            try FileManager.default.copyItem(at: received.file, to: target)
            return PickedVideo(url: target)
        }
    }
}

private struct ToolStatusRow: View {
    let running: Bool
    let error: String?
    var body: some View {
        if running { ProgressView("处理中…") }
        if let error {
            Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(UtilityTheme.danger)
        }
    }
}

// MARK: - Stitch

@MainActor struct StitchToolView: View {
    private enum Mode: String, CaseIterable, Identifiable { case vertical = "纵向", horizontal = "横向", grid = "网格"; var id: String { rawValue } }
    @State private var picks: [PhotosPickerItem] = []
    @State private var mode = Mode.vertical
    @State private var columns = 2
    @State private var spacing = 0.0
    @State private var whiteBackground = true
    @State private var result: ImageResult?
    @State private var running = false
    @State private var error: String?
    @State private var shared: SharedFile?

    var body: some View {
        WorkspacePage {
            PageHeader(title: "多图拼接", subtitle: "按选择顺序拼成一张 PNG")
            UtilityCard {
                PhotosPicker(selection: $picks, maxSelectionCount: 32, selectionBehavior: .ordered, matching: .images) {
                    Label(picks.isEmpty ? "选择图片（最多 32 张）" : "已选 \(picks.count) 张，重新选择", systemImage: "photo.on.rectangle")
                }
                Picker("排列", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                if mode == .grid { Stepper("每行 \(columns) 张", value: $columns, in: 1...8) }
                HStack { Text("间距 \(Int(spacing)) 像素"); Slider(value: $spacing, in: 0...64, step: 2) }
                Toggle("白色背景（关闭为透明）", isOn: $whiteBackground)
                Button { Task { await run() } } label: { Label("开始拼接", systemImage: "rectangle.split.1x2") }
                    .buttonStyle(.borderedProminent).disabled(picks.count < 1 || running)
                ToolStatusRow(running: running, error: error)
            }
            if let result, let image = UIImage(data: result.data) {
                UtilityCard {
                    Text("结果 \(result.width) × \(result.height) 像素 · \(ByteCountFormatter.string(fromByteCount: Int64(result.data.count), countStyle: .file))")
                        .font(.subheadline)
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 420)
                    Button { if let url = temporaryExport(result.data, ext: "png") { shared = SharedFile(url: url) } } label: {
                        Label("分享 / 保存", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .sheet(item: $shared) { ShareSheet(items: [$0.url]) }
    }

    private func run() async {
        running = true; error = nil; result = nil
        defer { running = false }
        var images: [Data] = []
        for item in picks {
            guard let data = try? await item.loadTransferable(type: Data.self) else { error = "有图片无法读取。"; return }
            images.append(data)
        }
        let layout: StitchLayout = switch mode { case .vertical: .vertical; case .horizontal: .horizontal; case .grid: .grid(columns: columns) }
        let options = StitchOptions(layout: layout, spacing: Int(spacing), background: whiteBackground ? .white : .clear)
        do { result = try await stitchImages(images, options: options) } catch { self.error = error.userMessage }
    }
}

// MARK: - Video to GIF

@MainActor struct GIFToolView: View {
    @State private var pick: PhotosPickerItem?
    @State private var video: PickedVideo?
    @State private var start = 0.0
    @State private var duration = 3.0
    @State private var fps = 10
    @State private var width = 480
    @State private var result: GIFResult?
    @State private var running = false
    @State private var error: String?
    @State private var shared: SharedFile?
    @State private var task: Task<Void, Never>?

    var body: some View {
        WorkspacePage {
            PageHeader(title: "视频转 GIF", subtitle: "在设备上转换，不上传")
            UtilityCard {
                PhotosPicker(selection: $pick, matching: .videos) {
                    Label(video == nil ? "选择视频" : "已选择视频，重新选择", systemImage: "film")
                }
                Stepper("开始 \(start, specifier: "%.1f") 秒", value: $start, in: 0...600, step: 0.5)
                Stepper("时长 \(duration, specifier: "%.1f") 秒", value: $duration, in: 0.5...60, step: 0.5)
                Picker("帧率", selection: $fps) { ForEach([5, 10, 15, 20, 25], id: \.self) { Text("\($0) fps").tag($0) } }
                Picker("最大宽度", selection: $width) { ForEach([240, 320, 480, 640], id: \.self) { Text("\($0) 像素").tag($0) } }
                Text("小于最大宽度的视频不会被放大；GIF 不含声音。").font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
                HStack {
                    Button { task = Task { await run() } } label: { Label("开始转换", systemImage: "film.stack") }
                        .buttonStyle(.borderedProminent).disabled(video == nil || running)
                    if running { Button("取消", role: .cancel) { task?.cancel() } }
                }
                ToolStatusRow(running: running, error: error)
            }
            if let result {
                UtilityCard {
                    Text("\(result.width) × \(result.height) · \(result.frameCount) 帧 · \(result.totalDuration, specifier: "%.2f") 秒 · \(ByteCountFormatter.string(fromByteCount: result.bytes, countStyle: .file))")
                        .font(.subheadline)
                    if let image = UIImage(contentsOfFile: result.url.path) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 320)
                        Text("预览只显示第一帧。").font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
                    }
                    Button { shared = SharedFile(url: result.url) } label: { Label("分享 / 保存", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .onChange(of: pick) { _, item in
            video = nil; result = nil; error = nil
            guard let item else { return }
            Task {
                do { video = try await item.loadTransferable(type: PickedVideo.self) }
                catch { self.error = "视频无法读取。" }
            }
        }
        .sheet(item: $shared) { ShareSheet(items: [$0.url]) }
    }

    private func run() async {
        guard let video else { return }
        running = true; error = nil; result = nil
        defer { running = false }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("AIUtilityExports", isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let options = GIFOptions(start: start, duration: duration, fps: fps, maxWidth: width)
        do { result = try await makeGIF(fromVideo: video.url, outputDirectory: output, options: options) }
        catch { self.error = error == .invalidInput ? "片段超出视频长度。" : error.userMessage }
    }
}

// MARK: - Fingerprint

@MainActor struct FingerprintToolView: View {
    private enum Method: String, CaseIterable, Identifiable {
        case strip = "去除元数据", reencode = "重新编码", noise = "像素扰动"
        var id: String { rawValue }
    }
    @State private var pick: PhotosPickerItem?
    @State private var input: Data?
    @State private var method = Method.strip
    @State private var allowPixels = false
    @State private var result: FingerprintResult?
    @State private var running = false
    @State private var error: String?
    @State private var shared: SharedFile?

    var body: some View {
        WorkspacePage {
            PageHeader(title: "图片文件指纹", subtitle: "生成新文件，原图不变")
            UtilityCard {
                PhotosPicker(selection: $pick, matching: .images) {
                    Label(input == nil ? "选择图片" : "已选择图片，重新选择", systemImage: "photo")
                }
                Picker("方式", selection: $method) { ForEach(Method.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                Text(explanation).font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
                if method == .noise { Toggle("我知道这会轻微改变像素", isOn: $allowPixels) }
                Button { Task { await run() } } label: { Label("生成新文件", systemImage: "touchid") }
                    .buttonStyle(.borderedProminent)
                    .disabled(input == nil || running || (method == .noise && !allowPixels))
                ToolStatusRow(running: running, error: error)
                Text("不保证任何网站的去重判断一定会改变。").font(.caption2).foregroundStyle(UtilityTheme.inkSecondary)
            }
            if let result {
                UtilityCard {
                    Label(result.bytesChanged ? "文件字节已改变" : "文件字节没有变化（原图已经是规范格式）",
                          systemImage: result.bytesChanged ? "checkmark.circle" : "equal.circle")
                    Label(result.metadataRemoved ? "已移除可识别的元数据（位置、设备、时间等）" : "原图没有可移除的识别信息",
                          systemImage: "location.slash")
                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(result.data.count), countStyle: .file)) · \(result.typeIdentifier)")
                        .font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
                    Button {
                        let ext = result.typeIdentifier == "public.png" ? "png" : result.typeIdentifier == "public.jpeg" ? "jpg"
                            : (UTType(result.typeIdentifier)?.preferredFilenameExtension ?? "img")
                        if let url = temporaryExport(result.data, ext: ext) { shared = SharedFile(url: url) }
                    } label: { Label("分享 / 保存", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .onChange(of: pick) { _, item in
            input = nil; result = nil; error = nil
            guard let item else { return }
            Task { input = try? await item.loadTransferable(type: Data.self); if input == nil { error = "图片无法读取。" } }
        }
        .sheet(item: $shared) { ShareSheet(items: [$0.url]) }
    }

    private var explanation: String {
        switch method {
        case .strip: "不重新压缩像素，只去掉位置、设备、时间等信息；部分格式不支持无损处理会提示失败。"
        case .reencode: "解码后重新编码，会去掉元数据，JPEG 可能有极轻微画质变化。"
        case .noise: "约八分之一的像素在一个颜色通道上 ±1，肉眼几乎看不出。"
        }
    }

    private func run() async {
        guard let input else { return }
        running = true; error = nil; result = nil
        defer { running = false }
        let options: FingerprintOptions = switch method {
        case .strip: FingerprintOptions(method: .stripMetadata)
        case .reencode: FingerprintOptions(method: .reencode)
        case .noise: FingerprintOptions(method: .subtlePixelNoise, allowPixelChanges: allowPixels, noiseSeed: UInt64.random(in: 1...UInt64.max))
        }
        do { result = try await rewriteFingerprint(input, options: options) } catch { self.error = error.userMessage }
    }
}

// MARK: - Reverse search

@MainActor struct SearchToolView: View {
    private enum Source: String, CaseIterable, Identifiable {
        case soutubot = "搜图 Bot 酱", sauceNAO = "SauceNAO"
        var id: String { rawValue }
    }
    @State private var source = Source.soutubot
    @State private var strict = false
    @State private var keyDraft = ""
    @State private var hasKey = SauceNAOKeychain.isConfigured
    @State private var pick: PhotosPickerItem?
    @State private var matches: [ReverseSearchMatch]?
    @State private var running = false
    @State private var error: String?

    var body: some View {
        WorkspacePage {
            PageHeader(title: "反向搜图", subtitle: "只上传你选的这一张图片")
            UtilityCard {
                HStack { Text("搜索来源").font(.headline); Spacer(); StatusChip(status: .untested) }
                Picker("来源", selection: $source) { ForEach(Source.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                switch source {
                case .soutubot:
                    Toggle("严格模式（减少相似但不同的结果）", isOn: $strict).font(.subheadline)
                    Text("不需要 Key。按网页本身的请求方式接入，这个接口没有公开文档，网站改版后可能失效。结果可能包含成人向内容。")
                        .font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
                case .sauceNAO:
                    sauceNAOKey
                }
            }
            UtilityCard {
                PhotosPicker(selection: $pick, matching: .images) { Label("选择图片并搜索", systemImage: "magnifyingglass") }
                    .disabled(running || (source == .sauceNAO && !hasKey))
                ToolStatusRow(running: running, error: error)
                if let matches {
                    if matches.isEmpty { Text("没有找到足够相似的结果。").font(.subheadline) }
                    ForEach(Array(matches.enumerated()), id: \.offset) { _, match in result(match) }
                }
            }
        }
        .onChange(of: pick) { _, item in
            guard let item else { return }
            Task { await search(item) }
        }
        .onChange(of: source) { _, _ in matches = nil; error = nil }
    }

    @ViewBuilder private var sauceNAOKey: some View {
        if hasKey {
            HStack {
                Label("SauceNAO Key 已保存在本机钥匙串", systemImage: "key.fill").font(.subheadline)
                Spacer()
                Button("移除", role: .destructive) { SauceNAOKeychain.remove(); hasKey = false }
            }
        } else {
            SecureField("在 saucenao.com 账号页获取的 API Key", text: $keyDraft).utilityField()
            Button("保存 Key") {
                let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if SauceNAOKeychain.save(key) { hasKey = true; keyDraft = "" } else { error = "Key 保存失败。" }
            }
            .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        Text("这个 Key 与 AI 供应商的 Key 分开保存，不会用于翻译。").font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
    }

    private func result(_ match: ReverseSearchMatch) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(match.title ?? match.indexName).font(.subheadline.weight(.semibold)).lineLimit(2)
                Spacer()
                if let similarity = match.similarity {
                    // SauceNAO reports a percentage; Bot 酱 reports its own score.
                    if match.service == .sauceNAO {
                        Text("\(similarity, specifier: "%.1f")%").font(.caption.monospacedDigit())
                    } else {
                        Text("分数 \(similarity, specifier: "%.1f")").font(.caption.monospacedDigit())
                    }
                }
            }
            if let author = match.author { Text(author).font(.caption).foregroundStyle(UtilityTheme.inkSecondary) }
            Text(match.indexName).font(.caption2).foregroundStyle(UtilityTheme.inkSecondary).lineLimit(1)
            ForEach(match.links, id: \.self) { link in
                Link(destination: link) { Text(link.host ?? link.absoluteString).font(.caption) }
            }
            Divider()
        }
    }

    private func search(_ item: PhotosPickerItem) async {
        running = true; error = nil; matches = nil
        defer { running = false; pick = nil }
        guard let data = try? await item.loadTransferable(type: Data.self) else { error = "图片无法读取。"; return }
        let provider: any ReverseImageSearchProvider = switch source {
        case .soutubot: SoutubotProvider(strict: strict)
        case .sauceNAO: SauceNAOProvider(credentials: SauceNAOKeychain())
        }
        do { matches = try await provider.search(image: data) }
        catch { self.error = error.userMessage }
    }
}
