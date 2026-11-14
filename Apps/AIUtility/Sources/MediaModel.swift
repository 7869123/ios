import SwiftUI
import Security
import UIKit
import AIUtilityMedia
import AIUtilityMediaApple

/// Owns the single download manager (one task at a time, FIFO) and mirrors its queue for the UI.
/// Site resolvers are switched on here; they have only been checked against offline samples, so the
/// UI labels site downloads as not yet tested on the live sites.
@MainActor final class MediaModel: ObservableObject {
    @Published private(set) var snapshot: DownloadQueueSnapshot?
    @Published private(set) var startupError: MediaError?
    @Published var lastError: MediaError?
    /// Non-error feedback for the last action (already queued or downloaded, re-paste needed, files kept).
    @Published var notice: String?
    private var manager: DownloadManager?
    private var listener: Task<Void, Never>?
    private var starting = false

    func start() async {
        guard manager == nil, !starting else { return }
        starting = true; defer { starting = false }
        do {
            // Pixiv Ugoira archives become GIFs on device (frame timeline rounded to 10 ms, total kept).
            let configuration = try DownloadConfiguration(sites: [.bilibili, .x, .pixiv], assembler: UgoiraAssembler())
            let manager = try await DownloadManager(configuration: configuration)
            self.manager = manager
            startupError = nil
            listener = Task { [weak self] in
                for await snapshot in await manager.updates() { self?.snapshot = snapshot }
            }
        } catch {
            startupError = error
        }
    }

    /// Returns true when the link was accepted into the queue.
    func enqueue(_ text: String, keepUgoiraArchive: Bool = false) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http" else {
            lastError = .invalidURL; return false
        }
        guard let manager else { lastError = startupError ?? .invalidState; return false }
        lastError = nil; notice = nil
        let options = SiteOptions(pixiv: PixivOptions(keepUgoiraArchive: keepUgoiraArchive))
        do {
            let receipt = try await manager.enqueue(link: url, options: options)
            switch receipt.disposition {
            case .created: break
            case .alreadyQueued: notice = "这个链接已经在队列里。"
            case .alreadyCompleted: notice = "这个链接已经下载过，可以在下方列表里导出。"
            case .retryRequired:
                // Same link as a failed, cancelled or interrupted task (e.g. after a restart, when links are
                // no longer in memory): the link is supplied again, so start that task over.
                try await manager.retry(receipt.id)
                notice = "已重新开始之前的同一个任务。"
            }
            return true
        } catch { lastError = error; return false }
    }

    func cancel(_ id: DownloadID) async { _ = await manager?.cancel(id) }

    func retry(_ id: DownloadID) async {
        guard let manager else { return }
        lastError = nil; notice = nil
        do { try await manager.retry(id) }
        catch MediaError.notConfigured {
            // Links are kept only in memory, never on disk; after a restart the task needs its link again.
            notice = "App 重新打开后需要再次提供原链接：把这个任务的链接粘贴到上方，点「加入队列」即可重新下载。"
        } catch { lastError = error }
    }

    func delete(_ id: DownloadID) async {
        guard let manager else { return }
        lastError = nil; notice = nil
        do {
            let result = try await manager.deleteFiles(for: id)
            if !result.fullyDeleted { notice = "有 \(result.failed.count) 个文件没能删除，任务已保留在列表里。" }
        } catch { lastError = error }
    }

    /// Clears failed, cancelled, interrupted and duplicate records. Tasks that own downloaded files are either
    /// deleted together with their files, or kept in the list so the files stay exportable and deletable.
    func clearHistory(deletingFiles: Bool) async {
        guard let manager else { return }
        lastError = nil; notice = nil
        var undeleted = 0
        if deletingFiles {
            for task in snapshot?.tasks ?? [] {
                switch task.state {
                case .completed, .deletionIncomplete:
                    do { undeleted += try await manager.deleteFiles(for: task.id).failed.count }
                    catch { lastError = error; undeleted += 1 }
                default: continue
                }
            }
        }
        do { try await manager.clearHistory(keepingFiles: true) } catch { lastError = error; return }
        if undeleted > 0 { notice = "有文件没能删除，对应任务已保留在列表里。" }
    }

    func fileURL(_ file: DownloadedFile) async -> URL? {
        guard let manager else { return nil }
        do { return try await manager.fileURL(for: file) } catch { lastError = error; return nil }
    }
}

extension MediaError {
    /// Short Chinese explanation; never includes server text, addresses or keys.
    var userMessage: String {
        switch self {
        case .invalidInput: "输入无效。"
        case .invalidURL: "链接无效，请粘贴完整的 https 链接。"
        case .unsupportedSource: "暂不支持这个链接。"
        case .invalidSelection: "所选内容已失效，请重新解析。"
        case .invalidState: "当前状态无法执行这个操作。"
        case .notFound: "内容不存在或已删除。"
        case .outputMissing: "文件已不存在。"
        case .requiresLogin: "需要登录才能查看，App 不会绕过登录。"
        case .notConfigured: "还没有配置所需的 Key。"
        case .accessRestricted(let reason):
            switch reason {
            case .membership: "需要会员，App 不会绕过。"
            case .payment: "需要付费，App 不会绕过。"
            case .region: "所在地区无法观看。"
            case .drm: "内容受版权保护（DRM）。"
            case .permission: "没有访问权限（私密、受限或 Key 被拒绝）。"
            }
        case .rateLimited: "请求太频繁，请稍后再试。"
        case .network: "网络错误，请稍后重试。"
        case .timeout: "请求超时。"
        case .storageFull: "存储空间不足。"
        case .storageUnavailable: "无法读写本地存储。"
        case .parsingChanged: "站点返回的格式变了，解析失败。"
        case .unsupportedFormat: "这种格式暂不支持。"
        case .unsupportedPlatform: "这一项在当前版本还不能处理。"
        case .resourceLimitExceeded: "超出大小或数量限制。"
        case .integrityMismatch: "文件校验失败。"
        case .cleanupFailed: "临时文件清理失败。"
        case .cancelled: "已取消。"
        }
    }
}

/// SauceNAO key in its own Keychain item, separate from AI provider keys.
struct SauceNAOKeychain: SearchCredentialSource {
    private static let service = "AIUtility.SauceNAO"
    private static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "api-key"]
    }
    func sauceNAOKey() async throws -> String? { Self.load() }
    static func load() -> String? {
        var request = query()
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static var isConfigured: Bool { load() != nil }
    @discardableResult static func save(_ key: String) -> Bool {
        SecItemDelete(query() as CFDictionary)
        var item = query()
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
    static func remove() { SecItemDelete(query() as CFDictionary) }
}

/// System share sheet for exported files (save to Files/Photos, AirDrop, ...).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// File URLs usable with `.sheet(item:)`; a multi-file download is shared in one sheet.
struct SharedFile: Identifiable {
    let urls: [URL]
    init(url: URL) { urls = [url] }
    init(urls: [URL]) { self.urls = urls }
    var id: String { urls.map(\.path).joined(separator: "|") }
}

/// Writes tool output to a fresh temporary file so it can be shared.
func temporaryExport(_ data: Data, ext: String) -> URL? {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AIUtilityExports", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("AIUtility-\(UUID().uuidString.prefix(8)).\(ext)")
    do { try data.write(to: url, options: .atomic); return url } catch { return nil }
}
