import DroppyKit
import SwiftUI
import TracklogCore

// MARK: - Data

/// Data holds the live diagnostics and the one portable export. Import is
/// absent, not disabled.
struct TracklogDataPage: View {
    let droplet: TracklogDroplet
    @ObservedObject var state: TracklogAppState

    var body: some View {
        DropletSettingsPage {
            DropletSettingsSection {
                VStack(alignment: .leading, spacing: 2) {
                    settingsSectionHeader("Media")
                    Text("The source that is reading now playing right now.")
                        .font(.body)
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                }
            } content: {
                DropletSettingsCard {
                    DropletControlRow(title: "Source") {
                        DropletValuePill(text: state.mediaStatus.source.displayName)
                    }
                    DropletStackedRow(title: "Media helper") {
                        Text(state.mediaStatus.helperHealth.summary)
                            .font(.caption)
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if state.mediaStatus.automation == .denied {
                        DropletControlRow(title: "Automation") {
                            HStack(spacing: DroppySpacing.sm) {
                                DropletValuePill(text: "Denied")
                                Button("Open System Settings") {
                                    droplet.openAutomationSettings()
                                }
                                .buttonStyle(DroppyQuietButtonStyle(size: .small))
                            }
                        }
                    }
                    DropletControlRow(title: "Diagnostics") {
                        Button("Copy diagnostics") {
                            droplet.copyMediaDiagnostics()
                        }
                        .buttonStyle(DroppyAccentButtonStyle(size: .small))
                    }
                }
            }

            if let failure = state.failure {
                DropletSettingsSection {
                    settingsSectionHeader("Storage")
                } content: {
                    DropletSettingsCard {
                        DropletControlRow(title: failure.message) {
                            DropletValuePill(text: failureLabel(for: failure))
                        }
                        DropletStackedRow(title: "Diagnostics") {
                            Text(failure.diagnostics)
                                .font(.caption)
                                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            DropletSettingsSection {
                VStack(alignment: .leading, spacing: 2) {
                    settingsSectionHeader("Export")
                    Text(
                        "Writes your capture switches, app allowlist, simple edits and blocks. "
                            + "Accounts, credentials, history and the queue stay on this Mac.",
                    )
                    .font(.body)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                }
            } content: {
                DropletSettingsCard {
                    DropletControlRow(title: "Settings and rules") {
                        Button("Export settings…") {
                            droplet.exportSettings()
                        }
                        .buttonStyle(DroppyAccentButtonStyle(size: .small))
                    }
                }
            }
        }
    }

    private func failureLabel(for failure: CaptureFailure) -> String {
        switch failure.stage {
        case .database: "Unavailable"
        case .storage: "Write failed"
        case .history: "Read failed"
        case .edits: "Read failed"
        case .blocks: "Read failed"
        case .connections: "Unavailable"
        case .feedback: "Read failed"
        }
    }
}

// MARK: - About

struct TracklogAboutPage: View {
    let droplet: TracklogDroplet

    var body: some View {
        DropletSettingsPage {
            DropletSettingsCard {
                DropletControlRow(title: "Version") {
                    DropletValuePill(text: droplet.dropletVersion)
                }
                DropletControlRow(title: "Licence") {
                    Button("MIT") {
                        droplet.openURL("https://opensource.org/license/mit") // NOSONAR: public licence link
                    }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
            }

            DropletSettingsSection {
                settingsSectionHeader("Credits")
            } content: {
                DropletSettingsCard {
                    DropletControlRow(title: "Inspired by Pano Scrobbler") {
                        Button("Open") {
                            droplet.openURL("https://github.com/kawaiiDango/pano-scrobbler") // NOSONAR: public attribution link
                        }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                    }
                    DropletControlRow(title: "Built for Droppy with DroppyKit") {
                        Button("Open") {
                            droplet.openURL("https://getdroppy.app") // NOSONAR: public attribution link
                        }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                    }
                    DropletControlRow(title: "Last.fm attribution") {
                        Button("Open Last.fm") {
                            droplet.openURL("https://www.last.fm") // NOSONAR: public attribution link
                        }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                    }
                }
            }
        }
    }
}

// MARK: - Link tile

struct SettingsLinkTile: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.body.weight(.semibold))
            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous)
                    .fill(AdaptiveColors.overlayAuto(0.08)),
            )
    }
}
