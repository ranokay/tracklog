// swiftlint:disable large_tuple
import Foundation
import Testing
@testable import TracklogCore

@Suite("Chart calendar windows")
struct ChartCalendarTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

    @Test func standardWindowsStartAtTheAgreedLocalBoundaries() throws {
        let calendar = chartCalendar(utc)
        let now = chartDate(2026, 10, 31, 12)
        let cases: [(ChartPeriod, Date, Date)] = [
            (.today, chartDate(2026, 10, 31), chartDate(2026, 11, 1)),
            (.week, chartDate(2026, 10, 26), chartDate(2026, 11, 2)),
            (.month, chartDate(2026, 10, 1), chartDate(2026, 11, 1)),
            (.year, chartDate(2026, 1, 1), chartDate(2027, 1, 1)),
        ]
        for (period, start, end) in cases {
            let selection = chartSelection(source: .local, period: period, now: now, calendar: calendar)
            let window = try ChartWindows.resolve(selection: selection, now: now, calendar: calendar)
            #expect(window.range == start ..< end, "\(period) starts at its boundary")
        }
        let allTime = chartSelection(source: .local, period: .allTime, now: now, calendar: calendar)
        #expect(try ChartWindows.resolve(selection: allTime, now: now, calendar: calendar).range == nil)
    }

    @Test func boundedWindowsAreStartInclusiveAndEndExclusive() throws {
        let calendar = chartCalendar(utc)
        let now = chartDate(2026, 10, 31, 12)
        let selection = chartSelection(source: .local, period: .today, now: now, calendar: calendar)
        let window = try ChartWindows.resolve(selection: selection, now: now, calendar: calendar)
        let range = try #require(window.range)
        #expect(range.contains(now))
        #expect(range.contains(chartDate(2026, 10, 31, 23, 59)))
        #expect(!range.contains(chartDate(2026, 11, 1)))
        #expect(!range.contains(chartDate(2026, 10, 30, 23, 59)))
    }

    @Test func weekStartsOnMondayAcrossTheWeekend() throws {
        let calendar = chartCalendar(utc)
        for day in [26, 27, 31] {
            let now = chartDate(2026, 10, day, 12)
            let selection = chartSelection(source: .local, period: .week, now: now, calendar: calendar)
            let window = try ChartWindows.resolve(selection: selection, now: now, calendar: calendar)
            #expect(window.range == chartDate(2026, 10, 26) ..< chartDate(2026, 11, 2))
        }
    }

    @Test func customIncludesBothSelectedDatesThroughTheNextMidnight() throws {
        let calendar = chartCalendar(utc)
        let now = chartDate(2026, 10, 31, 12)
        var selection = chartSelection(source: .local, period: .custom, now: now, calendar: calendar)
        selection.customStart = ChartDate(2026, 10, 1)
        selection.customEnd = ChartDate(2026, 10, 14)

        let range = try #require(
            ChartWindows.resolve(selection: selection, now: now, calendar: calendar).range,
        )
        #expect(range.contains(chartDate(2026, 10, 1)))
        #expect(range.contains(chartDate(2026, 10, 14, 23, 59)))
        #expect(!range.contains(chartDate(2026, 9, 30, 23, 59)))
        #expect(!range.contains(chartDate(2026, 10, 15)))
    }

    @Test func reversedCustomDatesAreRejected() {
        let calendar = chartCalendar(utc)
        let now = chartDate(2026, 10, 31, 12)
        var selection = chartSelection(source: .local, period: .custom, now: now, calendar: calendar)
        selection.customStart = ChartDate(2026, 10, 14)
        selection.customEnd = ChartDate(2026, 10, 1)
        #expect(throws: ChartValidationError.reversedCustomRange) {
            try ChartWindows.resolve(selection: selection, now: now, calendar: calendar)
        }
    }

    @Test func dstDaysKeepTheirWallClockBoundaries() throws {
        let calendar = chartCalendar(losAngeles)
        let springNow = chartDate(2026, 3, 8, 12, timeZone: losAngeles)
        let spring = chartSelection(source: .local, period: .today, now: springNow, calendar: calendar)
        let springRange = try #require(
            ChartWindows.resolve(selection: spring, now: springNow, calendar: calendar).range,
        )
        #expect(springRange.upperBound.timeIntervalSince(springRange.lowerBound) == 23 * 3600)

        let fallNow = chartDate(2026, 11, 1, 12, timeZone: losAngeles)
        let fall = chartSelection(source: .local, period: .today, now: fallNow, calendar: calendar)
        let fallRange = try #require(
            ChartWindows.resolve(selection: fall, now: fallNow, calendar: calendar).range,
        )
        #expect(fallRange.upperBound.timeIntervalSince(fallRange.lowerBound) == 25 * 3600)
        #expect(calendar.component(.hour, from: fallRange.lowerBound) == 0)
    }

    @Test func aTimeZoneChangeMovesTheSameCalendarWindow() throws {
        let now = chartDate(2026, 10, 31, 12)
        let selection = chartSelection(
            source: .local,
            period: .today,
            now: now,
            calendar: chartCalendar(utc),
        )
        let utcRange = try #require(
            ChartWindows.resolve(selection: selection, now: now, calendar: chartCalendar(utc)).range,
        )
        let laRange = try #require(
            ChartWindows.resolve(selection: selection, now: now, calendar: chartCalendar(losAngeles)).range,
        )
        #expect(utcRange != laRange)
        #expect(laRange.contains(chartDate(2026, 11, 1, 3)))
        #expect(!utcRange.contains(chartDate(2026, 11, 1, 3)))
        #expect(utcRange.contains(chartDate(2026, 10, 31, 3)))
        #expect(!laRange.contains(chartDate(2026, 10, 31, 3)))
    }

    @Test func leapDayBelongsToItsDayMonthAndYear() throws {
        let calendar = chartCalendar(utc)
        let now = chartDate(2028, 2, 29, 12)
        for period in [ChartPeriod.today, .month, .year] {
            let selection = chartSelection(source: .local, period: period, now: now, calendar: calendar)
            let range = try #require(
                ChartWindows.resolve(selection: selection, now: now, calendar: calendar).range,
            )
            #expect(range.contains(now), "\(period) contains the leap day")
        }
        let today = chartSelection(source: .local, period: .today, now: now, calendar: calendar)
        #expect(try ChartWindows.resolve(selection: today, now: now, calendar: calendar).range
            == chartDate(2028, 2, 29) ..< chartDate(2028, 3, 1))
    }
}

// swiftlint:enable large_tuple
