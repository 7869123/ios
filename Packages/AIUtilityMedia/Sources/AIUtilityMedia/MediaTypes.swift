import Foundation

public enum MediaError: Error, Codable, Sendable, Equatable {
    public enum Restriction: String, Codable, Sendable { case membership, payment, region, drm, permission }
    case invalidInput, invalidURL, unsupportedSource, invalidSelection, invalidState
    case notFound, outputMissing, requiresLogin, notConfigured
    case accessRestricted(Restriction)
    case rateLimited(retryAfter: TimeInterval?)
    case network, timeout, storageFull, storageUnavailable
    case parsingChanged, unsupportedFormat, unsupportedPlatform
    case resourceLimitExceeded, integrityMismatch, cleanupFailed, cancelled

    static func safe(_ error: any Error) -> MediaError {
        if let value = error as? MediaError { return value }
        if error is CancellationError { return .cancelled }
        if let value = error as? URLError {
            if value.code == .cancelled { return .cancelled }
            if value.code == .timedOut { return .timeout }
            if value.code == .userAuthenticationRequired || value.code == .userCancelledAuthentication { return .requiresLogin }
            if [URLError.Code.serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired].contains(value.code) {
                return .accessRestricted(.permission)
            }
            return .network
        }
        let value = error as NSError
        if value.domain == NSCocoaErrorDomain {
            if value.code == CocoaError.Code.fileWriteOutOfSpace.rawValue { return .storageFull }
            return .storageUnavailable
        }
        return .network
    }
}

public enum MediaSource: String, Codable, Sendable, CaseIterable { case bilibili, x, pixiv, direct }

public struct MediaItemID: Codable, Sendable, Hashable {
    public let source: MediaSource
    public let value: String
    public init(source: MediaSource, value: String) throws(MediaError) {
        guard !value.isEmpty, value.utf8.count <= 256,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { throw .invalidInput }
        self.source = source; self.value = value
    }
}

public struct MediaVariant: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable { case image, video, audio, ugoira }
    public let id: String
    public let kind: Kind
    public let qualityLabel: String
    public let width: Int?
    public let height: Int?
    public let estimatedBytes: Int64?
    public let fileExtension: String
    public let requiresAssembly: Bool
    public init(id: String, kind: Kind, qualityLabel: String, width: Int? = nil, height: Int? = nil,
                estimatedBytes: Int64? = nil, fileExtension: String, requiresAssembly: Bool = false) throws(MediaError) {
        guard !id.isEmpty, id.utf8.count <= 256, qualityLabel.utf8.count <= 256,
              width.map({ $0 > 0 && $0 <= 100_000 }) ?? true,
              height.map({ $0 > 0 && $0 <= 100_000 }) ?? true,
              estimatedBytes.map({ $0 > 0 }) ?? true,
              Self.extensions.contains(fileExtension) else { throw .invalidInput }
        self.id = id; self.kind = kind; self.qualityLabel = qualityLabel
        self.width = width; self.height = height; self.estimatedBytes = estimatedBytes
        self.fileExtension = fileExtension; self.requiresAssembly = requiresAssembly
    }
    static let extensions: Set<String> = ["jpg", "png", "gif", "webp", "mp4", "mov", "webm", "mp3", "wav", "ogg", "zip", "json"]
    func validate() throws(MediaError) {
        _ = try MediaVariant(id: id, kind: kind, qualityLabel: qualityLabel, width: width, height: height,
                             estimatedBytes: estimatedBytes, fileExtension: fileExtension, requiresAssembly: requiresAssembly)
    }
}

public struct MediaItem: Sendable, Identifiable {
    public let id: MediaItemID
    public let title: String
    public let variants: [MediaVariant]
    public init(id: MediaItemID, title: String, variants: [MediaVariant]) throws(MediaError) {
        guard !variants.isEmpty, variants.count <= 64, title.utf8.count <= 512,
              !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              Set(variants.map(\.id)).count == variants.count else { throw .invalidInput }
        _ = try MediaItemID(source: id.source, value: id.value)
        for variant in variants { try variant.validate() }
        self.id = id; self.title = title; self.variants = variants
    }
}

public enum MediaSelection: Sendable, Hashable, Codable {
    case automatic
    case variant(itemID: MediaItemID, variantID: String)
}

