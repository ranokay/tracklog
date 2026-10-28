import DroppyKit
import SwiftUI
import TracklogCore

// MARK: - One connection

/// One connection's page: identity, endpoint, enabled switch, current cursor,
/// and the account actions.
struct TracklogConnectionPage: View {
    let droplet: TracklogDroplet
    @ObservedObject var state: TracklogAppState
    let connectionID: Int64

    @State private var actionError: String?

    private var connection: Connection? {
        state.connection(id: connectionID)
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
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
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

                DropletSettingsSection {
                    VStack(alignment: .leading, spacing: 2) {
                        settingsSectionHeader("Account")
                        Text(
                            "Sign in again and Unlink arrive in a later update. "
                                + "Unlinking will never delete local history.",
                        )
                        .font(.body)
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    }
                } content: {
                    DropletSettingsCard {
                        DropletControlRow(title: "Sign in again") {
                            DropletValuePill(text: "Later update")
                        }
                        DropletControlRow(title: "Unlink") {
                            DropletValuePill(text: "Later update")
                        }
                    }
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
                            EmptyView()
                        }
                    }
                }
            }
        }
    }

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
}
