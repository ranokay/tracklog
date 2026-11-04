import Foundation

/// The shared chart wording used by the native takeover and asserted by the
/// read-model tests. Service periods keep their returned semantics; local
/// periods keep the calendar caption.
public enum ChartCopy {
    public static func periodLabel(_ state: ChartViewState, calendar: Calendar) -> String {
        if let detail = state.periodDetail {
            return detail
        }
        return ChartWindows.caption(selection: state.selection, calendar: calendar)
    }

    public static func listTitle(type: ChartType, period: String) -> String {
        "Top 50 \(type.displayName.lowercased()) · \(period)"
    }

    public static func countUnit(_ count: Int, _ unit: ChartCountUnit) -> String {
        count == 1 ? unit.singular : unit.plural
    }

    public static func rowAccessibilityLabel(
        rank: Int,
        title: String,
        subtitle: String,
        count: Int,
        unit: ChartCountUnit,
    ) -> String {
        var parts = ["Rank \(rank)", title]
        if !subtitle.isEmpty {
            parts.append(subtitle)
        }
        parts.append("\(count) \(countUnit(count, unit))")
        return parts.joined(separator: ", ")
    }

    public static func rowAccessibilityValue(source: String, period: String) -> String {
        "\(source), \(period)"
    }

    public static func shownCount(_ count: Int, type: ChartType) -> String {
        "\(count) \(count == 1 ? type.singularName : type.displayName.lowercased()) shown"
    }

    public static func totalLabel(count: Int, caption: String, savedAt: Date?, age: String) -> String {
        if savedAt != nil {
            return "\(count) \(caption), saved \(age)"
        }
        return "\(count) \(caption)"
    }

    /// The one relative-age wording, measured against the current clock so a
    /// retained row's age keeps growing while it is displayed.
    public static func relativeAge(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 {
            return "just now"
        }
        if seconds < 3600 {
            return "\(Int(seconds / 60)) min ago"
        }
        if seconds < 86_400 {
            return "\(Int(seconds / 3600)) hr ago"
        }
        return "\(Int(seconds / 86_400)) d ago"
    }

    /// ListenBrainz returns `from_ts` and an exclusive midnight `to_ts` for
    /// week/month/year, so the displayed span ends on the last included day.
    /// Those bounds are UTC calendar dates and are formatted in UTC; the
    /// `statistics updated` instant stays in the Mac's zone. All time ends at
    /// the latest returned listen, so its `to_ts` is shown as supplied.
    public static func returnedRangeLabel(
        _ range: ChartReturnedRange,
        period: ChartPeriod,
        serviceKind: ServiceKind?,
        now: Date,
        calendar: Calendar,
    ) -> String {
        let end: Date = if serviceKind == .listenBrainz, period != .allTime {
            range.end.addingTimeInterval(-1)
        } else {
            range.end
        }
        let locale = calendar.locale ?? .autoupdatingCurrent
        let span = "Returned span \(utcDate(range.start, locale: locale)) – \(utcDate(end, locale: locale))"
        let age = "data ends \(relativeAge(range.end, now: now))"
        guard let updated = range.lastUpdated else {
            return "\(span) · \(age)"
        }
        return "\(span) · \(age) · statistics updated \(localDateTime(updated, locale: locale, in: calendar))"
    }

    private static func utcDate(_ date: Date, locale: Locale) -> String {
        let calendar = ChartCalendar.utc
        let style = Date.FormatStyle(
            date: .abbreviated,
            time: .omitted,
            locale: locale,
            calendar: calendar,
            timeZone: calendar.timeZone,
        )
        return date.formatted(style)
    }

    private static func localDateTime(_ date: Date, locale: Locale, in calendar: Calendar) -> String {
        let style = Date.FormatStyle(
            date: .abbreviated,
            time: .shortened,
            locale: locale,
            calendar: calendar,
            timeZone: calendar.timeZone,
        )
        return date.formatted(style)
    }
}
