import SwiftUI
import TracklogCore

/// The Libre.fm browser-link page. The root was chosen on the Add service
/// page, so the model already talks to the listener's server.
struct TracklogLibreFMLinkPage: View {
    let droplet: TracklogDroplet
    @ObservedObject var state: TracklogAppState

    var body: some View {
        TracklogBrowserLinkPage(
            droplet: droplet,
            state: state,
            kind: .libreFM,
            serviceName: "Libre.fm",
            endpoint: droplet.libreFMLink?.endpoint,
            link: droplet.libreFMLink?.model,
            unavailableNote: "Libre.fm sign-in is unavailable. Choose a server on the Add service page first.",
        )
    }
}
