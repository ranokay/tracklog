import Foundation

/// The stable identifiers a presented HUD carries. A second request with the
/// same id replaces the first in place instead of queueing behind it.
public enum HUDIdentifier {
    public static let failureSignIn = "hud.failure.signin"
    public static let failureStuck = "hud.failure.stuck"
    public static let failureRateLimited = "hud.failure.ratelimit"
    public static let failureMedia = "hud.failure.media"
    public static let confirmLove = "hud.confirm.love"
    public static let confirmUnlove = "hud.confirm.unlove"
    public static let confirmHate = "hud.confirm.hate"
    public static let confirmBlock = "hud.confirm.block"
    public static let confirmPause = "hud.confirm.pause"
    public static let confirmResume = "hud.confirm.resume"
    public static let confirmExport = "hud.confirm.export"
    public static let recoverySignIn = "hud.recovery.signin"
    public static let recoveryQueue = "hud.recovery.queue"
}

/// How loudly a HUD asks for attention.
public enum HUDPriority: Int, Equatable, Sendable, Comparable {
    /// Shown only when nothing else is on the surface.
    case low = 0
    /// The normal band.
    case normal = 500
    /// Pre-empts normal, for things the user acted on directly.
    case high = 1000

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum HUDShape: Equatable, Sendable {
    case strip
    case card

    public var isCard: Bool {
        self == .card
    }
}

/// Where a card's action goes. The droplet maps the destination to the host
/// settings page or the History takeover.
public enum HUDDestination: Equatable, Sendable {
    case services
    case historyPending
}

public struct HUDAction: Equatable, Sendable {
    public let title: String
    public let destination: HUDDestination

    public init(title: String, destination: HUDDestination) {
        self.title = title
        self.destination = destination
    }

    public static let signIn = HUDAction(title: "Sign in", destination: .services)
    public static let review = HUDAction(title: "Review", destination: .historyPending)
}

/// How a pause was requested. The menu's fixed durations speak "for 1 hour";
/// a time-picker pause speaks "until 14:00".
public enum PauseAnnouncement: Equatable, Sendable {
    case duration(TimeInterval)
    case until(Date)
}

/// One event the composition root may present. The vocabulary is host-neutral:
/// Core owns the copy and mechanics, the droplet owns the views and host calls.
public enum HUDEvent: Equatable, Sendable {
    case needsSignIn(services: [String])
    case stuckQueue(count: Int, services: [String])
    case rateLimited(services: [String])
    case mediaFeedUnavailable
    case loved(services: [String])
    case unloved(services: [String])
    case hated(service: String)
    case blocked(title: String)
    case paused(PauseAnnouncement)
    case resumed
    case exported
    case signedIn(service: String, delivered: Int)
    case caughtUp(service: String, delivered: Int)
}

/// One fully resolved HUD, ready for a host adapter. For a card, `glyph` and
/// `word` describe the compact strip the host transitions through.
public struct HUDPresentation: Equatable, Sendable {
    public let id: String
    public let duration: TimeInterval
    public let priority: HUDPriority
    public let shape: HUDShape
    public let glyph: String
    public let word: String
    public let title: String?
    public let detail: String?
    public let action: HUDAction?
    public let spoken: String

    public init(
        id: String,
        duration: TimeInterval,
        priority: HUDPriority,
        shape: HUDShape,
        glyph: String,
        word: String,
        title: String? = nil,
        detail: String? = nil,
        action: HUDAction? = nil,
        spoken: String,
    ) {
        self.id = id
        self.duration = duration
        self.priority = priority
        self.shape = shape
        self.glyph = glyph
        self.word = word
        self.title = title
        self.detail = detail
        self.action = action
        self.spoken = spoken
    }

    public var isCard: Bool {
        shape.isCard
    }
}

public extension Connection {
    /// The name HUD copy uses. A configurable Libre.fm root names its host, not
    /// the protocol, and is truncated to fit the notch copy.
    var hudServiceName: String {
        guard kind == .libreFM, endpoint != .libreFM else {
            return kind.displayName
        }
        let host = URLComponents(string: endpoint.rawValue)?.host ?? kind.displayName
        let trimmed = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return Self.hudTruncatedName(trimmed)
    }

    private static func hudTruncatedName(_ name: String) -> String {
        guard name.count > 24 else { return name }
        return String(name.prefix(23)) + "…"
    }
}
