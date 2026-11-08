import SwiftUI
import AIUtilityCore

/// AI providers, Keys and model bindings (Settings → AI 供应商与模型).
@MainActor struct ProviderSettingsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var provider = ProviderID.openAI
    @State private var candidateKey = ""
    @State private var screenshotModel = ""
    @State private var subtitleModel = ""
    @State private var catalogue: [AIModel] = []
    @State private var hasSavedKey = false
    @State private var busy = false
    @State private var message = "每家供应商保存一个 Key，两种翻译独立选择模型。"
    @State private var budget = ""
    @State private var operation: Task<Void, Never>?
    var body: some View {
        WorkspacePage {
            PageHeader(title: "AI 供应商与模型", subtitle: "Keychain 存储 · 模型验证后提交")
            KeyStatusCard()
            UtilityCard {
                Picker("配置供应商", selection: $provider) {
                    ForEach(ProviderID.allCases, id: \.self) { Text($0.title).tag($0) }
                }.disabled(busy)
                Label(hasSavedKey ? "已保存共享 Key" : "尚未配置 Key", systemImage: hasSavedKey ? "key.fill" : "key")
                    .font(.subheadline)
                SecureField(hasSavedKey ? "替换 Key（留空则使用已保存 Key）" : "输入 API Key", text: $candidateKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive().disabled(busy)
                    .utilityField()
                Button("获取官方模型目录") { discoverModels() }.disabled(busy)
                Text("读取目录不会保存候选 Key，也不代表该模型已通过生成验证。")
                    .font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
                modelField("截图翻译模型", value: $screenshotModel)
                modelField("字幕翻译模型", value: $subtitleModel)
                Button("验证并保存 Key 与两个模型") { saveKey() }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || candidateKey.isEmpty || screenshotModel.isEmpty || subtitleModel.isEmpty)
                if hasSavedKey {
                    HStack {
                        Button("验证并切换截图模型") { switchModel(.discordScreenshot, model: screenshotModel) }.disabled(busy || screenshotModel.isEmpty)
                        Button("验证并切换字幕模型") { switchModel(.videoSubtitle, model: subtitleModel) }.disabled(busy || subtitleModel.isEmpty)
                    }
                }
                Text("保存或切换将进行真实模型调用，可能收费。验证失败时保留原 Key 和绑定。切换模型无需重新输入 Key。")
                    .font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
                if busy { HStack { ProgressView(); Button("取消验证", role: .cancel) { operation?.cancel() } } }
                Text(message).font(.subheadline).textSelection(.enabled)
            }
            UtilityCard {
                Text("调用与隐私").font(.headline)
                Text(budget).font(.subheadline)
                Text("Key 不写入普通偏好或日志。截图本地识别，仅主动提交的文字发送到供应商；当前 Key、常见凭据及邮箱会先按规则脱敏，规则不保证发现所有隐私。")
                    .font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
                Button("刷新会话预算") { Task { await refreshBudget() } }
            }
        }
        .task(id: provider) { await loadBindings() }
        .onDisappear { operation?.cancel(); candidateKey = "" }
    }
    private func modelField(_ title: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.bold())
            TextField("填写官方模型 ID", text: value).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(busy)
                .utilityField()
            if !catalogue.isEmpty {
                Menu("从目录选择") {
                    ForEach(catalogue, id: \.id) { item in Button(item.displayName ?? item.id) { value.wrappedValue = item.id } }
                }.disabled(busy)
            }
        }
    }
    private func loadBindings() async {
        let selected = provider
        candidateKey = ""; catalogue = []
        hasSavedKey = false; screenshotModel = ""; subtitleModel = ""
        message = "正在读取此供应商的已保存配置…"
        do {
            let models = try await app.services.configurations.models(provider: selected)
            guard !Task.isCancelled, provider == selected else { return }
            hasSavedKey = !models.isEmpty
            screenshotModel = models[.discordScreenshot] ?? ""
            subtitleModel = models[.videoSubtitle] ?? ""
            message = hasSavedKey ? "已读取模型绑定；切换模型会先验证。" : "尚未配置此供应商，请输入 Key 和模型。"
        } catch {
            if !Task.isCancelled, provider == selected { message = UserFacingError.text(error) }
        }
        await refreshBudget()
    }
    private func refreshBudget() async {
        let snapshot = await app.services.budget.snapshot()
        budget = "本次会话已预留 \(snapshot.attempts) 次请求、\(snapshot.reservedOutputTokens) 输出 tokens。"
    }
    private func perform(_ body: @escaping @MainActor () async throws -> String) {
        guard !busy else { return }
        busy = true
        message = "正在验证，请稍候…"
        operation = Task {
            defer { busy = false; operation = nil }
            do { message = try await body() }
            catch { message = UserFacingError.text(error) }
            await refreshBudget()
        }
    }
    private func discoverModels() {
        let selected = provider, suppliedKey = candidateKey
        perform {
            let result: [AIModel]
            if suppliedKey.isEmpty {
                result = try await app.services.configurations.listModels(provider: selected)
            } else {
                result = try await app.services.configurations.discoverModels(provider: selected, candidateKey: APIKey(suppliedKey))
            }
            try Task.checkCancellation()
            catalogue = result
            return "已取得 \(result.count) 个模型。保存时仍会验证所选模型的生成能力。"
        }
    }
    private func saveKey() {
        let selected = provider, suppliedKey = candidateKey
        let bindings: [TranslationFeature: String] = [.discordScreenshot: screenshotModel, .videoSubtitle: subtitleModel]
        perform {
            try await app.services.configurations.saveKey(provider: selected, key: APIKey(suppliedKey), models: bindings)
            candidateKey = ""; hasSavedKey = true
            Task { await app.recheckKey(selected) }
            return "已验证并保存共享 Key 和两个模型绑定。"
        }
    }
    private func switchModel(_ feature: TranslationFeature, model: String) {
        let selected = provider
        perform {
            try await app.services.configurations.switchModel(provider: selected, feature: feature, model: model)
            Task { await app.recheckKey(selected) }
            return "已验证并切换模型，继续使用已有共享 Key。"
        }
    }
}

