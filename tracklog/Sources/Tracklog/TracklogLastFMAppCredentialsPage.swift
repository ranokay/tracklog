import DroppyKit
import SwiftUI
import TracklogCore

/// The nested Last.fm application-credentials page under Services.
///
/// It reports whether user-supplied credentials exist in the Keychain, never
/// shows a saved value back, and saves a candidate only after Last.fm accepts
/// it. Saving or removing a pair signs every Last.fm connection out; the page
/// says so before the control is used.
struct TracklogLastFMAppCredentialsPage: View {
    let droplet: TracklogDroplet
    @ObservedObject var state: TracklogAppState

    @State private var apiKey = ""
    @State private var sharedSecret = ""
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var isRemoving = false

    private var trimmedKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedSecret: String {
        sharedSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isWorking: Bool {
        isSaving || isRemoving
    }

    private var lastFMConnectionCount: Int {
        state.connections.filter { $0.kind == .lastFM }.count
    }

    private var overrideSavedText: String {
        "Enter both values again to replace it, or remove it. Removing leaves Last.fm "
            + "without app credentials until you save another pair."
    }

    var body: some View {
        DropletSettingsPage {
            DropletSettingsSection {
                VStack(alignment: .leading, spacing: 2) {
                    settingsSectionHeader("Current credentials")
                    Text(
                        "Register a Last.fm API application and save its API key and shared "
                            + "secret here before signing in.",
                    )
                    .font(.body)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                }
            } content: {
                DropletSettingsCard {
                    DropletControlRow(title: "Your credentials") {
                        DropletValuePill(
                            text: state.lastFMOverridePresent ? "Saved in the Keychain" : "Not set",
                        )
                    }
                    if let problem = state.lastFMAppCredentialProblem {
                        DropletStackedRow(title: problem.title) {
                            Text(problem.detail)
                                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            accountSection
            warningSection

            DropletSettingsSection {
                settingsSectionHeader("Done")
            } content: {
                DropletSettingsCard {
                    DropletControlRow(title: "Services") {
                        Button("Back to services") {
                            droplet.goBackInSettings()
                        }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                    }
                }
            }
        }
    }

    private var accountSection: some View {
        DropletSettingsSection {
            VStack(alignment: .leading, spacing: 2) {
                settingsSectionHeader("Your API key and shared secret")
                Text(
                    "Both values come from your Last.fm API account page. Tracklog checks them "
                        + "with Last.fm before saving. They are kept in the Keychain, never shown "
                        + "again, and are never written to the database, a log or an export.",
                )
                .font(.body)
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            }
        } content: {
            DropletSettingsCard {
                if state.lastFMOverridePresent {
                    DropletStackedRow(title: "Credentials saved") {
                        Text(overrideSavedText)
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                DropletStackedRow(title: "API key") {
                    TextField("Paste your Last.fm API key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Last.fm API key")
                        .disabled(isWorking)
                }

                DropletStackedRow(title: "Shared secret") {
                    SecureField("Paste your Last.fm shared secret", text: $sharedSecret)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Last.fm shared secret")
                        .disabled(isWorking)
                }

                DropletControlRow(title: "Save") {
                    HStack(spacing: DroppySpacing.sm) {
                        if state.lastFMOverridePresent {
                            Button("Remove credentials") {
                                remove()
                            }
                            .buttonStyle(DroppyQuietButtonStyle(size: .small))
                            .disabled(isWorking)
                        }
                        Button(isSaving ? "Checking…" : "Save credentials") {
                            save()
                        }
                        .buttonStyle(DroppyAccentButtonStyle(size: .small))
                        .disabled(isWorking || trimmedKey.isEmpty || trimmedSecret.isEmpty)
                        .keyboardShortcut(.defaultAction)
                    }
                }

                if let errorMessage {
                    DropletStackedRow(title: "Needs attention") {
                        Text(errorMessage)
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var warningSection: some View {
        DropletSettingsSection {
            settingsSectionHeader("Reconnect after a change")
        } content: {
            DropletSettingsCard {
                Text(warningText)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var warningText: String {
        if lastFMConnectionCount == 1 {
            return "Changing these credentials invalidates every Last.fm session key. "
                + "The Last.fm connection must sign in again; its pending scrobbles stay "
                + "queued until it does."
        }
        return "Changing these credentials invalidates every Last.fm session key. "
            + "Every Last.fm connection must sign in again; pending scrobbles stay queued "
            + "until each one does."
    }

    private func save() {
        guard !isWorking, !trimmedKey.isEmpty, !trimmedSecret.isEmpty else { return }
        isSaving = true
        errorMessage = nil
        let key = trimmedKey
        let secret = trimmedSecret
        Task {
            do {
                try await droplet.saveLastFMAppCredentialOverride(
                    apiKey: key,
                    sharedSecret: secret,
                )
                apiKey = ""
                sharedSecret = ""
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }

    private func remove() {
        guard !isWorking else { return }
        isRemoving = true
        errorMessage = nil
        Task {
            do {
                try await droplet.removeLastFMAppCredentialOverride()
            } catch {
                errorMessage = error.localizedDescription
            }
            isRemoving = false
        }
    }
}
