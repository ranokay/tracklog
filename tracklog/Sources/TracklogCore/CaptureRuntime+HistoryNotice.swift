import Foundation

// MARK: - History jump notice

extension CaptureRuntime {
    func count(on date: Date, store: any ListenStore) async -> Int? {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return try? await store.count(in: start ..< end)
    }

    func jumpNotice(
        requestedAt: Date,
        position: HistoryPosition,
        total: Int,
        dayCount: Int?,
    ) -> HistoryJumpNotice? {
        guard total > 0 else { return nil }
        if case .newest = position {
            return HistoryJumpNotice(requestedAt: requestedAt, kind: .afterNewest)
        }
        if dayCount == 0 {
            return HistoryJumpNotice(requestedAt: requestedAt, kind: .emptyDay)
        }
        return HistoryJumpNotice(requestedAt: requestedAt, kind: .positioned)
    }
}
