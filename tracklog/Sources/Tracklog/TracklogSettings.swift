import DroppyKit
import SwiftUI
import TracklogCore

/// The droplet's settings page: the Scrobbling root plus doors to the five
/// pages that hold everything typed. Droppy draws the page header.
struct TracklogSettings: View {
    @ObservedObject var droplet: TracklogDroplet

    var body: some View {
        DropletSettingsPane {
            DropletSettingsCard {
                DropletToggleRow(
                    title: "Scrobble what I play",
                    subtitle: "Reads the system now-playing feed and sends listens to the services you connect.",
                    isOn: droplet.scrobblingBinding
                )
            }

            DropletSettingsSection {
                settingsSectionHeader("Scrobbling")
            } content: {
                DropletSettingsCard {
                    DropletControlRow(title: "Pause") {
                        HStack(spacing: DroppySpacing.sm) {
                            DropletValuePill(text: "1 hour left")
                            Button("Resume") {}
                                .buttonStyle(DroppyQuietButtonStyle(size: .small))
                        }
                    }
                    DropletToggleRow(
                        title: "Send now playing",
                        subtitle: "Shows the current track on the services while it plays.",
                        isOn: .constant(true)
                    )
                    DropletControlRow(title: "Minimum length") {
                        DropletValuePill(text: "30 seconds")
                    }
                }
            }

            DropletSettingsSection {
                settingsSectionHeader("Settings")
            } content: {
                DropletSettingsCard {
                    DropletSettingsPageLink(
                        "Services",
                        subtitle: "Last.fm, ListenBrainz, Libre.fm and their accounts.",
                        page: "services",
                        icon: nil
                    )
                    DropletSettingsPageLink(
                        "Edits",
                        subtitle: "Replace track, artist and album fields.",
                        page: "edits",
                        icon: nil
                    )
                    DropletSettingsPageLink(
                        "Blocks",
                        subtitle: "Skip tracks, albums and artists you never want scrobbled.",
                        page: "blocks",
                        icon: nil
                    )
                    DropletSettingsPageLink(
                        "Data",
                        subtitle: "Export your history, edits and blocks.",
                        page: "data",
                        icon: nil
                    )
                    DropletSettingsPageLink(
                        "About",
                        subtitle: "Version, licence and credits.",
                        page: "about",
                        icon: nil
                    )
                }
            }
        }
    }
}

// MARK: - Pages

extension TracklogDroplet: SettingsPagesProviding {
    public func makeSettingsPage(id: String, context: SettingsPaneContext) -> AnyView? {
        switch id {
        case "services":
            return AnyView(TracklogServicesPage(droplet: self))
        case "edits":
            return AnyView(TracklogEditsPage())
        case "blocks":
            return AnyView(TracklogBlocksPage())
        case "data":
            return AnyView(TracklogDataPage())
        case "about":
            return AnyView(TracklogAboutPage())
        default:
            return nil
        }
    }
}

private struct TracklogServicesPage: View {
    @ObservedObject var droplet: TracklogDroplet

    var body: some View {
        DropletSettingsPage {
            DropletSettingsCard {
                DropletControlRow(title: "Last.fm") {
                    DropletValuePill(text: "Connected")
                }
                DropletControlRow(title: "ListenBrainz") {
                    DropletValuePill(text: "Needs sign-in")
                }
                DropletControlRow(title: "Libre.fm") {
                    DropletValuePill(text: "Connected")
                }
                DropletControlRow(title: "Add a service") {
                    Button("Add") {}
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
            }

            DropletSettingsSection {
                settingsSectionHeader("Reading from")
            } content: {
                DropletSettingsCard {
                    DropletControlRow(title: "Current connection") {
                        DropletValuePill(text: "Last.fm · ranokay")
                    }
                    DropletToggleRow(title: "Enabled", isOn: .constant(true))
                }
            }
        }
    }
}

private struct TracklogEditsPage: View {
    var body: some View {
        DropletSettingsPage {
            DropletSettingsCard {
                DropletControlRow(title: "Simple edits") {
                    DropletValuePill(text: "2 rules")
                }
                DropletControlRow(title: "Regex edits") {
                    DropletValuePill(text: "Later")
                }
                DropletControlRow(title: "Rule order") {
                    Button("Edit") {}
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
            }
        }
    }
}

private struct TracklogBlocksPage: View {
    var body: some View {
        DropletSettingsPage {
            DropletSettingsCard {
                DropletControlRow(title: "Windowlicker") {
                    DropletValuePill(text: "Track")
                }
                DropletControlRow(title: "Kid A") {
                    DropletValuePill(text: "Album")
                }
                DropletControlRow(title: "Add a block") {
                    Button("Add") {}
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
            }
        }
    }
}

private struct TracklogDataPage: View {
    var body: some View {
        DropletSettingsPage {
            DropletSettingsCard {
                DropletControlRow(title: "Export history") {
                    Button("Choose…") {}
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
                DropletControlRow(title: "Import") {
                    DropletValuePill(text: "Later")
                }
                DropletControlRow(title: "Local database") {
                    DropletValuePill(text: "on this Mac")
                }
            }
        }
    }
}

private struct TracklogAboutPage: View {
    var body: some View {
        DropletSettingsPage {
            DropletSettingsCard {
                DropletControlRow(title: "Version") {
                    DropletValuePill(text: "1.0.0")
                }
                DropletControlRow(title: "Licence") {
                    DropletValuePill(text: "MIT")
                }
                DropletControlRow(title: "Inspired by") {
                    DropletValuePill(text: "Pano Scrobbler")
                }
            }
        }
    }
}
