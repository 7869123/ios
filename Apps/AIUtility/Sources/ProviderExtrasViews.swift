import SwiftUI
import AIUtilityCore

extension ReasoningEffort {
    var title: String {
        switch self {
        case .auto: "自动（Auto）"; case .none: "不推理（None）"; case .minimal: "极低（Minimal）"; case .low: "低（Low）"
        case .medium: "中（Medium）"; case .high: "高（High）"; case .xhigh: "很高（XHigh）"; case .max: "最高（Max）"
        }
    }
}

/// Per-model reasoning effort and total output budget (Codex's TranslationPreferences). Only the efforts
/// verified for this exact model are offered; Auto sends no reasoning parameter.
@MainActor struct ReasoningSettingsCard: View {
    @EnvironmentObject private var app: AppModel
    let provider: ProviderID
    let model: String
    let featureTitle: String
    @State private var effort = ReasoningEffort.auto
    @State private var budget = 1024
    /// Last saved effort and output budget, to enable the save button only for real changes.
    @State private var saved: (effort: ReasoningEffort, budget: Int)?
    @State private var message: String?
    @State private var failed = false

    private var capabilities: ReasoningCapabilities { ReasoningCapabilities.forModel(model, provider: provider) }

    var body: some View {
        UtilityCard {
            HStack {
                Text("推理强度 · \(featureTitle)").font(.headline)
                Spacer()
                Text(model).font(.caption.monospaced()).foregroundStyle(UtilityTheme.inkSecondary).lineLimit(1)
            }
            let effortChoices = capabilities.efforts.count > 1
            if effortChoices {
                Picker("推理强度", selection: $effort) {
                    ForEach(capabilities.efforts, id: \.self) { Text($0.title).tag($0) }
                }
            } else {
                Text("这个模型只确认支持「自动」，不会发送推理参数；仍可调整总输出上限。")
                    .font(.subheadline).foregroundStyle(UtilityTheme.inkSecondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                    // Separate steps up and down so 4096 is not a cliff: 256 below it, 4096 above it.
                    Stepper("总输出上限 \(budget) tokens", onIncrement: { budget = Self.step(budget, up: true) },
                            onDecrement: { budget = Self.step(budget, up: false) })
                    Text("思考过程和译文共用这个上限；切换强度不会自动加大，避免悄悄多花钱。建议值约 \(capabilities.suggestedTotalOutputTokens)，仅供参考。")
                        .font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
                    Text("每次翻译都会按这个上限预留会话额度：本次会话共 \(AppModel.sessionOutputTokens) tokens，按当前上限最多约可翻译 \(min(AppModel.sessionAttempts, AppModel.sessionOutputTokens / max(budget, 1))) 次（Key 检测、模型目录和自动重试也会占用），完全退出并重新打开 App 后重置。")
                        .font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
                    if budget < capabilities.suggestedTotalOutputTokens, effort != .auto, effort != .none {
                        Text("上限低于建议值，高强度时译文可能被截断。")
                            .font(.caption).foregroundStyle(UtilityTheme.poc)
                    }
            }
            if effortChoices {
                Text(ReasoningCapabilities.explanation).font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
                Text(ReasoningCapabilities.lowExplanation).font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
                Text(ReasoningCapabilities.highExplanation).font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
            }
            Button(effortChoices ? "保存推理设置" : "保存输出上限") { save() }
                .buttonStyle(PrimaryActionStyle())
                .disabled(saved.map { $0.effort == effort && $0.budget == budget } ?? false)
            if let message {
                Text(message).font(.caption).foregroundStyle(failed ? UtilityTheme.danger : UtilityTheme.inkSecondary)
            }
        }
        .task(id: "\(provider.rawValue)/\(model)") { await load() }
    }

    /// 16…4096 moves in 256s (first step up from below 256 lands on 256), 4096…65536 in 4096s.
    static func step(_ value: Int, up: Bool) -> Int {
        if up { return value < 256 ? 256 : value < 4096 ? min(4096, value + 256) : min(65_536, value + 4096) }
        return value > 4096 ? max(4096, value - 4096) : value > 256 ? max(256, value - 256) : 16
    }

    private func load() async {
        message = nil; failed = false
        do {
            let value = try await app.services.preferences.reasoningSettings(provider: provider, model: model)
            saved = (value.effort, value.totalOutputTokens); effort = value.effort; budget = value.totalOutputTokens
        } catch { message = "推理设置读取失败。"; failed = true }
    }

    private func save() {
        let effort = effort, budget = budget, provider = provider, model = model
        Task {
            do {
                try await app.services.preferences.saveReasoning(effort, provider: provider, model: model, totalOutputTokens: budget)
                saved = (effort, budget)
                message = "已保存。下次翻译开始生效。"; failed = false
            } catch { message = "保存失败：这个模型不支持所选强度，或上限不在 16–65536 之间。"; failed = true }
        }
    }
}

/// DeepSeek official balance, low-balance thresholds per currency, manual refresh.
@MainActor struct DeepSeekBalanceCard: View {
    @EnvironmentObject private var app: AppModel
    @State private var snapshot: BalanceSnapshot?
    @State private var thresholds: [BalanceCurrency: String] = [:]
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        UtilityCard {
            HStack {
                Text("DeepSeek 余额").font(.headline)
                Spacer()
                Button { refresh() } label: { Label("刷新", systemImage: "arrow.clockwise") }.disabled(busy)
            }
            if let balance = snapshot?.balance {
                ForEach(balance.amounts, id: \.currency) { amount in
                    HStack {
                        Text(amount.currency.rawValue).font(.subheadline.monospaced())
                        Spacer()
                        Text(Self.money(amount.total)).font(.title3.monospacedDigit().bold())
                    }
                    Text("赠送 \(Self.money(amount.granted)) · 充值 \(Self.money(amount.toppedUp))")
                        .font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
                }
                if !balance.isAvailable {
                    Label("DeepSeek 表示当前余额不足以调用 API。", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(UtilityTheme.danger)
                }
            } else {
                Text("还没有查询过余额。").font(.subheadline).foregroundStyle(UtilityTheme.inkSecondary)
            }
            if let updated = snapshot?.updatedAt {
                Text("更新于 \(updated.formatted(date: .abbreviated, time: .shortened))\(isStale ? "（最近一次刷新失败，显示的是之前的结果）" : "")")
                    .font(.caption).foregroundStyle(isStale ? UtilityTheme.poc : UtilityTheme.inkSecondary)
            }
            Divider()
            Text("低余额提醒").font(.subheadline.bold())
            ForEach(BalanceCurrency.allCases, id: \.self) { currency in
                HStack {
                    Text(currency.rawValue).font(.subheadline.monospaced()).frame(width: 44, alignment: .leading)
                    TextField("不提醒", text: Binding(get: { thresholds[currency] ?? "" }, set: { thresholds[currency] = $0 }))
                        .keyboardType(.decimalPad).utilityField()
                    Button("保存") { saveThreshold(currency) }.buttonStyle(.bordered)
                }
            }
            Text("设置了阈值时，App 在前台最多每 5 分钟查询一次（不设阈值就不查询，也不占用翻译的会话请求次数）；余额低于阈值时在首页提醒，关闭前一直保留，回到阈值以上后再次低于才会再提醒。两种币种分别设置，不做汇率换算。查询使用已保存的 DeepSeek Key，不调用模型、不产生费用。")
                .font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
            if let message { Text(message).font(.caption).foregroundStyle(UtilityTheme.inkSecondary) }
            if snapshot?.alertPersistenceFailed == true {
                Text("提醒状态没能保存，可能会重复提醒。").font(.caption).foregroundStyle(UtilityTheme.poc)
            }
        }
        .task { await load() }
    }

