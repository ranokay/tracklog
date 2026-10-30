import DroppyKit
import SwiftUI
import TracklogCore

public extension TracklogDroplet {
    func dismissTakeoverForSettings() {
        guard let host, host.notchSurface.expandedState.current?.surfaceID == tracklogHistorySurfaceID else {
            return
        }
        host.notchSurface.dismissExpandedSurface(tracklogHistorySurfaceID)
    }

    /// The player's display name, for the widget's status line.
    var sourceName: String? {
        guard let bundleID = state.nowPlaying?.track.bundleID, !bundleID.isEmpty else { return nil }
        return displayName(for: bundleID)
    }
}

// MARK: - Shelf widget

extension TracklogDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        [
            ShelfWidgetDescriptor(
                id: "tracklog",
                title: "Tracklog",
                systemImage: "waveform",
                layoutTraits: ShelfWidgetLayoutTraits(
                    preferredSoloWidth: 420,
                    preferredPairedWidth: 210,
                    contentHeight: .fixed(150),
                ),
            ),
        ]
    }

    public func makeWidgetView(_: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        AnyView(TracklogWidget(droplet: self, state: state, context: context))
    }

    public func makeWidgetSettingsPopover(_: ShelfWidgetID) -> AnyView? {
        nil
    }
}

/// A Libre.fm browser link in flight. The root and its page model travel
/// together, so a model can never outlive the server it was started against.
struct TracklogLibreFMLink {
    let endpoint: ServiceEndpoint
    let model: LastFMLinkModel
}

/// A browser re-auth in flight on one connection's page.
struct TracklogReauthLink {
    let connectionID: Int64
    let model: LastFMLinkModel
}
