import DroppyKit
import SwiftUI

/// A settings page door that is also keyboard-operable. The SDK link draws the
/// native row and handles the pointer; this wrapper makes the row focusable and
/// forwards Return/Space to the same public page opener.
struct TracklogSettingsPageLink<Tile: View>: View {
    let droplet: TracklogDroplet
    let title: String
    let subtitle: String?
    let pageID: String
    @ViewBuilder let tile: () -> Tile

    @Environment(\.dropletSettingsPageOpener) private var opener

    init(
        droplet: TracklogDroplet,
        _ title: String,
        subtitle: String? = nil,
        page id: String,
        @ViewBuilder tile: @escaping () -> Tile,
    ) {
        self.droplet = droplet
        self.title = title
        self.subtitle = subtitle
        pageID = id
        self.tile = tile
    }

    var body: some View {
        DropletSettingsPageLink(title, subtitle: subtitle, page: pageID) {
            tile()
        }
        .focusable()
        .onKeyPress(.return) {
            activate()
            return .handled
        }
        .onKeyPress(.space) {
            activate()
            return .handled
        }
    }

    private func activate() {
        if let opener {
            opener(page: pageID, title: title)
        } else {
            _ = droplet.openSettingsPage(pageID, title: title)
        }
    }
}
