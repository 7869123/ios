import SwiftUI
import PhotosUI
import UIKit
import AIUtilityCore

@MainActor struct ScreenshotView: View {
    @EnvironmentObject private var app: AppModel
    @State private var photo: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var preview: UIImage?
    /// Selection in the displayed image, normalised 0…1 with a top-left origin.
    @State private var region = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
    @State private var useRegion = false
    @State private var recognizing = false
    @State private var translating = false
    @State private var operation: Task<Void, Never>?
    @State private var ocrStatus = "选择截图后在设备本地识别，可框选只识别一部分，识别结果可编辑。"
    var body: some View {
        WorkspacePage {
            PageHeader(title: "读懂每一张截图", subtitle: "Discord 对话与图片文字 · 本地 OCR")
            UtilityCard {
                let pickTitle = preview == nil ? "选择截图" : "换一张截图"
                PhotosPicker(selection: $photo, matching: .images) {
                    Label(pickTitle, systemImage: "photo.badge.plus").frame(maxWidth: .infinity)
                }.buttonStyle(PrimaryActionStyle()).disabled(recognizing || translating)
                if let preview {
                    Toggle("只识别框选区域", isOn: $useRegion).font(.subheadline).disabled(recognizing)
                    if useRegion {
                        RegionSelector(image: preview, region: $region)
                        Text("拖动方框移动，拖右下角圆点调整大小。").font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
                    } else {
                        Image(uiImage: preview).resizable().scaledToFit().frame(maxHeight: 280)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    HStack {
                        Button(useRegion ? "识别框选区域" : "识别整张图") { recognize() }
                            .buttonStyle(PrimaryActionStyle()).disabled(recognizing || translating)
                        if recognizing {
                            ProgressView()
                            Button("取消", role: .cancel) { cancel() }
                        }
                    }
                }
                Text(ocrStatus).font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
            }
            TranslationPanel(feature: .discordScreenshot, input: $app.screenshotDraft, translating: $translating, inputLocked: recognizing)
        }
        .task(id: photo) {
            guard let photo else { return }
            do {
                guard let data = try await photo.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                    throw AIUtilityError.invalidRequest
                }
                imageData = data; preview = image
                region = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
                ocrStatus = "已载入截图。点「识别」后才会在本机识别文字。"
                recognize()
            } catch { if !Task.isCancelled { ocrStatus = "截图无法读取。" } }
        }
        .onDisappear { cancel() }
    }

    private func recognize() {
        guard let data = imageData else { return }
        let box = useRegion ? region : nil
        recognizing = true
        operation = Task {
            defer { recognizing = false; operation = nil }
            do {
                let languages = (try? await app.services.preferences.languages(for: .discordScreenshot)) ?? TranslationLanguages()
                // Vision uses a bottom-left origin on the orientation-corrected image.
                let ocrRegion = try box.map {
                    try OCRRegion(x: max(0, $0.minX), y: max(0, 1 - $0.maxY), width: min($0.width, 1 - max(0, $0.minX)),
                                  height: min($0.height, 1 - max(0, 1 - $0.maxY)))
                }
                let draft = try await app.services.screenshots.recognize(imageData: data, source: languages.source, region: ocrRegion)
                try Task.checkCancellation()
                app.screenshotDraft = draft.text
                let seconds = Double(draft.recognitionDuration.components.attoseconds) / 1e18 + Double(draft.recognitionDuration.components.seconds)
                ocrStatus = draft.lines.isEmpty ? "未识别到文字，可调整框选范围或手动输入。"
                    : "已识别 \(draft.lines.count) 行，用时 \(String(format: "%.1f", seconds)) 秒。只有点击翻译才会发送文字。"
            } catch {
                if !Task.isCancelled { ocrStatus = UserFacingError.text(error) }
            }
        }
    }

    private func cancel() {
        operation?.cancel()
        Task { await app.services.screenshots.cancel() }
    }
}

