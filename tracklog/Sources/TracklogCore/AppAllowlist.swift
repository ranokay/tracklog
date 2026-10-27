import Foundation

/// One player the media feed has seen, and whether its plays may be captured.
///
/// The allow decision is the user's: Music and Spotify start allowed when the
/// apps table is created, and every other bundle identifier stays denied until
/// the Apps page allows it. An empty bundle identifier is not a player and is
/// never listed.
public struct SeenApp: Identifiable, Equatable, Sendable {
    public let bundleID: String
    public var isAllowed: Bool

    public var id: String {
        bundleID
    }

    public init(bundleID: String, isAllowed: Bool) {
        self.bundleID = bundleID
        self.isAllowed = isAllowed
    }
}

/// The players a database seeds as allowed, in Apps list order.
public enum SeededPlayers {
    public static let bundleIDs = ["com.apple.Music", "com.spotify.client"]
}

/// Durable player allowlist. The capture pipeline asks it before reading a
/// sample, so a denied app produces no now playing and no history.
public protocol AppAllowlistStore: Sendable {
    /// Every player the feed has seen, in the order it first saw them.
    func apps() async throws -> [SeenApp]
    /// Whether the player may capture. An unknown or empty identifier is denied.
    func isAllowed(_ bundleID: String) async throws -> Bool
    /// Adds a player as denied. Returns the stored row, or `nil` for an empty
    /// identifier, which is never listed.
    @discardableResult
    func recordSeen(_ bundleID: String) async throws -> SeenApp?
    /// Changes one listed player's decision. Unknown identifiers are ignored.
    func setAllowed(_ bundleID: String, allowed: Bool) async throws
}
