import Foundation
import Testing
@testable import AIUtilityCore

private actor CountingOCR: RegionOCRService {
    private(set) var calls = 0
    private(set) var region: OCRRegion?
    func recognize(imageData: Data, languages: [String]) async throws -> OCRResult {
        try await recognize(imageData: imageData, languages: languages, region: nil)
    }
    func recognize(imageData: Data, languages: [String], region: OCRRegion?) async throws -> OCRResult {
        calls += 1; self.region = region
        return OCRResult(lines: [OCRLine(text: "recognized", confidence: 1, box: OCRBox(x: 0, y: 0, width: 1, height: 1))])
    }
}

@Test func screenshotWorkflowRecognizesOnceEditsAndSendsOnlyText() async throws {
    let ocr = CountingOCR()
    let transport = ScriptedTransport([.echoInput])
    let (engine, _) = try configuredEngine(transport: transport)
    let workflow = ScreenshotTranslationWorkflow(ocr: ocr, translation: engine)
    let region = try OCRRegion(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
    let original = try await workflow.recognize(imageData: Data("synthetic-local-image".utf8), source: .english, region: region)
    #expect(await transport.requests.isEmpty)
    let edited = try await workflow.edit("edited words", draft: original.id)
    let output = try await workflow.translate(draft: edited.id, provider: .openAI,
        languages: TranslationLanguages(source: .english, target: .japanese))
    #expect(output == "edited words")
    #expect(await ocr.calls == 1)
    #expect(await ocr.region == region)
    let request = try #require(await transport.requests.first)
    let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
    #expect(!body.contains("synthetic-local-image"))
    await #expect(throws: AIUtilityError.invalidRequest) { try await workflow.translate(draft: original.id, provider: .openAI) }
}

@Test func screenshotCancellationWaitsForNetworkAndPreservesEditableDraft() async throws {
    let ocr = CountingOCR()
    let transport = ScriptedTransport([.waitForCancellation, .echoInput])
    let (engine, _) = try configuredEngine(transport: transport)
    let workflow = ScreenshotTranslationWorkflow(ocr: ocr, translation: engine)
    let draft = try await workflow.recognize(imageData: Data([1]), source: .english)
    let pending = Task { try await workflow.translate(draft: draft.id, provider: .openAI) }
    await transport.waitForFirstCall()
    await #expect(throws: AIUtilityError.configurationBusy) { try await workflow.translate(draft: draft.id, provider: .openAI) }
    await workflow.cancel()
    await #expect(throws: AIUtilityError.cancelled) { try await pending.value }
    let preserved = await workflow.draft()
    #expect(preserved?.id == draft.id)
    let text = try await workflow.translate(draft: draft.id, provider: .openAI)
    #expect(text == "recognized")
    #expect(await ocr.calls == 1)
}

@Test func normalizedOCRRegionRejectsInvalidBounds() throws {
    for values in [[-0.1, 0, 1, 1], [0, 0, 0, 1], [0.5, 0.5, 0.6, 0.5], [Double.nan, 0, 1, 1]] {
        #expect(throws: AIUtilityError.invalidRequest) { try OCRRegion(x: values[0], y: values[1], width: values[2], height: values[3]) }
    }
    #expect(try OCRRegion(x: 0, y: 0, width: 1, height: 1).width == 1)
}

private actor SwitchingAdapter: AIProviderAdapter {
    nonisolated let provider = ProviderID.openAI
    private var entered = false
    private var entrance: CheckedContinuation<Void, Never>?
    func listModels(key: APIKey, timeout: TimeInterval, beforeRequest: @escaping @Sendable () async throws -> Void) async throws -> [AIModel] { [] }
    func generate(_ request: GenerationRequest, key: APIKey, timeout: TimeInterval) async throws -> GenerationResult {
        if request.instructions.contains("connectivity test") { return GenerationResult(text: "OK") }
        entered = true; entrance?.resume(); entrance = nil
        try await Task.sleep(for: .seconds(60))
        return GenerationResult(text: "stale")
    }
    func wait() async { if !entered { await withCheckedContinuation { entrance = $0 } } }
}

@Test func modelSwitchActivelyCancelsOldTranslationWithoutWaitingForTimeout() async throws {
    let adapter = SwitchingAdapter()
    let gateway = ProviderGateway(adapters: [adapter])
    let store = TestCredentialStore()
    try store.replace(provider: .openAI, configuration: ProviderConfiguration(key: APIKey("test-key"), models: [.videoSubtitle: "old"]))
    let coordinator = ConfigurationCoordinator(store: store, gateway: gateway)
    let engine = TranslationEngine(configurations: coordinator, gateway: gateway)
    let request = Task { try await engine.translate("Hello", provider: .openAI, feature: .videoSubtitle) }
    await adapter.wait()
    try await coordinator.switchModel(provider: .openAI, feature: .videoSubtitle, model: "new")
    await #expect(throws: AIUtilityError.cancelled) { try await request.value }
    #expect(try await coordinator.models(provider: .openAI)[.videoSubtitle] == "new")
    let measurements = await engine.diagnostics.snapshot()
    #expect(measurements.last?.outcome == .failure(.cancelled))
}

@Test func boundedDiagnosticsAndOldPreferenceMigration() async throws {
    let diagnostics = TranslationDiagnostics(capacity: 3)
    for index in 0..<20 { await diagnostics.record(stage: .translationAPI, milliseconds: Double(index), outcome: .success) }
    await diagnostics.record(stage: .speechRecognition, milliseconds: .nan, outcome: .success)
    let values = await diagnostics.snapshot()
    #expect(values.count == 3)
    #expect(values.first?.milliseconds == 17)
    let store = TestLocalStore()
    try store.write(Data(#"{"version":1,"features":{"videoSubtitle":{"prompt":"keep prompt","languages":{"source":"ja","target":"en"}}}}"#.utf8), to: .translationPreferences)
    let preferences = TranslationPreferences(store: store)
    #expect(try await preferences.prompt(for: .videoSubtitle) == "keep prompt")
    #expect(try await preferences.reasoning(provider: .openAI, model: "new") == .auto)
    try await preferences.saveReasoning(.low, provider: .openAI, model: "gpt-5.4", totalOutputTokens: 4096)
    let next = TranslationPreferences(store: store)
    #expect(try await next.languages(for: .videoSubtitle) == TranslationLanguages(source: .japanese, target: .english))
    #expect(try await next.prompt(for: .videoSubtitle) == "keep prompt")
}

private actor FIFORecorder {
    private(set) var calls: [String] = []
    func translate(_ text: String) -> String { calls.append(text); return "translated " + text }
}

@Test func subtitleResultsRemainOrderedAndDuplicateFinalDoesNotCostTwice() async throws {
    let recorder = FIFORecorder()
    let pipeline = SubtitleTranslationSession { text, _, _ in await recorder.translate(text) }
    let stream = try await pipeline.events()
    let session = try await pipeline.start(provider: .openAI, languages: TranslationLanguages())
    let utterance = UUID()
    try await pipeline.ingest(SpeechTranscript(utteranceID: utterance, sequence: 1, text: "first", isFinal: true, timestamp: 1), session: session)
    try await pipeline.ingest(SpeechTranscript(utteranceID: utterance, sequence: 2, text: "first", isFinal: true, timestamp: 2), session: session)
    try await pipeline.ingest(SpeechTranscript(utteranceID: UUID(), sequence: 1, text: "second", isFinal: true, timestamp: 3), session: session)
    var ordinals: [UInt64] = []
    var iterator = stream.makeAsyncIterator()
    while let event = await iterator.next() {
        if case .translated(_, let ordinal, _, _, _) = event { ordinals.append(ordinal) }
        if ordinals.count == 2 { break }
    }
    #expect(ordinals == [1, 2])
    #expect(await recorder.calls == ["first", "second"])
    #expect(await pipeline.metrics().duplicateEvents == 1)
    await pipeline.pause()
}

@Test func subtitleCommittedPrefixCannotBeRevisedAndStaleEpochIsIgnored() throws {
    var segmenter = SubtitleSegmenter(policy: SubtitlePolicy())
    let id = UUID()
    _ = try segmenter.ingest(SpeechTranscript(utteranceID: id, sequence: 1, text: "Hello world.", isFinal: false, timestamp: 1))
    #expect(segmenter.flush(at: 3) == ["Hello world."])
    #expect(try segmenter.ingest(SpeechTranscript(utteranceID: id, sequence: 2, text: "Changed world.", isFinal: true, timestamp: 4)).isEmpty)
    #expect(try segmenter.ingest(SpeechTranscript(utteranceID: UUID(), sequence: 1, text: "old callback", isFinal: true, timestamp: 0)).isEmpty)
}
