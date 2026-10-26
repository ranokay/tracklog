import DroppyKit
import SwiftUI
import TracklogCore

/// The droplet's settings pane. Droppy already draws the page header, so this
/// starts with the first setting.
struct TracklogSettings: View {
    @ObservedObject var droplet: TracklogDroplet

    var body: some View {
        DropletSettingsPane {
            DropletSettingsCard {
                DropletToggleRow(
                    title: "Scrobble what I play",
                    subtitle: "Reads the system now-playing feed and sends listens to the services you connect.",
                    isOn: droplet.scrobblingBinding,
                )
            }

            DropletSettingsSection {
                settingsSectionHeader("Status")
            } content: {
                DropletSettingsCard {
                    DropletControlRow(title: "Media feed") {
                        DropletValuePill(text: droplet.helperAvailable ? "Available" : "Unavailable")
                    }
                    DropletControlRow(title: "Now playing") {
                        DropletValuePill(text: droplet.nowPlaying?.track.title ?? "Nothing")
                    }
                    DropletControlRow(title: "Scrobbles this session") {
                        DropletValuePill(text: "\(droplet.scrobbleCount)")
                    }
                    DropletControlRow(title: "Last scrobble") {
                        DropletValuePill(text: droplet.lastScrobble?.track.title ?? "None")
                    }
                }
            }

            DropletSettingsSection {
                settingsSectionHeader("Services")
            } content: {
                DropletSettingsCard {
                    serviceRow("Last.fm")
                    serviceRow("ListenBrainz")
                    serviceRow("Libre.fm")
                    serviceRow("Pleroma")
                }
            }

            DropletSettingsCard {
                DropletControlRow(title: "Queue") {
                    DropletValuePill(text: "Local")
                }
            }
        }
    }

    private func serviceRow(_ name: String) -> some View {
        DropletControlRow(title: name) {
            DropletValuePill(text: "Not connected")
        }
    }
}
