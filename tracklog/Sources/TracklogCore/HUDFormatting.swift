import Foundation

extension HUD {
    // MARK: - Card builders

    static func needsSignIn(_ rawServices: [String]) -> HUDPresentation {
        let services = serviceNames(rawServices)
        let many = services.count > 1
        let subject = many ? joined(services) : services[0]
        return HUDPresentation(
            id: HUDIdentifier.failureSignIn,
            duration: cardDuration,
            priority: .normal,
            shape: .card,
            glyph: "person.crop.circle.badge.exclamationmark",
            word: "Sign in",
            title: many ? "\(services.count) services need sign-in" : "\(subject) needs sign-in",
            detail: "Scrobbles are waiting",
            action: .signIn,
            spoken: "\(subject) \(many ? "need" : "needs") sign-in. Scrobbles are waiting.",
        )
    }

    static func stuckQueue(count: Int, services rawServices: [String]) -> HUDPresentation {
        let services = serviceNames(rawServices)
        let many = services.count > 1
        let countText = scrobbles(count)
        let detail = many
            ? "Across \(services.count) services"
            : "\(services[0]) is not accepting \(count == 1 ? "it" : "them")"
        let spoken = many
            ? "\(countText) \(count == 1 ? "is" : "are") waiting across \(services.count) services."
            : "\(countText) \(count == 1 ? "is" : "are") waiting for \(services[0]), "
            + "which is not accepting \(count == 1 ? "it" : "them")."
        return HUDPresentation(
            id: HUDIdentifier.failureStuck,
            duration: cardDuration,
            priority: .normal,
            shape: .card,
            glyph: "tray.full",
            word: "Waiting",
            title: "\(countText) waiting",
            detail: detail,
            action: .review,
            spoken: spoken,
        )
    }

    static func rateLimited(_ rawServices: [String]) -> HUDPresentation {
        let services = serviceNames(rawServices)
        let many = services.count > 1
        let spoken = many
            ? "\(services.count) services are rate limited. Retrying automatically."
            : "\(services[0]) is rate limited. Retrying automatically."
        return strip(
            id: HUDIdentifier.failureRateLimited,
            glyph: "clock.arrow.circlepath",
            word: "Retrying",
            spoken: spoken,
            style: .failure,
        )
    }

    static func feedback(
        id: String,
        glyph: String,
        word: String,
        verb: String,
        services rawServices: [String],
    ) -> HUDPresentation {
        let services = serviceNames(rawServices)
        let spoken = services.count > 1
            ? "\(verb) on \(services.count) services."
            : "\(verb) on \(services[0])."
        return strip(
            id: id,
            glyph: glyph,
            word: word,
            spoken: spoken,
            style: .confirmation,
        )
    }

    // MARK: - Formatting

    static func pauseSpeech(_ announcement: PauseAnnouncement) -> String {
        switch announcement {
        case let .duration(seconds):
            "Scrobbling paused for \(durationText(seconds))."
        case let .until(date):
            "Scrobbling paused until \(clockTime(date))."
        }
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded()))
        if minutes >= 60, minutes % 60 == 0 {
            let hours = minutes / 60
            return "\(hours) \(hours == 1 ? "hour" : "hours")"
        }
        return "\(minutes) \(minutes == 1 ? "minute" : "minutes")"
    }

    static func clockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func scrobbles(_ count: Int) -> String {
        let count = max(0, count)
        return "\(count) \(count == 1 ? "scrobble" : "scrobbles")"
    }

    /// One name per targeted connection, in the order the runtime supplies
    /// them. Different connections may share a visible label (two GNU FM roots
    /// on one host, or two long hosts that truncate alike), so this never
    /// collapses equal strings: the count is the connection count.
    static func serviceNames(_ services: [String]) -> [String] {
        let cleaned = services
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return cleaned.isEmpty ? ["Service"] : cleaned
    }

    static func joined(_ services: [String]) -> String {
        guard let last = services.last else { return "Service" }
        guard services.count > 2 else { return services.joined(separator: " and ") }
        return services.dropLast().joined(separator: ", ") + " and \(last)"
    }
}