    private var isStale: Bool { if case .failed = snapshot?.status { true } else { false } }

    static func money(_ value: Decimal) -> String {
        value.formatted(.number.precision(.fractionLength(2)))
    }

    private func load() async {
        snapshot = await app.services.deepSeekBalance.snapshot()
        for currency in BalanceCurrency.allCases {
            if let value = try? await app.services.deepSeekBalance.threshold(for: currency) {
                thresholds[currency] = "\(value)"
            }
        }
    }

    private func refresh() {
        busy = true; message = nil
        Task {
            defer { busy = false }
            do { snapshot = try await app.services.deepSeekBalance.refresh() }
            catch {
                snapshot = await app.services.deepSeekBalance.snapshot()
                message = UserFacingError.text(error)
            }
        }
    }

    private func saveThreshold(_ currency: BalanceCurrency) {
        // Whole input must be a plain number ("5", "5.5"; a decimal comma is accepted). Decimal(string:) alone
        // reads only a valid prefix, so "5,5" would silently become 5 and "12abc" 12.
        let text = (thresholds[currency] ?? "").trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let value: Decimal?
        if text.isEmpty { value = nil }
        else if text.range(of: #"^[0-9]{1,9}(\.[0-9]{1,4})?$"#, options: .regularExpression) != nil,
                let parsed = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) {
            value = parsed; thresholds[currency] = "\(parsed)"
        } else { message = "请输入不小于 0 的数字（最多 4 位小数），留空表示不提醒。"; return }
        Task {
            do {
                try await app.services.deepSeekBalance.setThreshold(value, for: currency)
                message = value == nil ? "已关闭 \(currency.rawValue) 低余额提醒。" : "已保存 \(currency.rawValue) 提醒阈值。"
            } catch { message = "阈值保存失败。" }
        }
    }
}

/// Actual OpenAI response usage recorded by this app, per response model.
@MainActor struct OpenAIUsageCard: View {
    @EnvironmentObject private var app: AppModel
    @State private var snapshot: OpenAIUsageSnapshot?