public struct SiteOptions: Sendable, Hashable, Codable {
    public var bilibili: BilibiliOptions
    public var pixiv: PixivOptions
    public init(bilibili: BilibiliOptions = .init(), pixiv: PixivOptions = .init()) {
        self.bilibili = bilibili; self.pixiv = pixiv
    }
    enum CodingKeys: String, CodingKey { case bilibili, pixiv }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        bilibili = try values.decodeIfPresent(BilibiliOptions.self, forKey: .bilibili) ?? .init()
        pixiv = try values.decodeIfPresent(PixivOptions.self, forKey: .pixiv) ?? .init()
    }
    func effective(source: MediaSource, ugoira: Bool = false) -> SiteOptions {
        SiteOptions(bilibili: source == .bilibili ? bilibili : .init(),
                    pixiv: source == .pixiv && ugoira ? pixiv : .init())
    }
}

public struct BilibiliOptions: Sendable, Hashable, Codable {
    public var allParts: Bool
    public init(allParts: Bool = false) { self.allParts = allParts }
    enum CodingKeys: String, CodingKey { case allParts }
    public init(from decoder: any Decoder) throws {
        allParts = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(Bool.self, forKey: .allParts) ?? false
    }
}

public struct PixivOptions: Sendable, Hashable, Codable {
    public var keepUgoiraArchive: Bool
    public init(keepUgoiraArchive: Bool = false) { self.keepUgoiraArchive = keepUgoiraArchive }
    enum CodingKeys: String, CodingKey { case keepUgoiraArchive }
    public init(from decoder: any Decoder) throws {
        keepUgoiraArchive = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(Bool.self, forKey: .keepUgoiraArchive) ?? false
    }
}

public enum MediaAssembly: Sendable, Equatable {
    case passthrough, muxAudioVideo, ugoiraToGIF(keepOriginalArchive: Bool)
}

/// Sensitive requests are memory-only and never participate in reflection/logging.
public struct MediaComponent: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let id: String
    private let url: URL
    public init(id: String, url: URL) throws(MediaError) {
        try URLSafety.validate(url)
        guard !id.isEmpty, id.count <= 128 else { throw .invalidInput }
        self.id = id; self.url = url
    }
    func requestURL() -> URL { url }
    public var description: String { "MediaComponent([redacted])" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["request": "[redacted]"]) }
}

public struct MediaTransferPlan: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let itemID: MediaItemID
    public let variant: MediaVariant
    public let effectiveOptions: SiteOptions
    public let components: [MediaComponent]
    public let assembly: MediaAssembly
    public init(itemID: MediaItemID, variant: MediaVariant, effectiveOptions: SiteOptions = .init(),
                components: [MediaComponent], assembly: MediaAssembly = .passthrough) throws(MediaError) {
        guard !components.isEmpty, components.count <= 64,
              Set(components.map(\.id)).count == components.count else { throw .invalidInput }
        try variant.validate()
        self.itemID = itemID; self.variant = variant; self.effectiveOptions = effectiveOptions
        self.components = components; self.assembly = assembly
    }
    public var description: String { "MediaTransferPlan([redacted])" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["requests": "[redacted]"]) }
}