/// Settings hub: two sub-pages so Keys and appearance no longer share one long scroll.
@MainActor struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(AppearanceStore.self) private var appearance
    @Environment(WallpaperStore.self) private var wallpaper
    var body: some View {
        WorkspacePage {
            PageHeader(title: "设置", subtitle: "AI 供应商与模型 · 外观与壁纸")
            NavigationLink {
                ProviderSettingsView().navigationTitle("AI 供应商与模型").navigationBarTitleDisplayMode(.inline)
            } label: {
                SettingsEntry(icon: "key.horizontal", title: "AI 供应商与模型",
                              detail: ProviderID.allCases.map { "\($0.title) \(app.status(of: $0).title)" }.joined(separator: " · "))
            }
            .buttonStyle(PressableCardStyle())
            NavigationLink {
                AppearanceSettingsView().navigationTitle("外观与壁纸").navigationBarTitleDisplayMode(.inline)
            } label: {
                SettingsEntry(icon: "paintpalette", title: "外观与壁纸",
                              detail: "界面透明度 \(Int((appearance.panelTransparency * 100).rounded()))% · \(wallpaperTitle)")
            }
            .buttonStyle(PressableCardStyle())
        }
    }
    private var wallpaperTitle: String {
        switch wallpaper.mode { case .custom: "自定义壁纸"; case .bundled: "默认壁纸"; case .plain: "纯色背景" }
    }
}

@MainActor private struct SettingsEntry: View {
    let icon: String
    let title: String
    let detail: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.body.weight(.semibold)).foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(UtilityTheme.deepGradient, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(UtilityTheme.ink)
                Text(detail).font(.caption).foregroundStyle(UtilityTheme.inkSecondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(UtilityTheme.inkSecondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .glassSurface(RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

/// Cold-start Key status of all providers, shown at the top of the provider page.
@MainActor private struct KeyStatusCard: View {
    @EnvironmentObject private var app: AppModel
    var body: some View {
        UtilityCard {
            HStack {
                Text("Key 状态").font(.headline)
                Spacer()
                Button("重新检测") { Task { await app.checkAllKeys() } }.buttonStyle(.bordered).controlSize(.small)
            }
            ForEach(ProviderID.allCases, id: \.self) { provider in
                let status = app.status(of: provider)
                HStack(spacing: 8) {
                    Text(provider.title).font(.subheadline.weight(.semibold)).foregroundStyle(UtilityTheme.ink)
                    Spacer()
                    if status == .checking || status == .unknown { ProgressView().controlSize(.mini) }
                    else { Circle().fill(status.color).frame(width: 7, height: 7) }
                    Text(status.title).font(.subheadline.weight(.semibold)).foregroundStyle(status.color)
                }
                .accessibilityElement(children: .combine)
            }
            Text("每次冷启动用已保存的 Key 读取模型目录来检测（不生成内容，每家占用一次会话调用额度）。“可用”不保证生成一定成功，例如余额不足时仍可能失败。")
                .font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
        }
    }
}

/// Appearance and wallpaper (Settings → 外观与壁纸).
@MainActor struct AppearanceSettingsView: View {
    var body: some View {
        WorkspacePage {
            PageHeader(title: "外观与壁纸", subtitle: "界面透明度 · 壁纸遮罩 · 自定义壁纸")
            AppearanceSettingsCard()
            WallpaperSettingsCard()
        }
    }
}
