import Foundation
import Testing
@testable import AIUtilityMedia

struct RecoveryTests {
    @Test func failedCompletionCommitCleansPublishedFilesAndDoesNotClaimSuccess() async throws {
        let h = try Harness(); defer { try? h.cleanup() }
        let manager = try h.manager()
        h.store.failNextCompletion()
        let task = try await manager.enqueue(link: mediaURL)
        #expect(try await waitFor(manager, id: task.id) == .failed(.storageUnavailable))
        #expect(try h.store.load().ownership.isEmpty)
        #expect(try h.store.load().tasks.first?.journal == nil)
        let outputs = h.files.base.root.appendingPathComponent("outputs")
        let paths = FileManager.default.enumerator(at: outputs, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        #expect(!paths.contains(where: { $0.pathExtension == "png" }))
        try await manager.shutdown()
    }
    @Test func unavailableFilesAndValidPathsAreDifferentErrors() async throws {
        let h = try Harness(); defer { try? h.cleanup() }
        let manager = try h.manager(), first = try await manager.enqueue(link: mediaURL)
        let files = try await waitFor(manager, id: first.id).files, file = try #require(files.first)
        let path = try await manager.fileURL(for: file)
        let replacement = path.deletingLastPathComponent().appendingPathComponent("replacement.png")
        try png.write(to: replacement) // Allocate while the original exists so the inode cannot be reused.
        try FileManager.default.removeItem(at: path)
        try FileManager.default.moveItem(at: replacement, to: path)
        let old = try #require(file.fileIdentity)
        let current = try #require((try FileManager.default.attributesOfItem(atPath: path.path)[.systemFileNumber] as? NSNumber)?.uint64Value)
        #expect(current != old)
        await expectError(.integrityMismatch) { _ = try await manager.fileURL(for: file) }
        try await manager.shutdown()
    }
    @Test func deletionMetadataFailureRecoversActualDiskWithoutFalseRollback() async throws {
        let h = try Harness(); defer { try? h.cleanup() }
        let manager = try h.manager(), first = try await manager.enqueue(link: mediaURL)
        _ = try await waitFor(manager, id: first.id)
        h.store.failNextWrite(offset: 2)
        await expectError(.storageUnavailable) { _ = try await manager.deleteFiles(for: first.id) }
        #expect(try h.store.load().ownership[first.id.rawValue.uuidString]?.deleting == true)
        try await manager.retryCleanup(first.id)
        #expect(try await manager.history().isEmpty)
        #expect(try h.store.load().ownership.isEmpty)
        try await manager.shutdown()
    }
    @Test func resolvedAliasesAndIrrelevantPixivOptionsDoNotDownloadTwice() async throws {
        let h = try Harness(resolvers: [FixtureResolver(.pixiv)]); defer { try? h.cleanup() }
        let manager = try h.manager(), url = URL(string: "https://www.pixiv.net/artworks/123")!
        let first = try await manager.enqueue(link: url)
        _ = try await waitFor(manager, id: first.id)
        let second = try await manager.enqueue(link: url, options: SiteOptions(pixiv: .init(keepUgoiraArchive: true)))
        #expect(try await waitFor(manager, id: second.id) == .duplicate(existing: first.id))
        #expect(await h.transport.counts().downloads == 1)
        try await manager.shutdown()
    }
    @Test func queuedOptionsAreValueSnapshotsAndAllPartsCannotSilentlyDowngrade() async throws {
        let gate = TransferGate(), h = try Harness(steps: [.gate(gate)], resolvers: [FixtureResolver(.bilibili)])
        defer { try? h.cleanup() }
        let manager = try h.manager(), first = try await manager.enqueue(link: mediaURL)
        await gate.waitUntilEntered()
        var options = SiteOptions()
        let second = try await manager.enqueue(link: URL(string: "https://www.bilibili.com/video/BVfixture")!, options: options)
        options.bilibili.allParts = true
        #expect(try h.store.load().tasks.first(where: { $0.id == second.id })?.options.bilibili.allParts == false)
        let third = try await manager.enqueue(link: URL(string: "https://www.bilibili.com/video/BVfixture")!, options: options)
        #expect(third.id != second.id)
        await gate.release(); _ = try await waitFor(manager, id: first.id)
        _ = try await waitFor(manager, id: second.id)
        #expect(try await waitFor(manager, id: third.id) == .failed(.unsupportedFormat))
        #expect(await h.transport.counts().downloads == 2)
        try await manager.shutdown()
    }
    @Test func restartNeedsOriginalSensitiveLinkAndNeverPersistsIt() async throws {
        let h = try Harness(); defer { try? h.cleanup() }
        let manager = try h.manager(), job = try await manager.enqueue(link: mediaURL)
        _ = try await waitFor(manager, id: job.id); try await manager.shutdown()
        // Simulate an OS termination while the old row was resolving.
        var disk = try h.store.load(); disk.tasks[0].state = .resolving; try h.store.save(disk)
        let restored = try h.manager()
        #expect(try await restored.history().first?.state == .interrupted)
        await expectError(.notConfigured) { try await restored.retry(job.id) }
        let supplied = try await restored.enqueue(link: mediaURL)
        #expect(supplied.id == job.id && supplied.disposition == .retryRequired)
        try await restored.retry(job.id)
        guard case .completed = try await waitFor(restored, id: job.id) else { Issue.record("Restored retry failed"); return }
        try await restored.shutdown()
    }
    @Test func headStatusRefusalAndRetryAfterAreClassified() async throws {
        let h = try Harness(policy: .init(minimumRequestInterval: 0, maxRetries: 0, minimumFreeBytes: 0))
        defer { try? h.cleanup() }
        let manager = try h.manager()
        let cases: [(Int, MediaError)] = [(401, .requiresLogin), (403, .accessRestricted(.permission)),
            (404, .notFound), (429, .rateLimited(retryAfter: 5)), (503, .network), (206, .integrityMismatch)]
        for (status, error) in cases {
            let path = "/status-\(status)"
            await h.transport.setHeader(path: path, status: status, headers: ["retry-after": "5"])
            let receipt = try await manager.enqueue(link: URL(string: "https://media.example.org" + path)!)
            #expect(try await waitFor(manager, id: receipt.id) == .failed(error))
        }
        #expect(await h.transport.counts().downloads == 0)
        try await manager.shutdown()
    }
    @Test func selectedItemIsRevalidatedByResolver() async throws {
        let h = try Harness(); defer { try? h.cleanup() }
        let manager = try h.manager()
        let variant = try MediaVariant(id: "forged", kind: .image, qualityLabel: "Fixture", fileExtension: "png")
        let item = try MediaItem(id: MediaItemID(source: .direct, value: "unknown"), title: "Fixture", variants: [variant])
        let receipt = try await manager.enqueue(item, variant: variant)
        #expect(try await waitFor(manager, id: receipt.id) == .failed(.invalidSelection))
        #expect(await h.transport.counts().downloads == 0)
        try await manager.shutdown()
    }
    @Test func finitePolicyRejectsInvalidConfiguration() throws {
        #expect(throws: MediaError.invalidInput) { try DownloadPolicy(requestTimeout: .infinity).validate() }
        #expect(throws: MediaError.invalidInput) { try DownloadPolicy(maxRetries: 6).validate() }
        #expect(throws: MediaError.invalidInput) { try DownloadPolicy(maxOutputs: 0).validate() }
        #expect(throws: MediaError.invalidInput) { try DownloadPolicy(maxFileBytes: -1).validate() }
    }
}
