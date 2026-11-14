import Foundation
import Testing
import AIUtilityMedia
@testable import AIUtilityMediaApple

/// Platform-independent P2 logic: runs on Linux and Apple platforms.
struct GIFTimelineTests {
    @Test func wholeFrameIntervalsKeepEveryFrameAndTotal() {
        let plan = GIFTimeline.plan(duration: 1.0, fps: 10)
        #expect(plan.count == 10)
        #expect(plan.allSatisfy { $0.delayCentiseconds == 10 })
        #expect(plan.map(\.offset) == (0..<10).map { Double($0) / 10 })
    }

    @Test func fractionalIntervalsFollowTrueTimelineAndKeepTotal() {
        let plan = GIFTimeline.plan(duration: 1.0, fps: 30)
        #expect(plan.count == 30)
        #expect(plan.reduce(0) { $0 + $1.delayCentiseconds } == 100)
        #expect(plan.allSatisfy { (3...4).contains($0.delayCentiseconds) })
        for (index, frame) in plan.enumerated() { #expect(abs(frame.offset - Double(index) / 30) < 1e-12) }
    }

    @Test func tooShortTrailingFrameMergesIntoPrevious() {
        // 1.004 s at 10 fps: an 11th frame at 1.0 s would last 0 cs.
        let plan = GIFTimeline.plan(duration: 1.004, fps: 10)
        #expect(plan.count == 10)
        #expect(plan.reduce(0) { $0 + $1.delayCentiseconds } == 100)
        #expect(plan.allSatisfy { $0.delayCentiseconds >= 2 })
    }

    @Test func clipShorterThanTwoCentisecondsHasNoPlan() {
        #expect(GIFTimeline.plan(duration: 0.01, fps: 10).isEmpty)
        #expect(throws: MediaError.unsupportedFormat) { try ProcessingValidation.check(GIFOptions(duration: 0.01)) }
    }

    @Test func gifOptionsAreValidatedBeforeAnyWork() {
        #expect(throws: MediaError.invalidInput) { try ProcessingValidation.check(GIFOptions(duration: 1, fps: 0)) }
        #expect(throws: MediaError.invalidInput) { try ProcessingValidation.check(GIFOptions(duration: 1, fps: 60)) }
        #expect(throws: MediaError.invalidInput) { try ProcessingValidation.check(GIFOptions(start: -1, duration: 1)) }
        #expect(throws: MediaError.invalidInput) { try ProcessingValidation.check(GIFOptions(duration: .nan)) }
        #expect(throws: MediaError.invalidInput) { try ProcessingValidation.check(GIFOptions(duration: 1, maxWidth: 0)) }
        #expect(throws: MediaError.resourceLimitExceeded) { try ProcessingValidation.check(GIFOptions(duration: 61)) }
        var limits = MediaProcessingLimits(); limits.maxGIFFrames = 9
        #expect(throws: MediaError.resourceLimitExceeded) {
            try ProcessingValidation.check(GIFOptions(duration: 1, fps: 10, limits: limits))
        }
        #expect(throws: Never.self) { try ProcessingValidation.check(GIFOptions(duration: 1, fps: 10)) }
    }
}

struct StitchGeometryTests {
    let sizes: [(width: Int, height: Int)] = [(10, 4), (6, 6), (8, 2)]

