import Foundation
import Testing
@testable import TracklogCore

@Suite("Delivery retry schedule")
struct DeliveryScheduleTests {
    private let neutralJitter: @Sendable () -> Double = { 0.5 }

    @Test func attemptsWalkTheFullScheduleThenStayAtTheCap() {
        let schedule = DeliveryRetrySchedule(random: neutralJitter)
        let expected: [TimeInterval] = [30, 60, 120, 300, 900, 1800, 3600, 3600, 3600, 3600]

        #expect((1 ... expected.count).map { schedule.delay(afterFailedAttempts: $0) } == expected)
    }

    @Test func jitterStaysInsideTwentyPercent() {
        let low = DeliveryRetrySchedule(random: { 0 })
        let high = DeliveryRetrySchedule(random: { 1 })

        #expect(low.delay(afterFailedAttempts: 1) == 24)
        #expect(high.delay(afterFailedAttempts: 1) == 36)
        #expect(low.delay(afterFailedAttempts: 7) == 2880)
        #expect(high.delay(afterFailedAttempts: 7) == 4320)
    }

    @Test func aMissingAttemptHasNoDelay() {
        let schedule = DeliveryRetrySchedule(random: neutralJitter)

        #expect(schedule.delay(afterFailedAttempts: 0) == 0)
    }
}
