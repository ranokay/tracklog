import DroppyKit
import SwiftUI
import TracklogCore

/// The droplet's settings pane. Droppy already draws the page header, so this
/// starts with the first setting.
struct TracklogSettings: View {
    let droplet: TracklogDroplet
    @ObservedObject var state: TracklogAppState

    var body: some View {
        DropletSettingsPane {
            DropletSettingsCard {
                DropletToggleRow(
                    title: "Scrobble what I play",
                    subtitle: "Reads the system now-playing feed and saves what you listen to on this Mac.",
                    isOn: droplet.scrobblingBinding,
                )
            }

            if let failure = state.failure {
                DropletSettingsSection {
                    settingsSectionHeader("Storage")
                } content: {
                    DropletSettingsCard {
                        DropletControlRow(title: failure.message) {
                            DropletValuePill(text: failureLabel(for: failure))
                        }
                        DropletStackedRow(title: "Diagnostics") {
                            Text(failure.diagnostics)
                                .font(.system(size: 11))
                                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            DropletSettingsSection {
                settingsSectionHeader("Status")
            } content: {
                DropletSettingsCard {
                    DropletControlRow(title: "Media feed") {
                        DropletValuePill(text: state.feedAvailable ? "Available" : "Unavailable")
                    }
                    DropletControlRow(title: "Now playing") {
                        DropletValuePill(text: state.nowPlaying?.track.title ?? "Nothing")
                    }
                    DropletControlRow(title: "Listens this session") {
                        DropletValuePill(text: "\(state.listenCount)")
                    }
                    DropletControlRow(title: "Last listen") {
                        DropletValuePill(text: state.lastListen?.processed.title ?? "None")
                    }
                }
            }

            DropletSettingsSection {
                settingsSectionHeader("History")
            } content: {
                DropletSettingsCard {
                    if state.listens.isEmpty {
                        DropletControlRow(title: "Nothing played yet") {
                            Text("Play something to start your history.")
                                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        }
                    } else {
                        ForEach(state.listens) { listen in
                            DropletControlRow(title: listen.processed.title) {
                                Text(listen.processed.artist)
                                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                                    .lineLimit(1)
                            }
                        }
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

    private func failureLabel(for failure: CaptureFailure) -> String {
        switch failure.stage {
        case .database: "Unavailable"
        case .storage: "Write failed"
        case .history: "Read failed"
        }
    }
}
