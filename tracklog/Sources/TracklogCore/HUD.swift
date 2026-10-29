import Foundation

/// The mechanics a strip class shares, bundled so `strip` stays a small
/// builder rather than a six-argument call at every case.
struct HUDStripStyle: Sendable {
    let duration: TimeInterval
    let priority: HUDPriority

    static let failure = HUDStripStyle(duration: 4, priority: .normal)
    static let confirmation = HUDStripStyle(duration: 2, priority: .high)
    static let recovery = HUDStripStyle(duration: 2, priority: .low)
}

/// Turns one event into the exact copy, duration, priority and shape #29
/// settled. Pure and host-neutral so tests assert the vocabulary without
/// touching SwiftUI.
public enum HUD {
    static let cardDuration: TimeInterval = 8

    public static func resolve(_ event: HUDEvent) -> HUDPresentation {
        switch event {
        case .needsSignIn, .stuckQueue, .rateLimited, .mediaFeedUnavailable:
            failure(event)
        case .loved, .unloved, .hated, .blocked, .paused, .resumed, .exported:
            confirmation(event)
        case .signedIn, .caughtUp:
            recovery(event)
        }
    }

    private static func failure(_ event: HUDEvent) -> HUDPresentation {
        switch event {
        case let .needsSignIn(services):
            needsSignIn(services)
        case let .stuckQueue(count, services):
            stuckQueue(count: count, services: services)
        case let .rateLimited(services):
            rateLimited(services)
        case .mediaFeedUnavailable:
            strip(
                id: HUDIdentifier.failureMedia,
                glyph: "waveform.slash",
                word: "No feed",
                spoken: "Media feed unavailable. Playback will not be scrobbled.",
                style: .failure,
            )
        default:
            preconditionFailure("Not a failure HUD")
        }
    }

    private static func confirmation(_ event: HUDEvent) -> HUDPresentation {
        switch event {
        case let .loved(services):
            feedback(
                id: HUDIdentifier.confirmLove,
                glyph: "heart.fill",
                word: "Loved",
                verb: "Loved",
                services: services,
            )
        case let .unloved(services):
            feedback(
                id: HUDIdentifier.confirmUnlove,
                glyph: "heart",
                word: "Unloved",
                verb: "Unloved",
                services: services,
            )
        case let .hated(service):
            strip(
                id: HUDIdentifier.confirmHate,
                glyph: "heart.slash.fill",
                word: "Hated",
                spoken: "Hated on \(service).",
                style: .confirmation,
            )
        case let .blocked(title):
            strip(
                id: HUDIdentifier.confirmBlock,
                glyph: "hand.raised.fill",
                word: "Blocked",
                spoken: "Blocked \(title). It will not scrobble again.",
                style: .confirmation,
            )
        case let .paused(announcement):
            strip(
                id: HUDIdentifier.confirmPause,
                glyph: "pause.fill",
                word: "Paused",
                spoken: pauseSpeech(announcement),
                style: .confirmation,
            )
        case .resumed:
            strip(
                id: HUDIdentifier.confirmResume,
                glyph: "play.fill",
                word: "Resumed",
                spoken: "Scrobbling resumed.",
                style: .confirmation,
            )
        case .exported:
            strip(
                id: HUDIdentifier.confirmExport,
                glyph: "square.and.arrow.up",
                word: "Exported",
                spoken: "Settings exported.",
                style: .confirmation,
            )
        default:
            preconditionFailure("Not a confirmation HUD")
        }
    }

    private static func recovery(_ event: HUDEvent) -> HUDPresentation {
        switch event {
        case let .signedIn(service, delivered):
            strip(
                id: HUDIdentifier.recoverySignIn,
                glyph: "checkmark.circle.fill",
                word: "Signed in",
                spoken: "\(service) reconnected. \(scrobbles(delivered)) sent.",
                style: .recovery,
            )
        case let .caughtUp(service, delivered):
            strip(
                id: HUDIdentifier.recoveryQueue,
                glyph: "checkmark.circle.fill",
                word: "Sent",
                spoken: "\(service) is accepting scrobbles again. \(delivered) sent.",
                style: .recovery,
            )
        default:
            preconditionFailure("Not a recovery HUD")
        }
    }

    static func strip(
        id: String,
        glyph: String,
        word: String,
        spoken: String,
        style: HUDStripStyle,
    ) -> HUDPresentation {
        HUDPresentation(
            id: id,
            duration: style.duration,
            priority: style.priority,
            shape: .strip,
            glyph: glyph,
            word: word,
            spoken: spoken,
        )
    }
}
