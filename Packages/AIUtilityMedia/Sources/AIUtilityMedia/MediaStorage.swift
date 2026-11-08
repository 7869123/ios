import Foundation

struct StoredTask: Codable, Sendable {
    let id: DownloadID
    var ordinal: UInt64
    let alias: String
    let selection: MediaSelection // Digested identities only; original selection stays in RuntimeInput.
    let options: SiteOptions
    var identity: String?
    var source: MediaSource?
    var effectiveOptions: SiteOptions?
    var state: DownloadState
    var attemptID: UUID
    let createdAt: Date
    var updatedAt: Date
    var journal: [DownloadedFile]?
    func snapshot(revision: UInt64) -> DownloadSnapshot {
        DownloadSnapshot(id: id, source: source, title: "Media download", state: state, attemptID: attemptID,
                         revision: revision, createdAt: createdAt, updatedAt: updatedAt, effectiveOptions: effectiveOptions)
    }
    var record: DownloadRecord {
        DownloadRecord(id: id, source: source, state: state, attemptID: attemptID, effectiveOptions: effectiveOptions,
                       createdAt: createdAt, updatedAt: updatedAt)
    }
}
struct Ownership: Codable, Sendable {
    var files: [DownloadedFile]
    var deleting: Bool
}
struct MediaManifest: Codable, Sendable {
    var schemaVersion = 1
    var revision: UInt64 = 0
    var nextOrdinal: UInt64 = 0
    var tasks: [StoredTask] = []
    var ownership: [String: Ownership] = [:]
}

protocol ManifestStore: Sendable {
    func load() throws -> MediaManifest
    func save(_ manifest: MediaManifest) throws
}
protocol MediaFiles: Sendable {
    func staging(_ id: DownloadID, attempt: UUID) throws -> URL
    func cleanup(_ id: DownloadID, attempt: UUID) throws
    func inspect(_ url: URL, response: WireResponse, variant: MediaVariant, policy: DownloadPolicy) throws -> Int64
    func checkSpace(_ required: Int64) throws
    func publish(_ staging: URL, files: [DownloadedFile]) throws
    func locate(_ file: DownloadedFile) throws -> URL
    func remove(_ file: DownloadedFile) throws -> Bool
}

/// Serial calls from DownloadManager; an atomic complete manifest is the transaction boundary.
final class DiskManifestStore: ManifestStore, @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    init(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        url = root.appendingPathComponent("manifest.json")
    }
    func load() throws -> MediaManifest {
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: url.path) else { return MediaManifest() }
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true, (values.fileSize ?? 0) <= 16_777_216 else { throw MediaError.storageUnavailable }
            let manifest = try JSONDecoder().decode(MediaManifest.self, from: Data(contentsOf: url))
            guard manifest.schemaVersion == 1, manifest.tasks.count <= 10_000,
                  Set(manifest.tasks.map(\.id)).count == manifest.tasks.count else { throw MediaError.storageUnavailable }
            return manifest
        }
    }
    func save(_ manifest: MediaManifest) throws {
        try lock.withLock {
            let data = try JSONEncoder().encode(manifest)
            guard data.count <= 16_777_216 else { throw MediaError.resourceLimitExceeded }
            try data.write(to: url, options: .atomic)
        }
    }
}

