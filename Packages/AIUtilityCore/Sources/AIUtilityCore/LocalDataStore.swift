import Foundation

public enum LocalRecord: String, Sendable {
    case translationPreferences, openAIUsage, deepSeekBalancePreferences
}

/// Only non-credential configuration and aggregate counters belong here. Never store source text.
/// A failed write must preserve the previous record. Use one service actor per record/namespace.
public protocol LocalDataStore: Sendable {
    func read(_ record: LocalRecord) throws -> Data?
    func write(_ data: Data, to record: LocalRecord) throws
}

public final class FileLocalDataStore: LocalDataStore, @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    public init(directory: URL) { self.directory = directory }

    public func read(_ record: LocalRecord) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        do {
            let url = try location(record, create: false)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 1_048_576 else { throw AIUtilityError.storageFailure }
            return try Data(contentsOf: url)
        } catch { throw AIUtilityError.storageFailure }
    }

    public func write(_ data: Data, to record: LocalRecord) throws {
        lock.lock(); defer { lock.unlock() }
        guard data.count <= 1_048_576 else { throw AIUtilityError.storageFailure }
        do {
            let url = try location(record, create: true)
            try data.write(to: url, options: .atomic)
        } catch { throw AIUtilityError.storageFailure }
    }

    private func location(_ record: LocalRecord, create: Bool) throws -> URL {
        guard directory.isFileURL else { throw AIUtilityError.storageFailure }
        // Resolve system aliases in the caller-provided parent, but never follow an owned record link.
        let parent = directory.resolvingSymlinksInPath()
        if create { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
        let url = parent.appendingPathComponent(record.rawValue + ".json")
        if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]),
           values.isSymbolicLink == true || values.isRegularFile == false { throw AIUtilityError.storageFailure }
        // resourceValues may fail for a dangling symbolic link.
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
            throw AIUtilityError.storageFailure
        }
        return url
    }
}
