import DroppyKit
import SwiftUI
import TracklogCore

/// Stable page ids for the Services flow. The connection pages are one per
/// local id, so a page id stays valid across a relaunch.
let tracklogServicesPageID = "services"
let tracklogAddServicePageID = "add-service"
let tracklogLastFMLinkPageID = "lastfm-link"
let tracklogLibreFMLinkPageID = "librefm-link"
let tracklogLastFMAppCredentialsPageID = "lastfm-credentials"

private let tracklogConnectionPagePrefix = "connection-"

func tracklogConnectionPageID(_ id: Int64) -> String {
    "\(tracklogConnectionPagePrefix)\(id)"
}

func tracklogConnectionID(fromPage id: String) -> Int64? {
    guard id.hasPrefix(tracklogConnectionPagePrefix) else { return nil }
    return Int64(id.dropFirst(tracklogConnectionPagePrefix.count))
}

// MARK: - Services

/// The connection list: service, identity, endpoint, auth state and the
/// current read cursor, with Add service beneath it.
struct TracklogServicesPage: View {
    let droplet: TracklogDroplet
    @ObservedObject var state: TracklogAppState

    var body: some View {
        DropletSettingsPage {
            DropletSettingsSection {
                VStack(alignment: .leading, spacing: 2) {
                    settingsSectionHeader("Services")
                    Text(
                        "Connect the services you use. Every listen is sent to each service you enable, "
                            + "and retried from the queue when a service is unavailable. "
                            + "The current connection only decides which account service-backed reads show; "
                            + "it never changes where a scrobble goes, and local history stays on this Mac.",
                    )
                    .font(.body)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                }
            } content: {
                DropletSettingsCard {
                    if let failure = state.connectionsFailure {
                        DropletStackedRow(title: failure.message) {
                            VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                                Text("Capture and local history keep running.")
                                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                                Button("Try again") {
                                    Task { await droplet.reloadServices() }
                                }
                                .buttonStyle(DroppyQuietButtonStyle(size: .small))
                            }
                        }
                    } else if state.connections.isEmpty {
                        DropletStackedRow(
                            title: "No services connected. Your listens are still saved on this Mac.",
                        ) {
                            EmptyView()
                        }
                    } else {
                        ForEach(state.connections) { connection in
                            connectionRow(connection)
                        }
                    }

                    DropletSettingsPageLink(
                        "Add service",
                        subtitle: "Connect Last.fm, Libre.fm or ListenBrainz.",
                        page: tracklogAddServicePageID,
                    ) {
                        SettingsLinkTile(systemImage: "plus")
                    }
                }
            }

            DropletSettingsSection {
                VStack(alignment: .leading, spacing: 2) {
                    settingsSectionHeader("Last.fm app credentials")
                    Text(
                        "Use your own API key and shared secret when the built-in pair is "
                            + "missing or rejected by Last.fm.",
                    )
                    .font(.body)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                }
            } content: {
                DropletSettingsCard {
                    if let problem = state.lastFMAppCredentialProblem {
                        DropletStackedRow(title: problem.title) {
                            Text(problem.detail)
                                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    DropletSettingsPageLink(
                        state.lastFMOverridePresent
                            ? "Last.fm app credentials"
                            : "Set up Last.fm app credentials",
                        subtitle: state.lastFMOverridePresent
                            ? "Stored in the Keychain and used instead of the built-in pair."
                            : "Add your own API key and shared secret.",
                        page: tracklogLastFMAppCredentialsPageID,
                    ) {
                        SettingsLinkTile(systemImage: "key")
                    }
                }
            }
        }
    }

    private var connectionTileSize: CGFloat {
        DropletSettingsPageLink<EmptyView>.tileSize
    }

    private func connectionRow(_ connection: Connection) -> some View {
        let isCurrent = state.currentConnectionID == connection.id
        return Button {
            droplet.openConnectionPage(for: connection)
        } label: {
            HStack(alignment: .center, spacing: DroppySpacing.md) {
                SettingsLinkTile(systemImage: serviceSymbol(connection.kind))
                    .frame(width: connectionTileSize, height: connectionTileSize)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(connection.kind.displayName)
                        .lineLimit(1)
                    Text(connection.identity)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(connection.endpoint.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .layoutPriority(1)

                Spacer(minLength: 12)

                DropletValuePill(text: connection.status.displayName)
                if isCurrent {
                    DropletValuePill(text: "Current")
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Text("\(connection.kind.displayName), \(connection.identity), \(connection.endpoint.description)"),
        )
        .accessibilityValue(
            Text(
                isCurrent
                    ? "\(connection.status.displayName), current"
                    : connection.status.displayName,
            ),
        )
        .accessibilityHint(Text("Open connection settings"))
        .accessibilityAddTraits(.isButton)
    }

    private func serviceSymbol(_ kind: ServiceKind) -> String {
        switch kind {
        case .lastFM: "music.note"
        case .libreFM: "dot.radiowaves.left.and.right"
        case .listenBrainz: "brain"
        }
    }
}
