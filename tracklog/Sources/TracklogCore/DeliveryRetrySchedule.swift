import Foundation

/// The delay before a failed delivery's next attempt: 30 s, 1 min, 2 min,
/// 5 min, 15 min, 30 min and then 60 min, each with ±20% jitter. A rate-limit
/// hint replaces the delay only when it is later.
public struct DeliveryRetrySchedule: Sendable {
    public static let standard = DeliveryRetrySchedule()

    public let delays: [TimeInterval]
    public let jitterFraction: Double
    private let random: @Sendable () -> Double

    public init(
        delays: [TimeInterval] = [30, 60, 120, 300, 900, 1800, 3600],
        jitterFraction: Double = 0.2,
        random: @escaping @Sendable () -> Double = { Double.random(in: 0 ..< 1) },
    ) {
        self.delays = delays
        self.jitterFraction = min(max(0, jitterFraction), 1)
        self.random = random
    }

    /// The delay after `attempts` failed attempts. The first failure waits the
    /// schedule's first delay; every failure past the last entry keeps the cap.
    public func delay(afterFailedAttempts attempts: Int) -> TimeInterval {
        guard attempts > 0, !delays.isEmpty else { return 0 }
        let base = delays[min(attempts - 1, delays.count - 1)]
        let unit = min(max(random(), 0), 1)
        let jitter = 1 + (unit * 2 - 1) * jitterFraction
        return base * jitter
    }
}
