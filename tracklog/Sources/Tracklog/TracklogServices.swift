import DroppyKit
import SwiftUI
import TracklogCore

/// Stable page ids for the Services flow. The connection pages are one per
/// local id, so a page id stays valid across a relaunch.
let tracklogServicesPageID = "services"
let tracklogAddServicePageID = "add-service"

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
                        "Connect the services you use. Delivery to them arrives in a later update. "
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

// MARK: - Add service

/// Add service: the launch services, with ListenBrainz's token link.
struct TracklogAddServicePage: View {
    let droplet: TracklogDroplet
    @ObservedObject var state: TracklogAppState

    @State private var token = ""
    @State private var errorMessage: String?
    @State private var isLinking = false

    private var trimmedToken: String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Until re-auth lands, there is nothing more to add on a connected
    /// ListenBrainz endpoint.
    private var listenBrainzIdentity: String? {
        state.connection(kind: .listenBrainz)?.identity
    }

    var body: some View {
        DropletSettingsPage {
            DropletSettingsSection {
                VStack(alignment: .leading, spacing: 2) {
                    settingsSectionHeader("Add a service")
                    Text(
                        "Tracklog will send every listen to each service you connect and enable. "
                            + "Delivery arrives in a later update.",
                    )
                    .font(.body)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                }
            } content: {
                DropletSettingsCard {
                    ForEach(ServiceKind.allCases) { kind in
                        DropletControlRow(title: kind.displayName) {
                            DropletValuePill(text: status(for: kind))
                        }
                    }
                }
            }

            DropletSettingsSection {
                VStack(alignment: .leading, spacing: 2) {
                    settingsSectionHeader("ListenBrainz")
                    Text(
                        "Paste the user token from your ListenBrainz settings. "
                            + "The token is checked with ListenBrainz before the connection is saved, "
                            + "then kept in the Keychain rather than the local database.",
                    )
                    .font(.body)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                }
            } content: {
                DropletSettingsCard {
                    if let listenBrainzIdentity {
                        linkedRows(identity: listenBrainzIdentity)
                    } else {
                        tokenForm
                    }
                }
            }

            if let errorMessage, listenBrainzIdentity == nil {
                DropletSettingsSection {
                    settingsSectionHeader("Not linked")
                } content: {
                    DropletSettingsCard {
                        Text(errorMessage)
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func status(for kind: ServiceKind) -> String {
        switch kind {
        case .listenBrainz:
            listenBrainzIdentity == nil ? "Not connected" : "Connected"
        case .lastFM, .libreFM:
            "Later update"
        }
    }

    private var tokenForm: some View {
        DropletStackedRow(title: "User token") {
            VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                SecureField("Paste your ListenBrainz user token", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("ListenBrainz user token")
                Text("The field is secure. A saved token is never shown again.")
                    .font(.callout)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                HStack(spacing: DroppySpacing.sm) {
                    Spacer(minLength: 0)
                    Button("Link") {
                        link()
                    }
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
                    .disabled(isLinking || trimmedToken.isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    @ViewBuilder
    private func linkedRows(identity: String) -> some View {
        DropletControlRow(title: "Connected") {
            DropletValuePill(text: identity)
        }
        DropletStackedRow(title: "Saved") {
            Text("The token is in the Keychain. The connection is listed on the Services page.")
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

    private func link() {
        guard !isLinking, !trimmedToken.isEmpty else { return }
        isLinking = true
        errorMessage = nil
        let candidate = trimmedToken
        Task {
            do {
                _ = try await droplet.linkListenBrainz(token: candidate)
                token = ""
            } catch {
                errorMessage = error.localizedDescription
            }
            isLinking = false
        }
    }
}