/// Draggable, resizable selection box over an image. `region` is normalised with a top-left origin.
@MainActor struct RegionSelector: View {
    let image: UIImage
    @Binding var region: CGRect
    @State private var moveStart: CGRect?
    @State private var resizeStart: CGRect?
    private let minimum: CGFloat = 0.05

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let frame = CGRect(x: region.minX * size.width, y: region.minY * size.height,
                               width: region.width * size.width, height: region.height * size.height)
            ZStack(alignment: .topLeading) {
                Image(uiImage: image).resizable().frame(width: size.width, height: size.height)
                Color.black.opacity(0.35)
                    .mask {
                        Rectangle().overlay(alignment: .topLeading) {
                            Rectangle().frame(width: frame.width, height: frame.height)
                                .offset(x: frame.minX, y: frame.minY).blendMode(.destinationOut)
                        }
                        .compositingGroup()
                    }
                    .allowsHitTesting(false)
                Rectangle().strokeBorder(UtilityTheme.brand, lineWidth: 2)
                    .background(Color.white.opacity(0.001))
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .gesture(DragGesture().onChanged { value in
                        let start = moveStart ?? region
                        if moveStart == nil { moveStart = start }
                        let x = min(max(0, start.minX + value.translation.width / size.width), 1 - start.width)
                        let y = min(max(0, start.minY + value.translation.height / size.height), 1 - start.height)
                        region = CGRect(x: x, y: y, width: start.width, height: start.height)
                    }.onEnded { _ in moveStart = nil })
                Circle().fill(UtilityTheme.brand).frame(width: 26, height: 26)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    .offset(x: frame.maxX - 13, y: frame.maxY - 13)
                    .gesture(DragGesture().onChanged { value in
                        let start = resizeStart ?? region
                        if resizeStart == nil { resizeStart = start }
                        let width = min(max(minimum, start.width + value.translation.width / size.width), 1 - start.minX)
                        let height = min(max(minimum, start.height + value.translation.height / size.height), 1 - start.minY)
                        region = CGRect(x: start.minX, y: start.minY, width: width, height: height)
                    }.onEnded { _ in resizeStart = nil })
                    .accessibilityLabel("调整框选大小")
            }
        }
        .aspectRatio(image.size.width / max(image.size.height, 1), contentMode: .fit)
        .frame(maxHeight: 360)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("截图框选区域")
    }
}

/// One subtitle entry with two sources: pasted text (available) and live cross-app captions (PoC).
@MainActor struct SubtitleView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case paste, live
        var id: String { rawValue }
        var title: String { self == .paste ? "粘贴文本" : "实时字幕" }
    }
    @EnvironmentObject private var app: AppModel
    @State private var translating = false
    @State private var mode = Mode.paste
    @State private var showLiveInfo = false
    var body: some View {
        WorkspacePage {
            PageHeader(title: "字幕工作台", subtitle: "粘贴文本翻译可用 · 实时字幕规划中 · 共用字幕模型")
            Picker("字幕来源", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            switch mode {
            case .paste:
                TranslationPanel(feature: .videoSubtitle, input: $app.subtitleDraft, translating: $translating)
            case .live:
                UtilityCard {
                    HStack {
                        Label("跨 App 实时字幕 · PiP", systemImage: "pip").font(.headline)
                        Spacer()
                        StatusChip(status: .poc)
                    }
                    Text("采集其他 App 正在播放的声音，本地识别后在画中画小窗中显示字幕，并用字幕模型翻译。目前是独立的诊断 PoC，尚未接入本 App，也未经真机验证，暂不可用。")
                        .font(.subheadline).foregroundStyle(UtilityTheme.inkSecondary)
                    Button("了解进度") { showLiveInfo = true }.buttonStyle(.bordered)
                }
            }
        }
        .sheet(isPresented: $showLiveInfo) { LiveCaptionInfoSheet() }
    }
}

@MainActor struct TranslationPanel: View {
    @EnvironmentObject private var app: AppModel
    let feature: TranslationFeature
    @Binding var input: String
    @Binding var translating: Bool
    var inputLocked = false
    @State private var languages = TranslationLanguages()
    @State private var output = ""
    @State private var status = "在设置中验证 Key 和模型后即可使用。"
    @State private var operation: Task<Void, Never>?
    private var provider: Binding<ProviderID> {
        feature == .discordScreenshot ? $app.screenshotProvider : $app.subtitleProvider
    }
    var body: some View {
        UtilityCard {
            Picker("供应商", selection: provider) {
                ForEach(ProviderID.allCases, id: \.self) { Text($0.title).tag($0) }
            }.disabled(translating)
            TranslationLanguagePickers(feature: feature, languages: $languages, disabled: translating)
            Text("原文").font(.headline)
            TextEditor(text: $input).frame(minHeight: 150, maxHeight: 250)
                .scrollContentBackground(.hidden).utilityField()
                .accessibilityLabel("待翻译文字").disabled(translating || inputLocked)
            HStack {
                Button("翻译") { translate() }.buttonStyle(PrimaryActionStyle())
                    .disabled(translating || inputLocked || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if translating {
                    ProgressView()
                    Button("取消", role: .cancel) { operation?.cancel() }
                }
            }
            Text(status).font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
            if !output.isEmpty {
                Divider()
                HStack {
                    Text("译文").font(.headline)
                    Spacer()
                    Button("复制", systemImage: "doc.on.doc") { UIPasteboard.general.string = output }
                }
                Text(output).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onDisappear { operation?.cancel() }
    }
    private func translate() {
        let text = input, selected = languages, selectedProvider = provider.wrappedValue, feature = feature
        translating = true
        output = ""
        status = "正在请求所选模型…"
        operation = Task {
            defer { translating = false; operation = nil }
            do {
                // Typed overload: the pair shown above, which is also the saved per-feature preference.
                let result = try await app.services.translation.translate(text, provider: selectedProvider,
                    feature: feature, languages: selected)
                try Task.checkCancellation()
                output = result
                status = "已收到译文。"
            } catch { status = UserFacingError.text(error) }
        }
    }
}
