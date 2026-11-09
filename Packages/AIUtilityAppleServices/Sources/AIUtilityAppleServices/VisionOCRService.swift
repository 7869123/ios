import AIUtilityCore
import Foundation
#if canImport(Vision)
@preconcurrency import Vision
import ImageIO

/// Locks only the cancellation handoff. Vision work runs on a detached worker, never the UI actor.
private final class VisionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var request: VNRequest?
    private var cancelled = false
    func install(_ request: VNRequest) {
        lock.lock(); defer { lock.unlock() }
        if cancelled { request.cancel() } else { self.request = request }
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true; request?.cancel()
    }
}

public struct VisionOCRService: RegionOCRService {
    public init() {}
    public func recognize(imageData: Data, languages: [String] = ["en-US", "ja-JP", "zh-Hans"]) async throws -> OCRResult {
        try await recognize(imageData: imageData, languages: languages, region: nil)
    }
    public func recognize(imageData: Data, languages: [String], region: OCRRegion?) async throws -> OCRResult {
        guard !imageData.isEmpty, imageData.count <= 32_000_000 else { throw AIUtilityError.invalidRequest }
        guard !languages.isEmpty, languages.count <= 3 else { throw AIUtilityError.invalidRequest }
        let cancellation = VisionCancellation()
        let worker = Task.detached(priority: .userInitiated) { () throws -> OCRResult in
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 16_384, height <= 16_384,
                  width * height <= 40_000_000 else { throw AIUtilityError.invalidRequest }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let supported = try request.supportedRecognitionLanguages()
            guard languages.allSatisfy({ supported.contains($0) }) else { throw AIUtilityError.unsupportedPlatform }
            request.recognitionLanguages = languages
            request.automaticallyDetectsLanguage = languages.count > 1
            if let region { request.regionOfInterest = CGRect(x: region.x, y: region.y, width: region.width, height: region.height) }
            cancellation.install(request)
            let handler = VNImageRequestHandler(data: imageData, options: [:])
            do { try handler.perform([request]) }
            catch {
                if Task.isCancelled { throw AIUtilityError.cancelled }
                throw AIUtilityError.invalidRequest
            }
            try Task.checkCancellation()
            let lines = (request.results ?? []).compactMap { observation -> OCRLine? in
                guard let text = observation.topCandidates(1).first else { return nil }
                let box = observation.boundingBox
                return OCRLine(text: text.string, confidence: text.confidence,
                    box: OCRBox(x: box.minX, y: box.minY, width: box.width, height: box.height))
            }
            return OCRResult(lines: lines)
        }
        return try await withTaskCancellationHandler {
            do {
                let result = try await worker.value
                guard !Task.isCancelled else { throw AIUtilityError.cancelled }
                return result
            } catch { throw AIUtilityError.sanitized(error) }
        } onCancel: {
            worker.cancel(); cancellation.cancel()
        }
    }
}
#endif
