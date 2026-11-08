import Foundation
import Testing
@testable import AIUtilityMedia

struct StorageTests {
    @Test func enqueueWriteFailurePreservesOldManifestAndDoesNotStart() async throws {
        let h = try Harness(); defer { try? h.cleanup() }
        let manager = try h.manager(), old = try h.store.load()
        h.store.failWrites(true)
        await expectError(.storageUnavailable) { _ = try await manager.enqueue(link: mediaURL) }
        #expect(try h.store.load().revision == old.revision)
        #expect(await queueSnapshot(manager).tasks.isEmpty)
        #expect(await h.transport.counts().heads == 0)
        h.store.failWrites(false); try await manager.shutdown()
    }
    @Test func initializationFailureCanSafelyRetrySameNamespace() throws {
        let h = try Harness(); defer { try? h.cleanup() }
        let old = try h.store.load()
        h.store.failWrites(true)
        #expect(throws: MediaError.storageUnavailable) { _ = try h.manager() }
        #expect(try h.store.load().revision == old.revision)
        h.store.failWrites(false)
        _ = try h.manager()
    }
    @Test func clearHistoryFailureRollsBackAndSuccessKeepsFilesDeletable() async throws {
        let h = try Harness(); defer { try? h.cleanup() }
        let manager = try h.manager(), receipt = try await manager.enqueue(link: mediaURL)
        let state = try await waitFor(manager, id: receipt.id), files = state.files
        let file = try #require(files.first)
        h.store.failWrites(true)
        await expectError(.storageUnavailable) { try await manager.clearHistory() }
        #expect(try await manager.history().count == 1)
        h.store.failWrites(false)
        try await manager.clearHistory()
        #expect(try await manager.history().isEmpty)
        #expect(FileManager.default.fileExists(atPath: try await manager.fileURL(for: file).path))
        let deleted = try await manager.deleteFiles(for: receipt.id)
        #expect(deleted.fullyDeleted && deleted.deleted == files)
        #expect(try await manager.history().isEmpty)
        try await manager.shutdown()
    }
    @Test func deletionRemovesDedupAndMissingFileIsReportedHonestly() async throws {
        let h = try Harness(); defer { try? h.cleanup() }
        let manager = try h.manager(), first = try await manager.enqueue(link: mediaURL)
        let files = try await waitFor(manager, id: first.id).files
        let file = try #require(files.first)
        try FileManager.default.removeItem(at: await manager.fileURL(for: file))
        let duplicate = try await manager.enqueue(link: mediaURL)
        #expect(duplicate.disposition == .retryRequired)
        let result = try await manager.deleteFiles(for: first.id)
        #expect(result.alreadyMissing == files && result.deleted.isEmpty && result.fullyDeleted)
        let fresh = try await manager.enqueue(link: mediaURL)
        #expect(fresh.disposition == .created && fresh.id != first.id)
        _ = try await waitFor(manager, id: fresh.id)
        try await manager.shutdown()
    }
    @Test func partialDeletionKeepsFailedOutputsAndAllowsFreshDownload() async throws {
        let h = try Harness(resolvers: [FixtureResolver(.x, count: 2)]); defer { try? h.cleanup() }
        let manager = try h.manager(), url = URL(string: "https://x.com/example/status/123")!
        let first = try await manager.enqueue(link: url)
        let files = try await waitFor(manager, id: first.id).files
        #expect(files.count == 2)
        let failedFile = try #require(files.first)
        h.files.failRemove([failedFile.id])
        let result = try await manager.deleteFiles(for: first.id)
        #expect(!result.fullyDeleted && result.deleted.count == 1 && result.failed.count == 1)
        #expect(try await manager.history().first?.state == .deletionIncomplete(remainingFiles: [failedFile]))
        let fresh = try await manager.enqueue(link: url)
        #expect(fresh.disposition == .created && fresh.id != first.id)
        _ = try await waitFor(manager, id: fresh.id)
        h.files.failRemove([])
        #expect(try await manager.deleteFiles(for: first.id).fullyDeleted)
        try await manager.shutdown()
    }
    @Test func activeAndQueuedTasksCannotBeDeleted() async throws {
        let gate = TransferGate(), h = try Harness(steps: [.gate(gate)])
        defer { try? h.cleanup() }
        let manager = try h.manager(), first = try await manager.enqueue(link: mediaURL)
        await gate.waitUntilEntered()
        let second = try await manager.enqueue(link: URL(string: "https://media.example.org/second.png")!)
        await expectError(.invalidState) { _ = try await manager.deleteFiles(for: first.id) }
        await expectError(.invalidState) { _ = try await manager.deleteFiles(for: second.id) }
        _ = await manager.cancel(second.id); _ = await manager.cancel(first.id); await gate.release()
        _ = try await waitFor(manager, id: first.id); try await manager.shutdown()
    }
    @Test func persistedManifestHasNoOriginalLinkTitleOrCredentials() async throws {
        let h = try Harness(); defer { try? h.cleanup() }
        let manager = try h.manager()
        let url = URL(string: "https://media.example.org/file.png?signature=fixture-secret#private-fragment")!
        let job = try await manager.enqueue(link: url)
        _ = try await waitFor(manager, id: job.id)
        let data = try JSONEncoder().encode(h.store.load()), text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("fixture-secret") && !text.contains("https:") && !text.contains("private-fragment"))
        #expect(!text.contains("Authorization") && !text.contains("Cookie"))
        try await manager.shutdown()
    }
    @Test func realDiskManifestPersistsAndFailedDecodeDoesNotOverwrite() throws {
        let h = try Harness(); defer { try? h.cleanup() }
        let root = h.root.appendingPathComponent("real-store"), repository = try DiskManifestStore(root: root)
        var expected = MediaManifest(); expected.revision = 7; try repository.save(expected)
        #expect(try DiskManifestStore(root: root).load().revision == 7)
        let file = root.appendingPathComponent("manifest.json"), corrupt = Data("invalid fixture".utf8)
        try corrupt.write(to: file)
        #expect(throws: (any Error).self) { _ = try repository.load() }
        #expect(try Data(contentsOf: file) == corrupt)
    }
    @Test func restartMarksRunningInterruptedAndPreservesPendingOrdinal() throws {
        let h = try Harness(); defer { try? h.cleanup() }
        let id = DownloadID(), pendingID = DownloadID(), attempt = UUID(), date = Date()
        var value = MediaManifest(); value.nextOrdinal = 2
        value.tasks = [
            StoredTask(id: id, ordinal: 1, alias: "digest-one", selection: .automatic, options: .init(), identity: nil,
                       source: .direct, effectiveOptions: nil, state: .resolving, attemptID: attempt, createdAt: date, updatedAt: date, journal: nil),
            StoredTask(id: pendingID, ordinal: 2, alias: "digest-two", selection: .automatic, options: .init(), identity: nil,
                       source: .direct, effectiveOptions: nil, state: .queued(position: 1), attemptID: UUID(), createdAt: date, updatedAt: date, journal: nil)
        ]
        try h.store.save(value); _ = try h.manager()
        let restored = try h.store.load()
        #expect(restored.tasks[0].state == .interrupted)
        #expect(restored.tasks[1].state == .queued(position: 1) && restored.tasks[1].ordinal == 2)
    }
    @Test func commitJournalRecoversPublishedButUncommittedOutput() throws {
        let h = try Harness(); defer { try? h.cleanup() }
        let id = DownloadID(), attempt = UUID(), fileID = UUID(), date = Date()
        let name = fileID.uuidString + ".png", stage = try h.files.staging(id, attempt: attempt)
        try png.write(to: stage.appendingPathComponent(name))
        let file = DownloadedFile(id: fileID, fileName: name,
            relativePath: "outputs/\(id.rawValue.uuidString)/\(attempt.uuidString)/\(name)", bytes: Int64(png.count), kind: .image)
        try h.files.publish(stage, files: [file])
        var value = MediaManifest()
        value.tasks = [StoredTask(id: id, ordinal: 1, alias: "digest", selection: .automatic, options: .init(), identity: nil,
            source: .direct, effectiveOptions: nil, state: .committing, attemptID: attempt, createdAt: date, updatedAt: date, journal: [file])]
        try h.store.save(value); _ = try h.manager()
        #expect(try h.store.load().tasks.first?.state == .interrupted)
        #expect(throws: MediaError.outputMissing) { _ = try h.files.locate(file) }
    }
    @Test func deletionJournalRecoveryNeverResurrectsHistory() throws {
        let h = try Harness(); defer { try? h.cleanup() }
        let id = DownloadID(), attempt = UUID(), fileID = UUID()
        let file = DownloadedFile(id: fileID, fileName: fileID.uuidString + ".png",
            relativePath: "outputs/\(id.rawValue.uuidString)/\(attempt.uuidString)/\(fileID.uuidString).png", bytes: 10, kind: .image)
        var value = MediaManifest(); value.ownership[id.rawValue.uuidString] = Ownership(files: [file], deleting: true)
        try h.store.save(value); _ = try h.manager()
        #expect(try h.store.load().ownership.isEmpty)
        #expect(try h.store.load().tasks.isEmpty)
    }
    @Test func forgedOutputPathAndChangedFileAreNotAccepted() throws {
        let h = try Harness(); defer { try? h.cleanup() }
        let file = DownloadedFile(id: UUID(), fileName: "outside.png", relativePath: "../../outside.png", bytes: 10, kind: .image)
        #expect(throws: MediaError.storageUnavailable) { _ = try h.files.remove(file) }
    }
    @Test func contentMismatchIsNeverMarkedCompleteOrRetried() async throws {
        let h = try Harness(); defer { try? h.cleanup() }
        await h.transport.setPayload(Data("<html>fixture</html>".utf8))
        let manager = try h.manager(), job = try await manager.enqueue(link: mediaURL)
        #expect(try await waitFor(manager, id: job.id) == .failed(.integrityMismatch))
        #expect(await h.transport.counts().downloads == 1)
        #expect(try h.store.load().ownership.isEmpty)
        try await manager.shutdown()
    }
    @Test func transferPlansAndComponentsRedactReflection() throws {
        let component = try MediaComponent(id: "fixture", url: URL(string: "https://media.example.org/file.png?signature=fixture-secret")!)
        let variant = try MediaVariant(id: "original", kind: .image, qualityLabel: "Fixture", fileExtension: "png")
        let plan = try MediaTransferPlan(itemID: MediaItemID(source: .direct, value: "fixture"), variant: variant, components: [component])
        #expect(!String(reflecting: plan).contains("fixture-secret"))
        #expect(!String(describing: component).contains("signature"))
        #expect(Mirror(reflecting: component).children.count == 1)
    }
}
