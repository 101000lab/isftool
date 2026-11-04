import Foundation

/// Summary of GPU times in milliseconds.
public struct Stats: Codable, Equatable, Sendable {
    public var median: Double
    public var p95: Double
    public var min: Double
    public var mean: Double
    /// Population standard deviation: the frames measured are the whole run, not a sample of a larger one.
    public var stddev: Double

    public init(median: Double, p95: Double, min: Double, mean: Double, stddev: Double) {
        self.median = median
        self.p95 = p95
        self.min = min
        self.mean = mean
        self.stddev = stddev
    }

    public init?(_ samples: [Double]) {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let n = sorted.count
        median = Self.median(sorted)
        // Nearest rank, so p95 is always one of the measured frames.
        p95 = sorted[Swift.max(0, Int((0.95 * Double(n)).rounded(.up)) - 1)]
        min = sorted[0]
        mean = sorted.reduce(0, +) / Double(n)
        let m = mean
        stddev = (sorted.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(n)).squareRoot()
    }

    /// Mean of the two middle values when the count is even.
    public static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let n = sorted.count
        guard n > 0 else { return .nan }
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }
}
