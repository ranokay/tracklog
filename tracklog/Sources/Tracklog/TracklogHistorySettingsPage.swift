import DroppyKit
import SwiftUI
import TracklogCore

let tracklogHistoryPageID = "history"

/// History's only typed surface. The takeover stays browse-only, so the date
/// and time are chosen here and Show in History presents the corresponding
/// position.
struct TracklogHistorySettingsPage: View {
    let droplet: TracklogDroplet
    @ObservedObject var state: TracklogAppState

    @State private var jumpDate = Date()

    var body: some View {
        DropletSettingsPage {
            DropletSettingsSection {
                VStack(alignment: .leading, spacing: 2) {
                    settingsSectionHeader("Local history")
                    Text(
                        "Choose a date and time. Show in History opens the takeover at the first listen "
                            + "from that moment; the takeover itself never asks for typing.",
                    )
                    .font(.body)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } content: {
                DropletSettingsCard {
                    DropletStackedRow(title: "Date and time") {
                        DatePicker(
                            "Date and time",
                            selection: $jumpDate,
                            displayedComponents: [.date, .hourAndMinute],
                        )
                        .labelsHidden()
                        .datePickerStyle(.compact)
                    }
                    DropletStackedRow(title: "History actions") {
                        HStack(spacing: DroppySpacing.sm) {
                            Button("Show in History") {
                                droplet.finishHistorySettingsPage()
                                droplet.showHistory(at: jumpDate)
                            }
                            .buttonStyle(DroppyAccentButtonStyle(size: .small))
                            .accessibilityHint(Text("Opens History at this date and time."))
                            Spacer(minLength: DroppySpacing.sm)
                        }
                    }
                    Text("Local history is never scoped to the current connection.")
                        .font(.caption)
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
