import Foundation

public enum SpeedStatistics {
    /// Median of the values (nil when empty).
    public static func median(_ values: [Double]) -> Double? { percentile(values, 0.5) }

    /// Linear-interpolated percentile, p in 0...1 (nil when empty).
    public static func percentile(_ values: [Double], _ p: Double) -> Double? {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        let position = min(1, max(0, p)) * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down)), upper = Int(position.rounded(.up))
        let weight = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * weight
    }

    /// Mean absolute difference between consecutive latency samples (as reported by common speed tests).
    public static func jitter(_ values: [Double]) -> Double? {
        let finite = values.filter(\.isFinite)
        guard finite.count >= 2 else { return nil }
        let diffs = zip(finite.dropFirst(), finite).map { abs($0 - $1) }
        return diffs.reduce(0, +) / Double(diffs.count)
    }

    /// Megabits per second for `bytes` moved in `seconds` (nil for a zero or invalid duration).
    public static func megabitsPerSecond(bytes: Int64, seconds: TimeInterval) -> Double? {
        guard seconds.isFinite, seconds > 0, bytes >= 0 else { return nil }
        return Double(bytes) * 8 / seconds / 1_000_000
    }
}
