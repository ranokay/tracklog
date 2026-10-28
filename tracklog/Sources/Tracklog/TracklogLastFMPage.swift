import DroppyKit
import SwiftUI
import TracklogCore

/// The Last.fm browser-link page. The page model lives in the droplet, so a
/// rebuilt view never loses the pending token; leaving the page cancels it.
struct TracklogLastFMLinkPage: View {
    let droplet: TracklogDroplet
    @ObservedObject var state: TracklogAppState

    var body: some View {
        if let link = droplet.lastFMLink {
            TracklogLastFMLinkContent(droplet: droplet, state: state, link: link)
        } else {
            DropletSettingsPage {
                DropletSettingsSection {
                    settingsSectionHeader("Last.fm")
                } content: {
                    DropletSettingsCard {
                        DropletStackedRow(title: "Last.fm sign-in is unavailable in the harness.") {
                            EmptyView()
                        }
                    }
                }
            }
        }
    }
}

private struct TracklogLastFMLinkContent: View {
    let droplet: TracklogDroplet
    @ObservedObject var state: TracklogAppState
    @ObservedObject var link: LastFMLinkModel

    private var connection: Connection? {
        state.connection(kind: .lastFM)
    }

    var body: some View {
        DropletSettingsPage {
            if let connection {
                connected(connection)
            } else {
                phaseContent
            }
        }
        .onAppear {
            if connection == nil {
                link.start()
            }
        }
        .onDisappear {
            link.cancel()
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch link.phase {
        case .idle, .starting:
            starting
        case .waiting:
            waiting
        case let .linked(connection):
            connected(connection)
        case let .failed(message):
            failed(message)
        case .cancelled:
            cancelled
        }
    }

    private var starting: some View {
        DropletSettingsSection {
            VStack(alignment: .leading, spacing: 2) {
                settingsSectionHeader("Last.fm")
                Text(
                    "Tracklog is asking Last.fm for a request token. "
                        + "Your browser opens as soon as the token arrives.",
                )
                .font(.body)
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            }
        } content: {
            DropletSettingsCard {
                DropletControlRow(title: "Status") {
                    DropletValuePill(text: "Starting")
                }
            }
        }
    }

    private var waiting: some View {
        DropletSettingsSection {
            VStack(alignment: .leading, spacing: 2) {
                settingsSectionHeader("Waiting for Last.fm")
                Text(
                    "Authorize Tracklog in your browser, then come back. "
                        + "This page checks automatically, and you can check again at any time.",
                )
                .font(.body)
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            }
        } content: {
            DropletSettingsCard {
                DropletControlRow(title: "Status") {
                    DropletValuePill(text: link.isChecking ? "Checking" : "Waiting")
                }
                if let notice = link.notice {
                    DropletStackedRow(title: "Note") {
                        Text(notice)
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                DropletControlRow(title: "Browser") {
                    Button("Open Last.fm again") {
                        link.openAuthorizationPage()
                    }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
                DropletControlRow(title: "Check again") {
                    Button(link.isChecking ? "Checking…" : "Check again") {
                        Task { await link.checkNow() }
                    }
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
                    .disabled(link.isChecking)
                }
            }
        }
    }

    private func failed(_ message: String) -> some View {
        DropletSettingsSection {
            settingsSectionHeader("Needs attention")
        } content: {
            DropletSettingsCard {
                Text(message)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                DropletControlRow(title: "Last.fm") {
                    Button("Try again") {
                        link.start()
                    }
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
                }
            }
        }
    }

    private var cancelled: some View {
        DropletSettingsSection {
            settingsSectionHeader("Sign-in cancelled")
        } content: {
            DropletSettingsCard {
                Text("Your browser session was left alone. Start again when you are ready.")
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                DropletControlRow(title: "Last.fm") {
                    Button("Start again") {
                        link.start()
                    }
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
                }
            }
        }
    }

    private func connected(_ connection: Connection) -> some View {
        DropletSettingsSection {
            settingsSectionHeader("Last.fm")
        } content: {
            DropletSettingsCard {
                DropletControlRow(title: "Connected") {
                    DropletValuePill(text: connection.identity)
                }
                DropletStackedRow(title: "Session") {
                    Text(
                        "The session key is in the Keychain. "
                            + "Every enabled service receives the listens you play.",
                    )
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
                DropletControlRow(title: "Done") {
                    Button("Back to services") {
                        droplet.goBackInSettings()
                    }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
            }
        }
    }
}
