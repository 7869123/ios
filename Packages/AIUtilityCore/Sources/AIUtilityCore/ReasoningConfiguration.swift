import Foundation

public enum ReasoningEffort: String, Codable, Sendable, CaseIterable {
    case auto, none, minimal, low, medium, high, xhigh, max
}

public struct ReasoningCapabilities: Sendable, Equatable {
    public let efforts: [ReasoningEffort]
    public let parameterDescription: String
    public let suggestedTotalOutputTokens: Int
    public static let explanation = "推理强度越高，通常需要更长的处理时间，并可能消耗更多 Token，但有助于提高复杂内容的理解和翻译准确性。实际效果因模型而异。"
    public static let lowExplanation = "Low：优先响应速度，适合实时字幕。"
    public static let highExplanation = "High 及更高：可能增加延迟和 API 费用；不保证翻译一定更准确。"

    /// Exact documented aliases/snapshots only. An unknown/new model remains usable with Auto.
    public static func forModel(_ model: String, provider: ProviderID) -> ReasoningCapabilities {
        let levels: [ReasoningEffort]
        let parameter: String
        switch provider {
        case .openAI:
            parameter = "Responses reasoning.effort; max_output_tokens includes reasoning and visible output."
            switch model {
            case "gpt-5.1", "gpt-5.1-2025-11-13": levels = [.auto, .none, .low, .medium, .high]
            case "gpt-5.4", "gpt-5.4-2026-03-05": levels = [.auto, .none, .low, .medium, .high, .xhigh]
            case "o3", "o3-2025-04-16", "o4-mini", "o4-mini-2025-04-16": levels = [.auto, .low, .medium, .high]
            default: levels = [.auto]
            }
        case .deepSeek:
            parameter = "Chat Completions reasoning_effort; max_tokens includes thinking and visible output."
            levels = ["deepseek-flash", "deepseek-v4-pro"].contains(model) ? [.auto, .none, .low, .high, .max] : [.auto]
        case .anthropic:
            parameter = "Messages output_config.effort with adaptive thinking; max_tokens includes thinking and visible output."
            switch model {
            case "claude-opus-4-6": levels = [.auto, .low, .medium, .high, .max]
            case "claude-sonnet-4-6": levels = [.auto, .low, .medium, .high, .max]
            case "claude-opus-4-7", "claude-opus-4-8", "claude-opus-5", "claude-opus-5-5", "claude-sonnet-5", "claude-sonnet-5-5", "claude-haiku-5-5":
                levels = [.auto, .low, .medium, .high, .xhigh, .max]
            default: levels = [.auto]
            }
        }
        return ReasoningCapabilities(efforts: levels, parameterDescription: levels.count == 1 ? "Only Auto is verified for this model; no reasoning parameter is sent." : parameter,
                                     suggestedTotalOutputTokens: levels.count == 1 ? 1024 : 32_768)
    }
}
