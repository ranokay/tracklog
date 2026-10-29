import Foundation

/// Account-action copy shared by the connection page and the host confirmation
/// dialogs, so one unlink says the same thing in both places.
enum TracklogConnectionCopy {
    /// "No pending scrobbles", "1 pending scrobble" or "12 pending scrobbles".
    static func pendingScrobbles(_ count: Int) -> String {
        switch count {
        case 0: "No pending scrobbles"
        case 1: "1 pending scrobble"
        default: "\(count) pending scrobbles"
        }
    }

    /// The unlink caveat the connection page must always state.
    static func revocation(service: String) -> String {
        "Tracklog cannot revoke access for you, so revoke Tracklog at \(service) after unlinking."
    }
}
