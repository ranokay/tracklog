import Foundation
import Testing
@testable import TracklogCore

@Suite("History feed")
struct HistoryFeedTests {
    @Test func groupsListensByLocalDayNewestFirst() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let morning = try #require(calendar.date(from: DateComponents(year: 2025, month: 5, day: 6, hour: 9)))
        let evening = try #require(calendar.date(from: DateComponents(year: 2025, month: 5, day: 6, hour: 21)))
        let previous = try #require(calendar.date(from: DateComponents(year: 2025, month: 5, day: 5, hour: 18)))

        let listens = [
            listen(title: "Evening", start: evening),
            listen(title: "Morning", start: morning),
            listen(title: "Previous", start: previous),
        ]

        let days = HistoryFeed.days(from: listens, calendar: calendar)

        #expect(days.count == 2)
        #expect(days[0].date == calendar.startOfDay(for: evening))
        #expect(days[0].count == 2)
        #expect(days[1].date == calendar.startOfDay(for: previous))
        #expect(days[1].count == 1)
        #expect(days.flatMap(\.listens).map(\.processed.title) == ["Evening", "Morning", "Previous"])
    }

    private func listen(title: String, start: Date) -> Listen {
        Listen(
            raw: ListenMetadata(title: title, artist: "Artist"),
            processed: ListenMetadata(title: title, artist: "Artist"),
            bundleID: "com.apple.Music",
            duration: 200,
            playedDuration: 100,
            startedAt: start,
            capturedAt: start,
        )
    }
}
