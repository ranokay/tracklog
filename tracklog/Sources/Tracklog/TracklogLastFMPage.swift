import SwiftUI
import TracklogCore

/// The Last.fm browser-link page. The page model lives in the droplet, so a
/// rebuilt view never loses the pending token; leaving the page cancels it.
struct TracklogLastFMLinkPage: View {
    let droplet: TracklogDroplet
    @ObservedObject var state: TracklogAppState

    var body: some View {
        TracklogBrowserLinkPage(
            droplet: droplet,
            state: state,
            kind: .lastFM,
            serviceName: "Last.fm",
            endpoint: nil,
            link: droplet.lastFMLink,
            unavailableNote: "Last.fm sign-in is unavailable in the harness.",
        )
    }
}
