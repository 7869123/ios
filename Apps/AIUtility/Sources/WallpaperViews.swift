import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

/// A wallpaper being edited: `data` is set for a newly chosen image and nil when re-positioning the saved one.
struct WallpaperDraft: Identifiable {
    let id = UUID()
    let image: UIImage
    let data: Data?
    var layout: WallpaperLayout
    var scrim: Double
}

/// Full-screen preview: the frame uses the current window's aspect ratio (portrait or landscape),
/// drag to move, pinch to zoom; nothing is saved until 保存.
@MainActor struct WallpaperEditorView: View {
    let image: UIImage
    let onSave: (WallpaperLayout, Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var layout: WallpaperLayout
    @State private var scrim: Double
    @State private var landscape: Bool
    @State private var dragBase: WallpaperLayout?
    @State private var zoomBase: Double?

    init(draft: WallpaperDraft, onSave: @escaping (WallpaperLayout, Double) -> Void) {
        image = draft.image
        self.onSave = onSave
        _layout = State(initialValue: draft.layout)
        _scrim = State(initialValue: draft.scrim)
        let window = WindowMetrics.size
        _landscape = State(initialValue: window.width > window.height)
    }

    /// Aspect of the device window in the chosen orientation.
    private var target: CGSize {
        let window = WindowMetrics.size
        let short = min(window.width, window.height), long = max(window.width, window.height)
        return landscape ? CGSize(width: long, height: short) : CGSize(width: short, height: long)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Picker("预览方向", selection: $landscape) {
                    Text("竖屏").tag(false)
                    Text("横屏").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)

                GeometryReader { proxy in
                    let fit = min(proxy.size.width / target.width, proxy.size.height / target.height)
                    let size = CGSize(width: target.width * fit, height: target.height * fit)
                    preview(size: size)
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                }

                Text("拖动调整位置，双指缩放。预览框按本机屏幕比例显示；同一设置会自动适配竖屏和横屏，可切换方向检查。")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    Image(systemName: "circle.lefthalf.filled").foregroundStyle(.secondary)
                    Text("文字可读性遮罩").font(.subheadline)
                    Slider(value: $scrim, in: WallpaperStore.scrimRange)
                    Text("\(Int(scrim * 100))%").font(.subheadline.monospacedDigit()).frame(width: 44, alignment: .trailing)
                }
                .frame(maxWidth: 520)
            }
            .padding()
            .background(Color(.systemGroupedBackground))
            .navigationTitle("壁纸预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { onSave(layout, scrim); dismiss() }.fontWeight(.semibold)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("重置位置") { layout = WallpaperLayout() }
                }
            }
        }
    }

    private func preview(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            WallpaperCanvas(image: image, layout: layout, container: size)
            Color.white.opacity(scrim)
            mockContent(size: size)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(UtilityTheme.stroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .contentShape(Rectangle())
        .gesture(dragGesture(size: size).simultaneously(with: zoomGesture(size: size)))
        .accessibilityElement()
        .accessibilityLabel("壁纸预览")
        .accessibilityHint("拖动调整位置，双指缩放，也可使用辅助功能操作")
        .accessibilityAction(named: "向左移动") { nudge(CGSize(width: -size.width * 0.1, height: 0), size: size) }
        .accessibilityAction(named: "向右移动") { nudge(CGSize(width: size.width * 0.1, height: 0), size: size) }
        .accessibilityAction(named: "向上移动") { nudge(CGSize(width: 0, height: -size.height * 0.1), size: size) }
        .accessibilityAction(named: "向下移动") { nudge(CGSize(width: 0, height: size.height * 0.1), size: size) }
        .accessibilityAction(named: "放大") { layout = layout.zoomed(to: layout.zoom + 0.25, imageSize: image.size, container: size) }
        .accessibilityAction(named: "缩小") { layout = layout.zoomed(to: layout.zoom - 0.25, imageSize: image.size, container: size) }
    }

    /// Faint stand-ins for page content so readability over the wallpaper can be judged.
    private func mockContent(size: CGSize) -> some View {
        let unit = size.width / 30
        return HStack(alignment: .top, spacing: unit) {
            if landscape {
                RoundedRectangle(cornerRadius: unit * 0.6).fill(.white.opacity(0.6))
                    .frame(width: size.width * 0.26)
            }
            VStack(alignment: .leading, spacing: unit) {
                RoundedRectangle(cornerRadius: unit * 0.3).fill(UtilityTheme.ink.opacity(0.75)).frame(width: unit * 6, height: unit * 1.1)
                RoundedRectangle(cornerRadius: unit * 0.8).fill(UtilityTheme.deepGradient).frame(height: unit * 4)
                HStack(spacing: unit * 0.6) {
                    ForEach(0..<(landscape ? 3 : 2), id: \.self) { _ in
                        RoundedRectangle(cornerRadius: unit * 0.6).fill(.white.opacity(0.55)).frame(height: unit * 3.6)
                    }
                }
            }
        }
        .padding(unit * 1.2)
        .allowsHitTesting(false)
    }

    private func nudge(_ translation: CGSize, size: CGSize) {
        layout = layout.dragged(by: translation, imageSize: image.size, container: size)
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragBase == nil { dragBase = layout }
                guard var base = dragBase else { return }
                base.zoom = layout.zoom
                layout = base.dragged(by: value.translation, imageSize: image.size, container: size)
            }
            .onEnded { _ in dragBase = nil }
    }

    private func zoomGesture(size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if zoomBase == nil { zoomBase = layout.zoom }
                guard let base = zoomBase else { return }
                layout = layout.zoomed(to: base * value.magnification, imageSize: image.size, container: size)
            }
            .onEnded { _ in zoomBase = nil }
    }
}

