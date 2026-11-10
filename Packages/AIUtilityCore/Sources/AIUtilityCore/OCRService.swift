import Foundation

public struct OCRBox: Sendable, Equatable {
    /// Vision normalized coordinates; origin at bottom left.
    public let x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}
public struct OCRLine: Sendable, Equatable {
    public let text: String
    public let confidence: Float
    public let box: OCRBox
    public init(text: String, confidence: Float, box: OCRBox) { self.text = text; self.confidence = confidence; self.box = box }
}
public struct OCRResult: Sendable {
    public let lines: [OCRLine]
    public var text: String { lines.map(\.text).joined(separator: "\n") }
    public init(lines: [OCRLine]) { self.lines = lines }
}
public protocol OCRService: Sendable {
    /// EXIF orientation comes from the encoded image. No network or file persistence.
    func recognize(imageData: Data, languages: [String]) async throws -> OCRResult
}

/// Normalized rectangle in the oriented image, origin at bottom left (Vision coordinates).
public struct OCRRegion: Sendable, Equatable {
    public let x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) throws {
        guard [x, y, width, height].allSatisfy(\.isFinite), x >= 0, y >= 0, width > 0, height > 0,
              x + width <= 1, y + height <= 1 else { throw AIUtilityError.invalidRequest }
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}
public protocol RegionOCRService: OCRService {
    func recognize(imageData: Data, languages: [String], region: OCRRegion?) async throws -> OCRResult
}
