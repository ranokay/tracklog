import DroppyKit
import SwiftUI
import TracklogCore

/// Stable interface values. The root is a page id as well as the pane the host
/// mounts, and every nested page keeps its id across releases.
let tracklogRootPageID = "scrobbling"
let tracklogAppsPageID = "apps"
let tracklogDataPageID = "data"
let tracklogAboutPageID = "about"

/// The droplet's root Settings page. Droppy draws the page header, so this
/// starts with the first setting and never repeats the droplet's name.
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
                .id(tracklogRootPageID)
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
                    TracklogSettingsPageLink(droplet: droplet,
                                             "Apps",
                                             subtitle: "Choose which players can scrobble.",
                                             page: tracklogAppsPageID) {
                        SettingsLinkTile(systemImage: "app.badge.checkmark")
                    }
                    .id(tracklogAppsPageID)
                }
            }

            DropletSettingsSection {
                settingsSectionHeader("Settings")
            } content: {
                DropletSettingsCard {
                    TracklogSettingsPageLink(droplet: droplet,
                                             "Services",
                                             subtitle: state.connections.isEmpty
                                                 ? "Connect Last.fm, Libre.fm or ListenBrainz."
                                                 : "\(state.connections.count) connected. Choose the current account.",
                                             page: tracklogServicesPageID) {
                        SettingsLinkTile(systemImage: "link")
                    }
                    .id(tracklogServicesPageID)
                    TracklogSettingsPageLink(droplet: droplet,
                                             "Edits",
                                             subtitle: "Fix recurring titles, artists and albums.",
                                             page: tracklogEditsPageID) {
                        SettingsLinkTile(systemImage: "text.badge.checkmark")
                    }
                    .id(tracklogEditsPageID)
                    TracklogSettingsPageLink(droplet: droplet,
                                             "Blocks",
                                             subtitle: "Stop a track, artist, album or album artist from being saved.",
                                             page: tracklogBlocksPageID) {
                        SettingsLinkTile(systemImage: "hand.raised")
                    }
                    .id(tracklogBlocksPageID)
                    TracklogSettingsPageLink(droplet: droplet,
                                             "Charts",
                                             subtitle: "Choose the local Custom date range.",
                                             page: tracklogChartsPageID) {
                        SettingsLinkTile(systemImage: "chart.bar.xaxis")
                    }
                    .id(tracklogChartsPageID)
                    TracklogSettingsPageLink(droplet: droplet,
                                             "Data",
                                             subtitle: "Media diagnostics and your portable settings export.",
                                             page: tracklogDataPageID) {
                        SettingsLinkTile(systemImage: "externaldrive")
                    }
                    .id(tracklogDataPageID)
                    TracklogSettingsPageLink(droplet: droplet,
                                             "About",
                                             subtitle: "Version, licence and credits.",
                                             page: tracklogAboutPageID) {
                        SettingsLinkTile(systemImage: "info.circle")
                    }
                    .id(tracklogAboutPageID)
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
