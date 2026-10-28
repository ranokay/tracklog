import Foundation

/// The fixed Last.fm web root used by the browser authorization page.
///
/// The URL path is named "auth"; it is an endpoint, not a credential. This
/// constant lives apart from ``LastFMClient`` so automatic SonarCloud analysis
/// can exclude only this endpoint declaration while still scanning the client.
enum LastFMWebEndpoint {
    static let authorizationRoot = "https://www.last.fm/api/auth/"
}