struct SandboxFiles: MediaFiles {
    let root: URL
    let cache: URL
    init(root: URL, cache: URL) throws {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.cache = cache.resolvingSymlinksInPath().standardizedFileURL
        for url in [self.root, self.cache, self.root.appendingPathComponent("outputs")] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Self.noLinks(url)
        }
        let a = try FileManager.default.attributesOfFileSystem(forPath: self.root.path)[.systemNumber] as? NSNumber
        let b = try FileManager.default.attributesOfFileSystem(forPath: self.cache.path)[.systemNumber] as? NSNumber
        guard let a, let b, a == b else { throw MediaError.storageUnavailable }
    }
    static func noLinks(_ url: URL) throws {
        var cursor = url.standardizedFileURL
        while cursor.path != "/", !cursor.path.isEmpty {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: cursor.path)) != nil { throw MediaError.storageUnavailable }
            let parent = cursor.deletingLastPathComponent()
            if parent == cursor { break }; cursor = parent
        }
    }
    func staging(_ id: DownloadID, attempt: UUID) throws -> URL {
        let path = cache.appendingPathComponent(id.rawValue.uuidString + "-" + attempt.uuidString, isDirectory: true)
        try Self.noLinks(path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }
    func cleanup(_ id: DownloadID, attempt: UUID) throws {
        let path = cache.appendingPathComponent(id.rawValue.uuidString + "-" + attempt.uuidString, isDirectory: true)
        try Self.noLinks(path)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
    func checkSpace(_ required: Int64) throws {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: root.path)
        guard let free = attributes[.systemFreeSize] as? NSNumber, free.int64Value >= required else { throw MediaError.storageFull }
    }
    func inspect(_ url: URL, response: WireResponse, variant: MediaVariant, policy: DownloadPolicy) throws -> Int64 {
        try Self.noLinks(url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0, size <= policy.maxFileBytes else { throw MediaError.resourceLimitExceeded }
        if let length = response.header("content-length").flatMap(Int64.init), length != size { throw MediaError.integrityMismatch }
        guard let format = MediaFormat.from(response.header("content-type")), format.ext == variant.fileExtension else {
            throw MediaError.unsupportedFormat
        }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        guard format.matches(try handle.read(upToCount: 64) ?? Data()) else { throw MediaError.integrityMismatch }
        return size
    }
    func publish(_ staging: URL, files: [DownloadedFile]) throws {
        guard let first = files.first else { throw MediaError.invalidInput }
        let target = try checked(first).deletingLastPathComponent()
        try Self.noLinks(staging); try Self.noLinks(target)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: staging, to: target)
    }
    private func checked(_ file: DownloadedFile) throws -> URL {
        let parts = file.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "outputs", UUID(uuidString: String(parts[1])) != nil,
              UUID(uuidString: String(parts[2])) != nil, parts[3] == Substring(file.fileName),
              !file.fileName.contains("\\"), !file.fileName.contains(":"),
              file.fileName.split(separator: ".").count == 2,
              UUID(uuidString: String(file.fileName.split(separator: ".")[0])) == file.id,
              MediaVariant.extensions.contains(String(file.fileName.split(separator: ".")[1])) else { throw MediaError.storageUnavailable }
        let url = root.appendingPathComponent(file.relativePath).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else { throw MediaError.storageUnavailable }
        try Self.noLinks(url)
        return url
    }
    func locate(_ file: DownloadedFile) throws -> URL {
        let url = try checked(file)
        guard FileManager.default.fileExists(atPath: url.path) else { throw MediaError.outputMissing }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.size] as? NSNumber)?.int64Value == file.bytes else { throw MediaError.integrityMismatch }
        if let identity = file.fileIdentity, (attrs[.systemFileNumber] as? NSNumber)?.uint64Value != identity { throw MediaError.integrityMismatch }
        return url
    }
    func remove(_ file: DownloadedFile) throws -> Bool {
        let url = try checked(file)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        _ = try locate(file) // Refuse to delete a replaced/non-owned file.
        try FileManager.default.removeItem(at: url)
        return true
    }
}

public struct DownloadConfiguration: Sendable {
    let root: URL
    let cache: URL
    let policy: DownloadPolicy
    let resolvers: [any MediaResolver]
    /// Roots must be dedicated descendants of this process's Documents/Caches directories.
    public init(storageRoot: URL? = nil, temporaryRoot: URL? = nil, policy: DownloadPolicy = .init(),
                resolvers: [any MediaResolver] = []) throws(MediaError) {
        do {
            try policy.validate()
            let manager = FileManager.default
            let documents = try manager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true).resolvingSymlinksInPath()
            let caches = try manager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true).resolvingSymlinksInPath()
            let root = (storageRoot ?? documents.appendingPathComponent("AIUtilityMedia", isDirectory: true)).resolvingSymlinksInPath()
            let cache = (temporaryRoot ?? caches.appendingPathComponent("AIUtilityMedia", isDirectory: true)).resolvingSymlinksInPath()
            guard root.isFileURL, cache.isFileURL,
                  root.standardizedFileURL.path.hasPrefix(documents.standardizedFileURL.path + "/"),
                  cache.standardizedFileURL.path.hasPrefix(caches.standardizedFileURL.path + "/") else { throw MediaError.invalidInput }
            try SandboxFiles.noLinks(root); try SandboxFiles.noLinks(cache)
            self.root = root; self.cache = cache; self.policy = policy; self.resolvers = resolvers
        } catch { throw MediaError.safe(error) }
    }
    init(testRoot: URL, policy: DownloadPolicy = .init()) throws {
        try policy.validate(); root = testRoot.appendingPathComponent("documents")
        cache = testRoot.appendingPathComponent("cache"); self.policy = policy; resolvers = []
    }
}