/// Settings card: choose from Photos or Files, re-position, or restore the default background.
@MainActor struct WallpaperSettingsCard: View {
    @Environment(WallpaperStore.self) private var store
    @State private var photoItem: PhotosPickerItem?
    @State private var importingFile = false
    @State private var draft: WallpaperDraft?
    @State private var loading = false
    @State private var message: String?

    var body: some View {
        UtilityCard {
            HStack {
                Text("壁纸").font(.headline)
                Spacer()
                Text(modeTitle).font(.caption.weight(.semibold)).foregroundStyle(UtilityTheme.brandStrong)
            }
            Text("选择一张图片作为页面背景。图片只保存在本机 App 目录，会缩小到长边 3000 像素并去除位置等元数据，不会上传。")
                .font(.caption).foregroundStyle(.secondary)
            if let image = store.image {
                WindowThumbnail(image: image, layout: store.layout, scrim: store.scrim)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { buttons }
                VStack(alignment: .leading, spacing: 12) { buttons }
            }
            if loading { ProgressView("正在处理图片…") }
            if let message { Text(message).font(.subheadline).foregroundStyle(.secondary) }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await loadPhoto(item) }
        }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.image]) { result in
            Task { await loadFile(result) }
        }
        .fullScreenCover(item: $draft) { draft in
            WallpaperEditorView(draft: draft) { layout, scrim in commit(draft, layout: layout, scrim: scrim) }
        }
    }

    private var modeTitle: String {
        switch store.mode { case .custom: "自定义壁纸"; case .bundled: "默认壁纸"; case .plain: "纯色背景" }
    }

    @ViewBuilder private var buttons: some View {
        PhotosPicker(selection: $photoItem, matching: .images) {
            Label(store.image == nil ? "从照片选择" : "从照片更换", systemImage: "photo.on.rectangle")
        }
        .buttonStyle(.borderedProminent)
        .disabled(loading)
        Button { importingFile = true } label: { Label("从文件选择", systemImage: "folder") }
            .buttonStyle(.bordered).disabled(loading)
        if let image = store.image {
            Button {
                draft = WallpaperDraft(image: image, data: nil, layout: store.layout, scrim: store.scrim)
            } label: { Label("调整位置", systemImage: "arrow.up.and.down.and.arrow.left.and.right") }
                .buttonStyle(.bordered).disabled(loading)
        }
        if store.mode == .custom || (store.mode == .plain && store.hasBundledDefault) {
            Button { store.restoreDefault(); message = "已使用默认壁纸。" } label: {
                Label("使用默认壁纸", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered).disabled(loading)
        }
        if store.mode != .plain {
            Button(role: .destructive) { store.usePlainBackdrop(); message = "已改为纯色背景。" } label: {
                Label("纯色背景", systemImage: "square.slash")
            }
            .buttonStyle(.bordered).disabled(loading)
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        defer { photoItem = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { message = "无法读取所选照片。"; return }
            await prepare(data)
        } catch {
            message = "无法读取所选照片。"
        }
    }

    private func loadFile(_ result: Result<URL, any Error>) async {
        guard case .success(let url) = result else { message = "未选择文件。"; return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { message = "无法读取所选文件。"; return }
        await prepare(data)
    }

    private func prepare(_ original: Data) async {
        loading = true
        defer { loading = false }
        do {
            let prepared = try await Task.detached(priority: .userInitiated) { try WallpaperStore.prepare(original) }.value
            guard let image = UIImage(data: prepared) else { message = "图片格式不受支持。"; return }
            message = nil
            draft = WallpaperDraft(image: image, data: prepared, layout: WallpaperLayout(), scrim: store.scrim)
        } catch {
            message = "图片格式不受支持或文件已损坏。"
        }
    }

    private func commit(_ draft: WallpaperDraft, layout: WallpaperLayout, scrim: Double) {
        if let data = draft.data {
            do { try store.save(imageData: data, layout: layout, scrim: scrim); message = "壁纸已保存。" }
            catch { message = "保存失败，原壁纸保持不变。" }
        } else {
            store.update(layout: layout, scrim: scrim)
            message = "位置已更新。"
        }
    }
}

/// Small preview of the saved wallpaper in the current window aspect.
private struct WindowThumbnail: View {
    let image: UIImage
    let layout: WallpaperLayout
    let scrim: Double
    var body: some View {
        let window = WindowMetrics.size
        let height: CGFloat = 120
        let size = CGSize(width: height * window.width / max(window.height, 1), height: height)
        ZStack {
            WallpaperCanvas(image: image, layout: layout, container: size)
            Color.white.opacity(scrim)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(UtilityTheme.stroke))
        .accessibilityLabel("当前壁纸预览")
    }
}