    @Test func verticalStacksInOrderAndCentres() throws {
        let layout = try StitchGeometry.layout(sizes: sizes, layout: .vertical, spacing: 2)
        #expect(layout.width == 10 && layout.height == 4 + 2 + 6 + 2 + 2)
        #expect(layout.frames == [PixelRect(x: 0, y: 0, width: 10, height: 4),
                                  PixelRect(x: 2, y: 6, width: 6, height: 6),
                                  PixelRect(x: 1, y: 14, width: 8, height: 2)])
    }

    @Test func horizontalRunsLeftToRightAndCentres() throws {
        let layout = try StitchGeometry.layout(sizes: sizes, layout: .horizontal, spacing: 1)
        #expect(layout.width == 10 + 1 + 6 + 1 + 8 && layout.height == 6)
        #expect(layout.frames == [PixelRect(x: 0, y: 1, width: 10, height: 4),
                                  PixelRect(x: 11, y: 0, width: 6, height: 6),
                                  PixelRect(x: 18, y: 2, width: 8, height: 2)])
    }

    @Test func gridFillsRowsWithLargestCells() throws {
        let layout = try StitchGeometry.layout(sizes: sizes, layout: .grid(columns: 2), spacing: 3)
        #expect(layout.width == 10 + 3 + 10 && layout.height == 6 + 3 + 6)
        #expect(layout.frames == [PixelRect(x: 0, y: 1, width: 10, height: 4),
                                  PixelRect(x: 13 + 2, y: 0, width: 6, height: 6),
                                  PixelRect(x: 1, y: 9 + 2, width: 8, height: 2)])
        // More columns than images: only the used columns count.
        let wide = try StitchGeometry.layout(sizes: sizes, layout: .grid(columns: 5), spacing: 0)
        #expect(wide.width == 30 && wide.height == 6)
    }

    @Test func invalidStitchRequestsFail() {
        #expect(throws: MediaError.invalidInput) { try StitchGeometry.layout(sizes: sizes, layout: .grid(columns: 0), spacing: 0) }
        #expect(throws: MediaError.invalidInput) { try StitchGeometry.layout(sizes: sizes, layout: .vertical, spacing: -1) }
        #expect(throws: MediaError.invalidInput) { try StitchGeometry.layout(sizes: [], layout: .vertical, spacing: 0) }
        #expect(throws: MediaError.invalidInput) { try ProcessingValidation.check(StitchOptions(), imageCount: 0) }
        var limits = MediaProcessingLimits(); limits.maxImageCount = 2
        #expect(throws: MediaError.resourceLimitExceeded) {
            try ProcessingValidation.check(StitchOptions(limits: limits), imageCount: 3)
        }
        #expect(throws: MediaError.invalidInput) {
            try ProcessingValidation.check(StitchOptions(background: RGBAColor(red: 2, green: 0, blue: 0)), imageCount: 1)
        }
    }

    @Test func noiseNeedsExplicitPermission() {
        #expect(throws: MediaError.invalidInput) {
            try ProcessingValidation.check(FingerprintOptions(method: .subtlePixelNoise), inputBytes: 10)
        }
        #expect(throws: Never.self) {
            try ProcessingValidation.check(FingerprintOptions(method: .subtlePixelNoise, allowPixelChanges: true), inputBytes: 10)
        }
        #expect(throws: MediaError.invalidInput) { try ProcessingValidation.check(FingerprintOptions(method: .reencode), inputBytes: 0) }
    }

    @Test func noiseGeneratorIsDeterministic() {
        var a = SplitMix64(seed: 42), b = SplitMix64(seed: 42), c = SplitMix64(seed: 43)
        let first = (0..<4).map { _ in a.next() }
        #expect(first == (0..<4).map { _ in b.next() })
        #expect(first != (0..<4).map { _ in c.next() })
    }
}

#if !canImport(ImageIO)
struct UnsupportedPlatformTests {
    @Test func toolsFailHonestlyWithoutImageIO() async {
        do { _ = try await stitchImages([Data([1])]); Issue.record("expected failure") }
        catch { #expect(error == .unsupportedPlatform) }
        do { _ = try await rewriteFingerprint(Data([1]), options: .init(method: .reencode)); Issue.record("expected failure") }
        catch { #expect(error == .unsupportedPlatform) }
        do {
            _ = try await makeGIF(fromVideo: URL(fileURLWithPath: "/nonexistent.mov"),
                                  outputDirectory: URL(fileURLWithPath: "/nonexistent"), options: GIFOptions(duration: 1))
            Issue.record("expected failure")
        } catch { #expect(error == .unsupportedPlatform) }
    }
}
#endif
