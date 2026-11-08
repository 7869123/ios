import Foundation
import Testing
@testable import AIUtilityMedia

struct SandboxPathTests {
    @Test func existingSystemTemporaryDirectoryIsAccepted() throws {
        // On Darwin, Foundation can standardize /private/var back to /var; this is not an app-owned symlink.
        try SandboxFiles.noLinks(FileManager.default.temporaryDirectory)
    }
    @Test func systemAliasExceptionRequiresExactPathAndDestination() {
        #expect(!SandboxFiles.isSystemAlias(path: "/var", destination: "/private/unrelated"))
        #expect(!SandboxFiles.isSystemAlias(path: "/tmp", destination: "/private/tmp/child"))
        #expect(!SandboxFiles.isSystemAlias(path: "/sandbox/var", destination: "private/var"))
        #expect(!SandboxFiles.isSystemAlias(path: "/sandbox/tmp", destination: "/private/tmp"))
        #if canImport(Darwin)
        #expect(SandboxFiles.isSystemAlias(path: "/var", destination: "private/var"))
        #expect(SandboxFiles.isSystemAlias(path: "/tmp", destination: "/private/tmp"))
        #else
        #expect(!SandboxFiles.isSystemAlias(path: "/var", destination: "private/var"))
        #expect(!SandboxFiles.isSystemAlias(path: "/tmp", destination: "/private/tmp"))
        #endif
    }
    @Test func symlinkInsideOwnedDirectoryAndDanglingLinkRemainRejected() throws {
        let h = try Harness(); defer { try? h.cleanup() }
        try SandboxFiles.noLinks(h.files.base.root)
        let link = h.files.base.root.appendingPathComponent("var", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: h.files.base.cache)
        #expect(throws: MediaError.storageUnavailable) { try SandboxFiles.noLinks(link.appendingPathComponent("child")) }
        let dangling = h.files.base.root.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: h.root.appendingPathComponent("missing"))
        #expect(throws: MediaError.storageUnavailable) { try SandboxFiles.noLinks(dangling) }
    }
}
