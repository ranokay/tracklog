import DroppyKit
import SwiftUI
import TracklogCore

/// The Apps page id, shared by the root page's link and the host's page
/// request. Stable interface value; never rename it.
let tracklogAppsPageID = "apps"

/// The droplet's root Settings page. Droppy draws the page header, so this
/// starts with the first setting.
struct TracklogSettings: View {
    let droplet: TracklogDroplet
    @ObservedObject var state: TracklogAppState

    @State private var pauseChoice = PauseChoice.notPaused
    @State private var customPauseDate = Date().addingTimeInterval(3600)

    var body: some View {
        DropletSettingsPane {
            DropletSettingsCard {
                DropletToggleRow(
                    title: "Scrobble what I play",
                    subtitle: "Reads the system now-playing feed and saves what you listen to on this Mac.",
                    isOn: droplet.scrobblingBinding,
                )
            }

            DropletSettingsSection {
                settingsSectionHeader("Scrobbling")
            } content: {
                DropletSettingsCard {
                    pauseRow
                    DropletToggleRow(
                        title: "Send now playing",
                        subtitle: "Shows the current track on your services. Scrobbles keep running when this is off.",
                        isOn: droplet.nowPlayingBinding,
                    )
                    DropletSliderRow(
                        title: "Minimum length",
                        value: "\(Int(state.minimumDuration)) seconds",
                        binding: droplet.minimumDurationBinding,
                        range: CaptureSettings.minimumDurationRange,
                        step: 1,
                    )
                }
            }

            DropletSettingsSection {
                settingsSectionHeader("Players")
            } content: {
                DropletSettingsCard {
                    DropletSettingsPageLink(
                        "Apps",
                        subtitle: "Choose which players can scrobble.",
                        page: tracklogAppsPageID,
                    ) {
                        SettingsLinkTile(systemImage: "app.badge.checkmark")
                    }
                }
            }

            DropletSettingsSection {
                settingsSectionHeader("Metadata")
            } content: {
                DropletSettingsCard {
                    DropletSettingsPageLink(
                        "Edits",
                        subtitle: "Fix recurring titles, artists and albums.",
                        page: tracklogEditsPageID,
                    ) {
                        SettingsLinkTile(systemImage: "text.badge.checkmark")
                    }
                    DropletSettingsPageLink(
                        "Blocks",
                        subtitle: "Stop a track, artist, album or album artist from being saved.",
                        page: tracklogBlocksPageID,
                    ) {
                        SettingsLinkTile(systemImage: "hand.raised")
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
                                .font(.system(size: 11))
                                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            mediaSection

            DropletSettingsSection {
                settingsSectionHeader("Status")
            } content: {
                DropletSettingsCard {
                    DropletControlRow(title: "Media feed") {
                        DropletValuePill(text: state.feedAvailable ? "Available" : "Unavailable")
                    }
                    DropletControlRow(title: "Now playing") {
                        DropletValuePill(text: state.nowPlaying?.track.title ?? "Nothing")
                    }
                    DropletControlRow(title: "Listens this session") {
                        DropletValuePill(text: "\(state.listenCount)")
                    }
                    DropletControlRow(title: "Last listen") {
                        DropletValuePill(text: state.lastListen?.processed.title ?? "None")
                    }
                }
            }

            DropletSettingsSection {
                settingsSectionHeader("History")
            } content: {
                DropletSettingsCard {
                    if state.historyFailure != nil {
                        DropletControlRow(title: "History unavailable") {
                            Text("History could not be loaded from this Mac.")
                                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        }
                    } else if state.listens.isEmpty {
                        DropletControlRow(title: "Nothing played yet") {
                            Text("Play something to start your history.")
                                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        }
                    } else {
                        ForEach(state.listens) { listen in
                            DropletControlRow(title: listen.processed.title) {
                                Text(listen.processed.artist)
                                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }

            DropletSettingsSection {
                settingsSectionHeader("Services")
            } content: {
                DropletSettingsCard {
                    DropletSettingsPageLink(
                        "Services",
                        subtitle: state.connections.isEmpty
                            ? "Connect Last.fm, Libre.fm or ListenBrainz."
                            : "\(state.connections.count) connected. Choose the current account.",
                        page: tracklogServicesPageID,
                    ) {
                        SettingsLinkTile(systemImage: "link")
                    }
                }
            }

            DropletSettingsCard {
                DropletControlRow(title: "Queue") {
                    DropletValuePill(text: "Local")
                }
            }
        }
    }

    // MARK: - Pause

    @ViewBuilder
    private var pauseRow: some View {
        if let until = state.pausedUntil {
            DropletControlRow(title: "Pause") {
                HStack(spacing: DroppySpacing.sm) {
                    Text(pauseDescription(until))
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        .monospacedDigit()
                    Button("Resume") {
                        droplet.resumeCapture()
                    }
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
                }
            }
        } else {
            DropletGroupedPickerRow(
                title: "Pause",
                subtitle: "Stops capture and now playing until the pause ends.",
            ) {
                Picker("Pause", selection: $pauseChoice) {
                    Text("Not paused").tag(PauseChoice.notPaused)
                    Text("30 minutes").tag(PauseChoice.thirtyMinutes)
                    Text("1 hour").tag(PauseChoice.oneHour)
                    Text("2 hours").tag(PauseChoice.twoHours)
                    Text("4 hours").tag(PauseChoice.fourHours)
                    Text("Until a time").tag(PauseChoice.untilTime)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .onChange(of: pauseChoice) { _, choice in
                    apply(choice)
                }
            }

            if pauseChoice == .untilTime {
                DropletStackedRow(title: "Resume at") {
                    HStack(spacing: DroppySpacing.sm) {
                        DatePicker(
                            "Resume at",
                            selection: $customPauseDate,
                            in: Date().addingTimeInterval(60)...,
                            displayedComponents: [.date, .hourAndMinute],
                        )
                        .labelsHidden()
                        .datePickerStyle(.compact)

                        Spacer(minLength: DroppySpacing.sm)

                        Button("Pause") {
                            droplet.pauseCapture(until: customPauseDate)
                            pauseChoice = .notPaused
                        }
                        .buttonStyle(DroppyAccentButtonStyle(size: .small))
                    }
                }
            }
        }
    }

    private func apply(_ choice: PauseChoice) {
        switch choice {
        case .notPaused:
            return
        case .thirtyMinutes:
            droplet.pauseCapture(for: 30 * 60)
        case .oneHour:
            droplet.pauseCapture(for: 60 * 60)
        case .twoHours:
            droplet.pauseCapture(for: 2 * 60 * 60)
        case .fourHours:
            droplet.pauseCapture(for: 4 * 60 * 60)
        case .untilTime:
            customPauseDate = max(customPauseDate, Date().addingTimeInterval(60))
        }
        if choice != .untilTime {
            pauseChoice = .notPaused
        }
    }

    private func pauseDescription(_ until: Date) -> String {
        if Calendar.current.isDateInToday(until) {
            "Until \(until.formatted(date: .omitted, time: .shortened))"
        } else {
            until.formatted(date: .abbreviated, time: .shortened)
        }
    }

    // MARK: - Failure

    private func failureLabel(for failure: CaptureFailure) -> String {
        switch failure.stage {
        case .database: "Unavailable"
        case .storage: "Write failed"
        case .history: "Read failed"
        case .edits: "Read failed"
        case .blocks: "Read failed"
        case .connections: "Unavailable"
        }
    }
}

private enum PauseChoice: Hashable {
    case notPaused
    case thirtyMinutes
    case oneHour
    case twoHours
    case fourHours
    case untilTime
}

// MARK: - Apps

/// The Apps page: every player the feed has seen, with the switch that decides
/// whether its plays may be captured.
struct TracklogAppsPage: View {
    let droplet: TracklogDroplet
    @ObservedObject var state: TracklogAppState

    var body: some View {
        DropletSettingsPage {
            DropletSettingsSection {
                VStack(alignment: .leading, spacing: 2) {
                    settingsSectionHeader("Players")
                    Text(
                        "Players appear here after they have played. Music and Spotify start allowed; others stay off until allowed.",
                    )
                    .font(.body)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                }
            } content: {
                DropletSettingsCard {
                    if state.seenApps.isEmpty {
                        DropletControlRow(title: "No players seen yet") {
                            Text("Play something to add a player.")
                                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        }
                    } else {
                        ForEach(state.seenApps) { app in
                            DropletToggleRow(
                                title: droplet.appName(for: app.bundleID),
                                subtitle: app.bundleID,
                                isOn: Binding(
                                    get: { app.isAllowed },
                                    set: { allowed in
                                        droplet.setAppAllowed(app.bundleID, allowed: allowed)
                                    },
                                ),
                            )
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Media

private extension TracklogSettings {
    var mediaSection: some View {
        DropletSettingsSection {
            settingsSectionHeader("Media")
        } content: {
            DropletSettingsCard {
                DropletControlRow(title: "Source") {
                    DropletValuePill(text: state.mediaStatus.source.displayName)
                }
                DropletStackedRow(title: "Media helper") {
                    Text(state.mediaStatus.helperHealth.summary)
                        .font(.system(size: 11))
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
    }
}

// MARK: - Link tile

struct SettingsLinkTile: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous)
                    .fill(AdaptiveColors.overlayAuto(0.08)),
            )
    }
}
