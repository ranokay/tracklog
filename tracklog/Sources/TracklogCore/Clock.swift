import Foundation

/// The time source the capture pipeline reads. Tests advance a fake.
@MainActor
public protocol Clock {
    var now: Date { get }
    /// Sleeps until `date`, or returns early when the task is cancelled.
    func sleep(until date: Date) async throws
}

@MainActor
public struct SystemClock: Clock {
    public init() {}

    public var now: Date {
        Date()
    }

    public func sleep(until date: Date) async throws {
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return }
        try await Task.sleep(for: .seconds(interval))
    }
}
