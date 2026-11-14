import SwiftUI
import AIUtilityCore

extension SupportedLanguage {
    var title: String {
        switch self { case .simplifiedChinese: "简体中文"; case .english: "English"; case .japanese: "日本語"; case .korean: "한국어" }
    }
}

extension SourceLanguage {
    var title: String { language?.title ?? "自动检测" }
}

extension TranslationFeature {
    var settingsTitle: String { self == .videoSubtitle ? "字幕翻译" : "截图翻译" }
}

/// Source and target pickers bound to the saved per-feature language preference. Changes are saved
/// immediately; if saving fails the selection still applies to this session and the error is shown.
@MainActor struct TranslationLanguagePickers: View {
    @EnvironmentObject private var app: AppModel
    let feature: TranslationFeature
    @Binding var languages: TranslationLanguages
    var disabled = false
    @State private var loaded = false
    @State private var error: String?

    private var sources: [SourceLanguage] {
        // Automatic detection is offered only when the engine really has a local detector.
        SourceLanguage.allCases.filter { $0 != .automatic || app.services.translation.supportsAutomaticTextDetection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("源语言", selection: $languages.source) {
                ForEach(sources, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("目标语言", selection: $languages.target) {
                ForEach(SupportedLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if languages.source.language == languages.target {
                Text("源语言与目标语言相同时直接返回原文，不调用模型。")
                    .font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(UtilityTheme.danger)
            }
        }
        .disabled(disabled || !loaded)
        .task(id: feature) {
            loaded = false
            do { languages = try await app.services.preferences.languages(for: feature); error = nil }
            catch { self.error = "语言设置读取失败，暂用默认值。" }
            loaded = true
        }
        .onChange(of: languages) { _, value in
            guard loaded else { return }
            let feature = feature
            Task {
                do { try await app.services.preferences.saveLanguages(value, for: feature); error = nil }
                catch { self.error = "语言设置保存失败，本次仍按所选语言翻译。" }
            }
        }
    }
}

/// Settings → 翻译提示词与语言: one editable prompt and one language pair per feature.
@MainActor struct TranslationSettingsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var feature = TranslationFeature.discordScreenshot
    @State private var languages = TranslationLanguages()
    @State private var prompt = ""
    @State private var savedPrompt = ""
    @State private var busy = false
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        WorkspacePage {
            PageHeader(title: "翻译提示词与语言", subtitle: "截图翻译与字幕翻译分别设置")
            Picker("功能", selection: $feature) {
                Text(TranslationFeature.discordScreenshot.settingsTitle).tag(TranslationFeature.discordScreenshot)
                Text(TranslationFeature.videoSubtitle.settingsTitle).tag(TranslationFeature.videoSubtitle)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            UtilityCard {
                Text("语言").font(.headline)
                TranslationLanguagePickers(feature: feature, languages: $languages)
                Text("支持简体中文、English、日本語、한국어互译。这里的选择与翻译页面里的是同一份设置。")
                    .font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
            }
            UtilityCard {
                Text("提示词").font(.headline)
                TextEditor(text: $prompt).frame(minHeight: 180, maxHeight: 320)
                    .scrollContentBackground(.hidden).utilityField()
                    .accessibilityLabel("\(feature.settingsTitle)提示词").disabled(busy)
                Text("可用 {{sourceLanguage}} 和 {{targetLanguage}} 代表所选语言。提示词随每次翻译请求发送，保存本身不会调用模型。待翻译的文字始终作为数据单独发送，不会被当作指令。")
                    .font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
                HStack {
                    Button("保存提示词") { save() }
                        .buttonStyle(PrimaryActionStyle())
                        .disabled(busy || prompt == savedPrompt || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("恢复默认") { restore() }.buttonStyle(.bordered).disabled(busy)
                }
                if let message {
                    Text(message).font(.subheadline).foregroundStyle(failed ? UtilityTheme.danger : UtilityTheme.inkSecondary)
                }
            }
        }
        .task(id: feature) { await load() }
    }

    private func load() async {
        message = nil; failed = false
        do {
            let value = try await app.services.preferences.prompt(for: feature)
            prompt = value; savedPrompt = value
        } catch { message = "提示词读取失败。"; failed = true }
    }

    private func save() {
        let text = prompt, feature = feature
        busy = true
        Task {
            defer { busy = false }
            do {
                try await app.services.preferences.savePrompt(text, for: feature)
                savedPrompt = text; message = "已保存。"; failed = false
            } catch { message = "保存失败：提示词不能为空，且不能超过 4096 字节。"; failed = true }
        }
    }

    private func restore() {
        let feature = feature
        busy = true
        Task {
            defer { busy = false }
            do {
                try await app.services.preferences.restoreDefaultPrompt(for: feature)
                let value = try await app.services.preferences.prompt(for: feature)
                prompt = value; savedPrompt = value; message = "已恢复默认提示词。"; failed = false
            } catch { message = "恢复默认失败。"; failed = true }
        }
    }
}
