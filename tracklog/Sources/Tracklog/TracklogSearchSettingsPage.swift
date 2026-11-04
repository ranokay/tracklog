import DroppyKit
import SwiftUI
import TracklogCore

/// The Search and play page: the one place the playback URL template is
/// configured. No template is set by default and no value is saved until it
/// validates.
struct TracklogSearchSettingsPage: View {
    let droplet: TracklogDroplet
    @ObservedObject var state: TracklogAppState

    @State private var draft = ""
    @State private var errorMessage: String?
    @State private var didLoad = false

    var body: some View {
        DropletSettingsPage {
            DropletSettingsSection {
                VStack(alignment: .leading, spacing: 2) {
                    settingsSectionHeader("Where a search opens")
                    Text(
                        "Play opens a search URL in your default browser. The URL comes from "
                            + "the template you save here; Tracklog ships with none. "
                            + "For example, https://example.com/search?q={query}.",
                    )
                    .font(.body)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                }
            } content: {
                DropletSettingsCard {
                    DropletControlRow(title: "Playback URL") {
                        DropletValuePill(text: state.playbackTemplate == nil ? "Not set" : "Set")
                    }

                    DropletStackedRow(title: "URL template") {
                        TextField(
                            "Paste a URL template",
                            text: $draft,
                        )
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .accessibilityLabel("Playback URL template")
                        .onSubmit { save() }
                    }

                    DropletControlRow(title: "Save") {
                        HStack(spacing: DroppySpacing.sm) {
                            if state.playbackTemplate != nil {
                                Button("Remove") {
                                    droplet.removePlaybackTemplate()
                                    draft = ""
                                    errorMessage = nil
                                }
                                .buttonStyle(DroppyQuietButtonStyle(size: .small))
                            }
                            Button("Save template") {
                                save()
                            }
                            .buttonStyle(DroppyAccentButtonStyle(size: .small))
                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

            DropletSettingsSection {
                settingsSectionHeader("How the template works")
            } content: {
                DropletSettingsCard {
                    ruleRow(
                        "One placeholder",
                        "Include {query} exactly once. It belongs in the path, query or "
                            + "fragment, never in the host.",
                    )
                    ruleRow(
                        "Web addresses only",
                        "Only http and https are opened. A template with another scheme is refused.",
                    )
                    ruleRow(
                        "Safe encoding",
                        "The query is encoded with RFC 3986 unreserved characters. A space "
                            + "becomes %20, and characters such as & and / stay part of the search text.",
                    )
                    ruleRow(
                        "What the query is",
                        "An artist row searches the artist name, an album row searches the "
                            + "artist and album, and a track or loved row searches the artist and title.",
                    )
                    ruleRow(
                        "Where Play appears",
                        "Palette results, History rows, track history, chart rows and the "
                            + "now-playing menu. With no template, Play opens this page.",
                    )
                }
            }
        }
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            draft = state.playbackTemplate?.rawValue ?? ""
        }
    }

    private func ruleRow(_ title: String, _ detail: String) -> some View {
        DropletStackedRow(title: title) {
            Text(detail)
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func save() {
        do {
            try droplet.savePlaybackTemplate(draft)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
