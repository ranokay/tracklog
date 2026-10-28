import Foundation

public extension LastFMClient {
    /// Sends `track.love` for one track. The artist and title must be
    /// non-empty; a missing pair throws a rejected service failure.
    func love(_ track: Track, sessionKey: String) async throws {
        let parameters = try identityParameters(title: track.title, artist: track.artist)
        _ = try await perform(method: "track.love", parameters: parameters, sessionKey: sessionKey)
    }

    /// Sends `track.unlove` for one track. The artist and title must be
    /// non-empty; a missing pair throws a rejected service failure.
    func unlove(_ track: Track, sessionKey: String) async throws {
        let parameters = try identityParameters(title: track.title, artist: track.artist)
        _ = try await perform(method: "track.unlove", parameters: parameters, sessionKey: sessionKey)
    }
}
