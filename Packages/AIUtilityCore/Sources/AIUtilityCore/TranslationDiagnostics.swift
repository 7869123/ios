import Foundation

public enum TranslationStage: String, Sendable { case speechRecognition, localOCR, translationAPI, subtitleQueueToOutput }
public enum MeasurementOutcome: Sendable, Equatable { case success, failure(AIUtilityError) }
public struct TranslationMeasurement: Sendable {
    public let stage: TranslationStage
    public let milliseconds: Double
    public let outcome: MeasurementOutcome
}

/// In-memory bounded numbers and safe enums only. Never accepts text, audio, image, keys or URLs.
public actor TranslationDiagnostics {
    private let capacity: Int
    private var samples: [TranslationMeasurement] = []
    public init(capacity: Int = 128) { self.capacity = min(512, max(1, capacity)) }
    public func record(stage: TranslationStage, milliseconds: Double, outcome: MeasurementOutcome) {
        guard milliseconds.isFinite, milliseconds >= 0, milliseconds <= 86_400_000 else { return }
        samples.append(TranslationMeasurement(stage: stage, milliseconds: milliseconds, outcome: outcome))
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }
    public func snapshot() -> [TranslationMeasurement] { samples }
    public func clear() { samples.removeAll(keepingCapacity: false) }
}
