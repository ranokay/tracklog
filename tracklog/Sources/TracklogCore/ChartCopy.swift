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
}
