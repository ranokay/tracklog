import DroppyKit
import SwiftUI
import TracklogCore

// MARK: - One connection

/// One connection's page: identity, endpoint, enabled switch, current cursor,
/// and the account actions. Signing in again runs the same flow the Add
/// service page uses; unlinking asks through the host first.
struct TracklogConnectionPage: View {
    let droplet: TracklogDroplet
    @ObservedObject var state: TracklogAppState
    let connectionID: Int64

    @State private var actionError: String?
    @State private var reauthToken = ""
    @State private var isReauthenticating = false

    private var connection: Connection? {
        state.connection(id: connectionID)
    }

    private var reauthLink: LastFMLinkModel? {
        guard state.reauthConnectionID == connectionID else { return nil }
        return droplet.reauthLink(for: connectionID)
    }

    private var trimmedToken: String {
        reauthToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        DropletSettingsPage {
            if let connection {
                DropletSettingsSection {
                    settingsSectionHeader("Connection")
                } content: {
                    DropletSettingsCard {
                        DropletControlRow(title: "Service") {
                            DropletValuePill(text: connection.kind.displayName)
                        }
                        DropletStackedRow(title: "Identity") {
                            Text(connection.identity)
                                .textSelection(.enabled)
                        }
                        DropletStackedRow(title: "Endpoint") {
                            Text(connection.endpoint.description)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        DropletToggleRow(
                            title: "Enabled",
                            subtitle: "Saved now; delivery arrives later. Turning it off holds its deliveries and discards nothing.",
                            isOn: enabledBinding(for: connection),
                        )
                        DropletControlRow(title: "Use for reading") {
                            if state.currentConnectionID == connection.id {
                                DropletValuePill(text: "Current")
                            } else {
                                Button("Use for reading") {
                                    setCurrent()
                                }
                                .buttonStyle(DroppyQuietButtonStyle(size: .small))
                            }
                        }
                    }
                }

                if let reauthLink {
                    TracklogBrowserLinkFlow(
                        connection: nil,
                        serviceName: connection.kind.displayName,
                        endpoint: connection.endpoint,
                        link: reauthLink,
                        doneTitle: "Done",
                        done: { droplet.cancelReauth() },
                    )
                } else {
                    accountSection(connection)
                }

                if let actionError {
                    DropletSettingsSection {
                        settingsSectionHeader("Not changed")
                    } content: {
                        DropletSettingsCard {
                            Text(actionError)
                                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } else {
                DropletSettingsSection {
                    settingsSectionHeader("Connection")
                } content: {
                    DropletSettingsCard {
                        DropletStackedRow(title: "This connection is no longer available.") {
                            Button("Back to services") {
                                droplet.goBackInSettings()
                            }
                            .buttonStyle(DroppyQuietButtonStyle(size: .small))
                        }
                    }
                }
            }
        }
        .onDisappear {
            droplet.cancelReauth()
        }
    }

    // MARK: - Account

    private func accountSection(_ connection: Connection) -> some View {
        DropletSettingsSection {
            VStack(alignment: .leading, spacing: 2) {
                settingsSectionHeader("Account")
                Text(accountDetail(connection))
                    .font(.body)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } content: {
            DropletSettingsCard {
                if connection.kind == .listenBrainz {
                    listenBrainzSignIn
                } else if droplet.canStartBrowserSignIn(connection) {
                    DropletControlRow(title: "Sign in again") {
                        Button("Sign in with \(connection.kind.displayName)") {
                            actionError = nil
                            droplet.startReauth(for: connection)
                        }
                        .buttonStyle(DroppyAccentButtonStyle(size: .small))
                    }
                } else {
                    DropletControlRow(title: "Sign in again") {
                        DropletValuePill(text: "Unavailable in the harness")
                    }
                }
                DropletControlRow(title: "Unlink") {
                    Button("Unlink") {
                        confirmUnlink(connection)
                    }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small, destructive: true))
                }
            }
        }
    }

    private func accountDetail(_ connection: Connection) -> String {
        let revocation = TracklogConnectionCopy.revocation(service: connection.kind.displayName)
        if connection.authState == .needsSignIn {
            return "\(connection.kind.displayName) rejected this connection's saved credential. "
                + "Its pending scrobbles are held until it signs in again. "
                + "Unlinking deletes the saved credential and abandons this connection's pending "
                + "scrobbles. Local history is kept, and re-linking does not resend them. "
                + revocation
        }
        return "Signing in again keeps this connection and its pending scrobbles. "
            + "Unlinking deletes the saved credential and abandons this connection's pending "
            + "scrobbles. Local history is kept, and re-linking does not resend them. "
            + revocation
    }

    private var listenBrainzSignIn: some View {
        DropletStackedRow(title: "Sign in again") {
            VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                SecureField("Paste a new ListenBrainz user token", text: $reauthToken)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("New ListenBrainz user token")
                Text(
                    "The token is checked with ListenBrainz before this connection changes. "
                        + "A saved token is never shown again.",
                )
                .font(.callout)
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DroppySpacing.sm) {
                    Spacer(minLength: 0)
                    Button(isReauthenticating ? "Signing in…" : "Sign in") {
                        signInListenBrainz()
                    }
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
                    .disabled(isReauthenticating || trimmedToken.isEmpty)
                }
            }
        }
    }

    // MARK: - Actions

    private func enabledBinding(for connection: Connection) -> Binding<Bool> {
        Binding(
            get: {
                state.connection(id: connectionID)?.isEnabled
                    ?? connection.isEnabled
            },
            set: { enabled in
                actionError = nil
                Task {
                    do {
                        try await droplet.setConnectionEnabled(id: connectionID, enabled: enabled)
                    } catch {
                        actionError = error.localizedDescription
                    }
                }
            },
        )
    }

    private func setCurrent() {
        actionError = nil
        Task {
            do {
                try await droplet.setCurrentConnection(connectionID)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func signInListenBrainz() {
        guard !isReauthenticating, !trimmedToken.isEmpty else { return }
        isReauthenticating = true
        actionError = nil
        let token = trimmedToken
        Task {
            do {
                try await droplet.reauthenticateListenBrainz(
                    connectionID: connectionID,
                    token: token,
                )
                reauthToken = ""
            } catch ConnectionError.reauthenticationCancelled {
                // The replacement was declined, so the old account stays.
            } catch {
                actionError = error.localizedDescription
            }
            isReauthenticating = false
        }
    }

    /// The host states the pending count before anything is deleted. Cancel,
    /// dismissal and a host without a presenter all leave the connection alone.
    private func confirmUnlink(_ connection: Connection) {
        actionError = nil
        Task {
            let pending: Int
            do {
                pending = try await droplet.pendingDeliveryCount(forConnection: connectionID)
            } catch {
                actionError = error.localizedDescription
                return
            }
            let confirmed = DropletConfirmationDialog.present(
                title: "Unlink \(connection.kind.displayName)?",
                message: unlinkMessage(pending: pending, service: connection.kind.displayName),
                confirmTitle: "Unlink",
                symbol: "trash",
            )
            guard confirmed else { return }
            do {
                try await droplet.unlinkConnection(id: connectionID)
                droplet.goBackInSettings()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func unlinkMessage(pending: Int, service: String) -> String {
        TracklogConnectionCopy.pendingScrobbles(pending)
            + " will be abandoned. The listens stay in local history and are not sent later. "
            + "The saved credential is deleted. "
            + TracklogConnectionCopy.revocation(service: service)
    }
}