    var body: some View {
        UtilityCard {
            HStack {
                Text("OpenAI 用量").font(.headline)
                Spacer()
                Button { Task { snapshot = await app.services.openAIUsage.snapshot() } } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
            }
            if let snapshot {
                section("本次打开 App 以来", snapshot.session)
                if let lifetime = snapshot.lifetime {
                    section("本机累计", lifetime)
                } else {
                    Text("本机累计记录读取失败（不是零用量）。").font(.caption).foregroundStyle(UtilityTheme.poc)
                }
                if snapshot.persistence == .writeFailed {
                    Text("最近的用量没能写入本机记录。").font(.caption).foregroundStyle(UtilityTheme.poc)
                }
                if snapshot.untrackedResponses > 0 {
                    Text("有 \(snapshot.untrackedResponses) 次响应没有返回用量，未计入。").font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
                }
            }
            Text(OpenAIUsageSnapshot.scope).font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
        }
        .task { snapshot = await app.services.openAIUsage.snapshot() }
    }

    @ViewBuilder private func section(_ title: String, _ models: [String: ModelTokenTotals]) -> some View {
        Text(title).font(.subheadline.bold())
        if models.isEmpty {
            Text("暂无记录。").font(.caption).foregroundStyle(UtilityTheme.inkSecondary)
        } else {
            ForEach(models.keys.sorted(), id: \.self) { model in
                if let totals = models[model] {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(model).font(.caption.monospaced()).lineLimit(1)
                            Spacer()
                            Text("\(totals.totalTokens) tokens").font(.caption.monospacedDigit().bold())
                        }
                        Text("输入 \(totals.inputTokens) · 输出 \(totals.outputTokens)\(totals.responsesWithReasoningDetail > 0 ? "（含推理 \(totals.reasoningTokens)）" : "") · \(totals.responsesWithActualUsage) 次响应")
                            .font(.caption2).foregroundStyle(UtilityTheme.inkSecondary)
                    }
                }
            }
        }
    }
}
