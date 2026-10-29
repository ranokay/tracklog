import DroppyKit
import SwiftUI
import TracklogCore

/// The Libre.fm block of the Add service page: the linked account, or a server
/// address and the browser sign-in that follows it.
struct TracklogLibreFMServiceSection: View {
    let droplet: TracklogDroplet
    @ObservedObject var state: TracklogAppState

    @State private var root = ServiceEndpoint.libreFM.description
    @State private var rootError: String?

    private var connection: Connection? {
        state.connection(kind: .libreFM)
    }

    private var trimmedRoot: String {
        root.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        DropletSettingsSection {
            VStack(alignment: .leading, spacing: 2) {
                settingsSectionHeader("Libre.fm")
                Text(intro)
                    .font(.body)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            }
        } content: {
            DropletSettingsCard {
                if let connection {
                    DropletControlRow(title: "Account") {
                        DropletValuePill(text: connection.identity)
                    }
                    DropletStackedRow(title: "Server") {
                        Text(connection.endpoint.description)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    DropletControlRow(title: "Status") {
                        DropletValuePill(text: connection.status.displayName)
                    }
                }
                if !droplet.canLinkLibreFM {
                    DropletStackedRow(title: "Libre.fm sign-in is unavailable in the harness.") {
                        EmptyView()
                    }
                } else {
                    serverForm
                }
            }
        }
    }

    private var intro: String {
        if connection != nil {
            return "This Mac sends every listen to the Libre.fm account above. "
                + "Each server keeps its own account, so a second GNU FM server can be added below."
        }
        return "Sign in to Libre.fm or to a GNU FM server you run. "
            + "Enter the server's HTTPS address first; Tracklog adds the API and sign-in paths."
    }

    private var serverForm: some View {
        DropletStackedRow(title: connection == nil ? "Server" : "Add another server") {
            VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                TextField(ServiceEndpoint.libreFM.description, text: $root)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Libre.fm server address")
                Text("A GNU FM server's HTTPS address. HTTP addresses are refused.")
                    .font(.callout)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                if let rootError {
                    Text(rootError)
                        .font(.callout)
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: DroppySpacing.sm) {
                    Spacer(minLength: 0)
                    Button("Sign in with Libre.fm") {
                        startLink()
                    }
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
                    .disabled(trimmedRoot.isEmpty)
                }
            }
        }
    }

    private func startLink() {
        guard let endpoint = ServiceEndpoint(normalizing: trimmedRoot) else {
            rootError = "Enter the server's HTTPS address, such as https://libre.fm. "
                + "HTTP addresses are refused."
            return
        }
        rootError = nil
        droplet.openLibreFMLink(endpoint: endpoint)
    }
}
