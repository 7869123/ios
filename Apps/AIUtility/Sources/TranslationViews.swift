import SwiftUI
import PhotosUI
import UIKit
import AIUtilityCore

@MainActor struct ScreenshotView: View {
    @EnvironmentObject private var app: AppModel
    @State private var photo: PhotosPickerItem?
    @State private var recognizing = false
    @State private var translating = false
    @State private var ocrStatus = "选择截图后在设备本地识别，可编辑识别文字。"
    var body: some View {
        WorkspacePage {
            PageHeader(title: "读懂每一张截图", subtitle: "Discord 对话与图片文字 · 本地 OCR")
            UtilityCard {
                PhotosPicker(selection: $photo, matching: .images) {
                    Label("选择截图", systemImage: "photo.badge.plus").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).disabled(recognizing || translating)
                if recognizing { ProgressView("正在本地识别…") }
                Text(ocrStatus).font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
            }
            TranslationPanel(feature: .discordScreenshot, input: $app.screenshotDraft, translating: $translating, inputLocked: recognizing)
        }
        .task(id: photo) {
            guard let photo else { return }
            recognizing = true
            defer { recognizing = false }
            do {
                guard let data = try await photo.loadTransferable(type: Data.self) else { throw AIUtilityError.invalidRequest }
                let result = try await app.services.ocr.recognize(imageData: data)
                try Task.checkCancellation()
                app.screenshotDraft = result.text
                ocrStatus = result.lines.isEmpty ? "未识别到文字，可手动输入。" : "已识别 \(result.lines.count) 行。只有点击翻译才会发送文字。"
            } catch { if !Task.isCancelled { ocrStatus = UserFacingError.text(error) } }
        }
    }
}

@MainActor struct SubtitleView: View {
    @EnvironmentObject private var app: AppModel
    @State private var translating = false
    var body: some View {
        WorkspacePage {
            PageHeader(title: "字幕工作台", subtitle: "使用独立字幕模型，共享供应商 Key")
            UtilityCard {
                Label("当前支持字幕文本翻译", systemImage: "text.bubble")
                Text("粘贴已转写的字幕文字。跨 App 音频、连续语音识别和 PiP 字幕仍在技术验证阶段，尚未接入此入口。")
                    .font(.subheadline).foregroundStyle(UtilityTheme.inkSecondary)
            }
            TranslationPanel(feature: .videoSubtitle, input: $app.subtitleDraft, translating: $translating)
        }
    }
}

@MainActor struct TranslationPanel: View {
    @EnvironmentObject private var app: AppModel
    let feature: TranslationFeature
    @Binding var input: String
    @Binding var translating: Bool
    var inputLocked = false
    @State private var language = TranslationLanguage.chinese
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
            Picker("目标语言", selection: $language) {
                ForEach(TranslationLanguage.allCases) { Text($0.rawValue).tag($0) }
            }.disabled(translating)
            Text("原文").font(.headline)
            TextEditor(text: $input).frame(minHeight: 150, maxHeight: 250)
                .scrollContentBackground(.hidden).utilityField()
                .accessibilityLabel("待翻译文字").disabled(translating || inputLocked)
            HStack {
                Button("翻译") { translate() }.buttonStyle(.borderedProminent)
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
        let text = input, target = language.rawValue, selectedProvider = provider.wrappedValue
        translating = true
        output = ""
        status = "正在请求所选模型…"
        operation = Task {
            defer { translating = false; operation = nil }
            do {
                let result = try await app.services.translation.translate(text, targetLanguage: target,
                    provider: selectedProvider, feature: feature)
                try Task.checkCancellation()
                output = result
                status = "已收到译文。"
            } catch { status = UserFacingError.text(error) }
        }
    }
}
