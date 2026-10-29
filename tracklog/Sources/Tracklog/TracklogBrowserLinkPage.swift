import DroppyKit
import SwiftUI
import TracklogCore

// MARK: - Shared browser link

/// The browser-link page shared by the Last.fm-protocol services. The page
/// model lives in the droplet, so a rebuilt view never loses the pending
/// token; leaving the page cancels it.
struct TracklogBrowserLinkPage: View {
    let droplet: TracklogDroplet
    @ObservedObject var state: TracklogAppState
    let kind: ServiceKind
    let serviceName: String
    /// The root the link was started against, shown for a configurable
    /// service. `nil` hides the row.
    let endpoint: ServiceEndpoint?
    let link: LastFMLinkModel?
    let unavailableNote: String

    var body: some View {
        if let link {
            DropletSettingsPage {
                TracklogBrowserLinkFlow(
                    connection: state.connection(kind: kind, endpoint: endpoint),
                    serviceName: serviceName,
                    endpoint: endpoint,
                    link: link,
                    doneTitle: "Back to services",
                    done: { droplet.goBackInSettings() },
                )
            }
        } else {
            DropletSettingsPage {
                DropletSettingsSection {
                    settingsSectionHeader(LocalizedStringKey(serviceName))
                } content: {
                    DropletSettingsCard {
                        DropletStackedRow(title: unavailableNote) {
                            EmptyView()
                        }
                    }
                }
            }
        }
    }
}

/// One browser link's phases. It returns sections rather than its own page, so
/// a connection page can host a re-auth in place.
struct TracklogBrowserLinkFlow: View {
    /// An already-linked connection shows the completed card instead of
    /// starting a new link. A re-auth passes `nil` and starts its own model.
    let connection: Connection?
    let serviceName: String
    let endpoint: ServiceEndpoint?
    @ObservedObject var link: LastFMLinkModel
    let doneTitle: String
    let done: () -> Void

    var body: some View {
        Group {
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
                settingsSectionHeader(LocalizedStringKey(serviceName))
                Text(
                    "Tracklog is asking \(serviceName) for a request token. "
                        + "Your browser opens as soon as the token arrives.",
                )
                .font(.body)
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            }
        } content: {
            DropletSettingsCard {
                serverRow
                DropletControlRow(title: "Status") {
                    DropletValuePill(text: "Starting")
                }
            }
        }
    }

    private var waiting: some View {
        DropletSettingsSection {
            VStack(alignment: .leading, spacing: 2) {
                settingsSectionHeader("Waiting for \(serviceName)")
                Text(
                    "Authorize Tracklog in your browser, then come back. "
                        + "This page checks automatically, and you can check again at any time.",
                )
                .font(.body)
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            }
        } content: {
            DropletSettingsCard {
                serverRow
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
                    Button("Open \(serviceName) again") {
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
                serverRow
                Text(message)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                DropletControlRow(title: serviceName) {
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
                DropletControlRow(title: serviceName) {
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
            settingsSectionHeader(LocalizedStringKey(serviceName))
        } content: {
            DropletSettingsCard {
                DropletControlRow(title: "Connected") {
                    DropletValuePill(text: connection.identity)
                }
                DropletStackedRow(title: "Server") {
                    Text(connection.endpoint.description)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
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
                    Button(doneTitle) {
                        done()
                    }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
            }
        }
    }

    @ViewBuilder
    private var serverRow: some View {
        if let endpoint {
            DropletStackedRow(title: "Server") {
                Text(endpoint.description)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }
}
