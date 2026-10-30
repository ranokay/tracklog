import DroppyKit
import SwiftUI
import TracklogCore

// MARK: - Add service

/// Add service: the launch services — Last.fm and Libre.fm through the
/// browser, ListenBrainz through a token.
struct TracklogAddServicePage: View {
    let droplet: TracklogDroplet
    @ObservedObject var state: TracklogAppState

    @State private var token = ""
    @State private var errorMessage: String?
    @State private var isLinking = false

    private var trimmedToken: String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One connection per endpoint, so a second ListenBrainz account is only
    /// reachable by signing the existing connection in again.
    private var listenBrainzIdentity: String? {
        state.connection(kind: .listenBrainz)?.identity
    }

    private var lastFMConnection: Connection? {
        state.connection(kind: .lastFM)
    }

    var body: some View {
        DropletSettingsPage {
            DropletSettingsSection {
                VStack(alignment: .leading, spacing: 2) {
                    settingsSectionHeader("Add a service")
                    Text(
                        "Tracklog will send every listen to each service you connect and enable.",
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
                    settingsSectionHeader("Last.fm")
                    Text(lastFMIntro)
                        .font(.body)
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                }
            } content: {
                DropletSettingsCard {
                    if let lastFMConnection {
                        DropletControlRow(title: "Account") {
                            DropletValuePill(text: lastFMConnection.identity)
                        }
                        DropletControlRow(title: "Status") {
                            DropletValuePill(text: lastFMConnection.status.displayName)
                        }
                        DropletStackedRow(title: "Session") {
                            Text(sessionText(for: lastFMConnection))
                                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if state.lastFMNeedsAppCredentialRemedy {
                        DropletStackedRow(title: "App credentials") {
                            Text(lastFMAppCredentialRemedyDetail)
                                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        TracklogSettingsPageLink(droplet: droplet,
                                                 lastFMAppCredentialLinkTitle,
                                                 subtitle: "Save your own API key and shared secret, then sign in.",
                                                 page: tracklogLastFMAppCredentialsPageID) {
                            SettingsLinkTile(systemImage: "key")
                        }
                    } else if lastFMConnection == nil, droplet.lastFMLink != nil {
                        TracklogSettingsPageLink(droplet: droplet,
                                                 "Sign in with Last.fm",
                                                 subtitle: "Opens Last.fm in your browser and waits for you to authorize Tracklog.",
                                                 page: tracklogLastFMLinkPageID) {
                            SettingsLinkTile(systemImage: "music.note")
                        }
                    } else if lastFMConnection == nil {
                        DropletStackedRow(title: "Last.fm sign-in is unavailable in the harness.") {
                            EmptyView()
                        }
                    }
                }
            }

            TracklogLibreFMServiceSection(droplet: droplet, state: state)

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

            if let errorMessage {
                DropletSettingsSection {
                    settingsSectionHeader("Needs attention")
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

    private func sessionText(for connection: Connection) -> String {
        if connection.authState == .needsSignIn {
            return "Last.fm needs this connection to sign in again. "
                + "Its pending scrobbles are held until it does."
        }
        return "The session key is in the Keychain. "
            + "The connection is listed on the Services page."
    }

    private var lastFMIntro: String {
        if state.lastFMNeedsAppCredentialRemedy {
            return "Tracklog cannot sign in to Last.fm until its app credentials work. "
                + "Save your own API key and shared secret first."
        }
        return "Sign in through your browser. Tracklog never sees your Last.fm password, "
            + "and the session key is kept in the Keychain."
    }

    private var lastFMAppCredentialRemedyDetail: String {
        if let problem = state.lastFMAppCredentialProblem {
            return problem.detail
        }
        return "The built-in Last.fm app credentials are missing. "
            + "Save your own API key and shared secret before signing in."
    }

    private var lastFMAppCredentialLinkTitle: String {
        state.lastFMOverridePresent
            ? "Fix Last.fm app credentials"
            : "Add Last.fm app credentials"
    }

    private func status(for kind: ServiceKind) -> String {
        switch kind {
        case .listenBrainz:
            listenBrainzIdentity == nil ? "Not connected" : "Connected"
        case .lastFM:
            if let lastFMConnection {
                lastFMConnection.status.displayName
            } else if state.lastFMNeedsAppCredentialRemedy {
                "Needs app credentials"
            } else {
                "Not connected"
            }
        case .libreFM:
            state.connection(kind: .libreFM)?.status.displayName ?? "Not connected"
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