public struct DownloadID: Codable, Sendable, Hashable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}
public struct DownloadProgress: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable { case transfer, processing }
    public let attemptID: UUID
    public let phase: Phase
    public let bytesWritten: Int64
    public let totalBytes: Int64?
    public var fraction: Double? { totalBytes.flatMap { $0 > 0 ? min(1, Double(bytesWritten) / Double($0)) : nil } }
}
public struct DownloadedFile: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let fileName: String
    public let relativePath: String
    public let bytes: Int64
    public let kind: MediaVariant.Kind
    public let fileIdentity: UInt64?
    init(id: UUID, fileName: String, relativePath: String, bytes: Int64, kind: MediaVariant.Kind, fileIdentity: UInt64? = nil) {
        self.id = id; self.fileName = fileName; self.relativePath = relativePath
        self.bytes = bytes; self.kind = kind; self.fileIdentity = fileIdentity
    }
}
public enum DownloadState: Codable, Sendable, Equatable {
    case queued(position: Int), resolving, running(DownloadProgress), waitingToRetry(attempt: Int, delay: TimeInterval)
    case processing(DownloadProgress), committing, cancelling, interrupted
    case completed(files: [DownloadedFile]), duplicate(existing: DownloadID)
    case deletionIncomplete(remainingFiles: [DownloadedFile]), failed(MediaError), cancelled
    var terminal: Bool {
        switch self {
        case .completed, .duplicate, .deletionIncomplete, .failed, .cancelled, .interrupted: true
        default: false
        }
    }
    var files: [DownloadedFile] {
        switch self { case .completed(let files), .deletionIncomplete(let files): files; default: [] }
    }
}
public struct DownloadSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let id: DownloadID
    public let source: MediaSource?
    public let title: String
    public let state: DownloadState
    public let attemptID: UUID
    public let revision: UInt64
    public let createdAt: Date
    public let updatedAt: Date
    public let effectiveOptions: SiteOptions?
}
public struct DownloadQueueSnapshot: Sendable, Equatable {
    public let revision: UInt64
    public let tasks: [DownloadSnapshot]
    public let activeID: DownloadID?
    public let blockingError: MediaError?
}
public struct DownloadRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: DownloadID
    public let source: MediaSource?
    public let state: DownloadState
    public let attemptID: UUID
    public let effectiveOptions: SiteOptions?
    public let createdAt: Date
    public let updatedAt: Date
}
public struct EnqueueReceipt: Sendable, Equatable {
    public enum Disposition: Sendable, Equatable { case created, alreadyQueued, alreadyCompleted, retryRequired }
    public let id: DownloadID
    public let disposition: Disposition
}
public enum CancelResult: Sendable, Equatable { case accepted, alreadyTerminal, tooLate, notFound }
public struct DownloadCapabilities: Sendable, Equatable {
    public let sources: Set<MediaSource>
    public let supportsDownloadResume: Bool
    public let supportsAllBilibiliParts: Bool
    public let assemblies: Set<String>
    public let localTools: Set<String>
}
public struct FileDeletionFailure: Sendable, Equatable {
    public let fileID: UUID
    public let error: MediaError
}
public struct DeleteResult: Sendable, Equatable {
    public let id: DownloadID
    public let deleted: [DownloadedFile]
    public let alreadyMissing: [DownloadedFile]
    public let failed: [FileDeletionFailure]
    public var fullyDeleted: Bool { failed.isEmpty }
}

public struct DownloadPolicy: Sendable {
    public let requestTimeout: TimeInterval
    public let taskTimeout: TimeInterval
    public let minimumRequestInterval: TimeInterval
    public let maxRetries: Int
    public let maxRedirects: Int
    public let maxOutputs: Int
    public let maxFileBytes: Int64
    public let maxTaskBytes: Int64
    public let minimumFreeBytes: Int64
    public let maxMetadataBytes: Int
    public let maxRequestsPerTask: Int
    public var maxConcurrent: Int { 1 }
    public init(requestTimeout: TimeInterval = 30, taskTimeout: TimeInterval = 1800,
                minimumRequestInterval: TimeInterval = 2, maxRetries: Int = 2, maxRedirects: Int = 5,
                maxOutputs: Int = 64, maxFileBytes: Int64 = 1_073_741_824,
                maxTaskBytes: Int64 = 2_147_483_648, minimumFreeBytes: Int64 = 134_217_728,
                maxMetadataBytes: Int = 4_194_304, maxRequestsPerTask: Int = 128) {
        self.requestTimeout = requestTimeout; self.taskTimeout = taskTimeout
        self.minimumRequestInterval = minimumRequestInterval; self.maxRetries = maxRetries
        self.maxRedirects = maxRedirects; self.maxOutputs = maxOutputs
        self.maxFileBytes = maxFileBytes; self.maxTaskBytes = maxTaskBytes; self.minimumFreeBytes = minimumFreeBytes
        self.maxMetadataBytes = maxMetadataBytes; self.maxRequestsPerTask = maxRequestsPerTask
    }
    func validate() throws(MediaError) {
        guard requestTimeout.isFinite, requestTimeout > 0, requestTimeout <= 300,
              taskTimeout.isFinite, taskTimeout > 0, taskTimeout <= 7200,
              minimumRequestInterval.isFinite, minimumRequestInterval >= 0, minimumRequestInterval <= 300,
              (0...5).contains(maxRetries), (0...10).contains(maxRedirects), (1...64).contains(maxOutputs),
              maxFileBytes > 0, maxFileBytes <= 8_589_934_592, maxTaskBytes >= maxFileBytes,
              maxTaskBytes <= 34_359_738_368, minimumFreeBytes >= 0,
              (1...4_194_304).contains(maxMetadataBytes), (1...1024).contains(maxRequestsPerTask) else { throw .invalidInput }
    }
}
