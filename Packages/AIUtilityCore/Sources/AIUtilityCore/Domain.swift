import Foundation

public enum ProviderID: String, Codable, Sendable, CaseIterable {
    case deepSeek, anthropic, openAI
}

public enum TranslationFeature: String, Codable, Sendable, CaseIterable {
    case discordScreenshot, videoSubtitle
}

/// Deliberately has no public raw-value property and redacts debugger reflection.
/// Swift/Foundation cannot guarantee zeroing every copy of a String in memory.
public struct APIKey: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let value: String

    public init(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 4096,
              value.unicodeScalars.allSatisfy({ (33...126).contains($0.value) })
        else { throw AIUtilityError.invalidCredential }
        self.value = value
    }

    public func withValue<T>(_ body: (String) throws -> T) rethrows -> T { try body(value) }
    public var description: String { "<APIKey: redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["value": "<redacted>"]) }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// Stored as ONE atomic Keychain item per provider. Never persist this to a file.
public struct ProviderConfiguration: Codable, Sendable, CustomStringConvertible, CustomReflectable {
    public let key: APIKey
    public let models: [TranslationFeature: String]
    public init(key: APIKey, models: [TranslationFeature: String]) {
        self.key = key
        self.models = models
    }
    public var description: String { "<ProviderConfiguration: redacted>" }
    public var customMirror: Mirror { Mirror(self, children: ["configuration": "<redacted>"]) }
}

public struct AIModel: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String?
    public init(id: String, displayName: String? = nil) { self.id = id; self.displayName = displayName }
}

public enum AIUtilityError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidCredential, unauthorized, forbidden, modelUnavailable, invalidRequest
    case quotaExceeded, rateLimited(retryAfter: TimeInterval?), overloaded
    case server(status: Int), transport, timeout, cancelled, malformedResponse
    case outputTruncated, contentRejected, budgetExceeded, notConfigured, configurationBusy
    case storageFailure, privacyViolation, unsupportedPlatform

    // No vendor message, HTTP body, key, source text or translated text is retained.
    public var description: String {
        switch self {
        case .invalidCredential: "invalidCredential"
        case .unauthorized: "unauthorized"
        case .forbidden: "forbidden"
        case .modelUnavailable: "modelUnavailable"
        case .invalidRequest: "invalidRequest"
        case .quotaExceeded: "quotaExceeded"
        case .rateLimited: "rateLimited"
        case .overloaded: "overloaded"
        case .server(let status): "server(\(status))"
        case .transport: "transport"
        case .timeout: "timeout"
        case .cancelled: "cancelled"
        case .malformedResponse: "malformedResponse"
        case .outputTruncated: "outputTruncated"
        case .contentRejected: "contentRejected"
        case .budgetExceeded: "budgetExceeded"
        case .notConfigured: "notConfigured"
        case .configurationBusy: "configurationBusy"
        case .storageFailure: "storageFailure"
        case .privacyViolation: "privacyViolation"
        case .unsupportedPlatform: "unsupportedPlatform"
        }
    }

    public static func sanitized(_ error: any Error) -> AIUtilityError {
        if Task.isCancelled || error is CancellationError { return .cancelled }
        if let error = error as? AIUtilityError { return error }
        if let error = error as? URLError {
            if error.code == .cancelled { return .cancelled }
            if error.code == .timedOut { return .timeout }
        }
        return .transport
    }
}

public struct GenerationRequest: Sendable, CustomStringConvertible, CustomReflectable {
    public let model: String
    public let instructions: String
    public let text: String
    public let maxOutputTokens: Int
    public init(model: String, instructions: String, text: String, maxOutputTokens: Int = 1024) throws {
        guard !model.isEmpty, model.utf8.count <= 256,
              !instructions.isEmpty, !text.isEmpty,
              instructions.utf8.count + text.utf8.count <= 32_768,
              (16...8192).contains(maxOutputTokens) else { throw AIUtilityError.invalidRequest }
        self.model = model; self.instructions = instructions; self.text = text
        self.maxOutputTokens = maxOutputTokens
    }
    public var description: String { "<GenerationRequest: redacted>" }
    public var customMirror: Mirror { Mirror(self, children: ["request": "<redacted>"]) }
}

public struct GenerationResult: Sendable, CustomStringConvertible, CustomReflectable {
    public let text: String
    public let outputTokens: Int?
    public init(text: String, outputTokens: Int? = nil) { self.text = text; self.outputTokens = outputTokens }
    public var description: String { "<GenerationResult: redacted>" }
    public var customMirror: Mirror { Mirror(self, children: ["result": "<redacted>"]) }
}

public protocol AIProviderAdapter: Sendable {
    var provider: ProviderID { get }
    func listModels(key: APIKey, timeout: TimeInterval,
                    beforeRequest: @escaping @Sendable () async throws -> Void) async throws -> [AIModel]
    func generate(_ request: GenerationRequest, key: APIKey, timeout: TimeInterval) async throws -> GenerationResult
}

/// Implementations must replace a complete record atomically or leave the old record intact.
/// Synchronous operations keep the final cancellation check and commit in one actor turn.
public protocol CredentialStore: Sendable {
    func load(provider: ProviderID) throws -> ProviderConfiguration?
    func replace(provider: ProviderID, configuration: ProviderConfiguration) throws
}
