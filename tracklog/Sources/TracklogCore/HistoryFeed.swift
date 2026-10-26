import Foundation

/// One local day's listens, in the order the feed shows them.
public struct HistoryDay: Identifiable, Equatable, Sendable {
    /// Midnight at the start of the day, in the calendar that grouped it.
    public let date: Date
    public let listens: [Listen]

    public var id: Date {
        date
    }

    public var count: Int {
        listens.count
    }
}

public enum HistoryFeed {
    /// Groups an already newest-first feed into local calendar days.
    public static func days(from listens: [Listen], calendar: Calendar = .current) -> [HistoryDay] {
        var order: [Date] = []
        var groups: [Date: [Listen]] = [:]
        for listen in listens {
            let day = calendar.startOfDay(for: listen.startedAt)
            if groups[day] == nil {
                order.append(day)
            }
            groups[day, default: []].append(listen)
        }
        return order.map { HistoryDay(date: $0, listens: groups[$0] ?? []) }
    }
}
