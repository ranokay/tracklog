import DroppyKit
import SwiftUI
import TracklogCore

extension TracklogWidget {
    // MARK: - Copy

    var statusLine: String {
        if state.status.isCancelled {
            return trackingCancelledText
        }
        if !state.status.isPlaying {
            return "Paused"
        }
        switch state.status.phase {
        case .scrobbled:
            return "Scrobbled"
        case .armed:
            return "Scrobbling in \(time(state.status.remaining))"
        case .idle:
            return "Waiting"
        }
    }

    func elapsedValue(_ sample: MediaSample) -> String {
        let elapsed = time(sample.elapsed)
        guard sample.track.duration > 0 else { return "\(elapsed) played" }
        return "\(elapsed) of \(time(sample.track.duration))"
    }

    func spokenSeconds(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        return "\(total) \(total == 1 ? "second" : "seconds")"
    }

    func progress(for sample: MediaSample) -> Double {
        if sample.track.duration > 0 {
            return min(1, max(0, sample.elapsed / sample.track.duration))
        }
        return state.status.progress
    }

    func time(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    func clockTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
