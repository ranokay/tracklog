import DroppyKit
import SwiftUI
import TracklogCore

let tracklogChartsPageID = "charts"

/// Charts' only typed surface. Custom dates are chosen here, the takeover is
/// already dismissed, and Save never opens the takeover by itself.
struct TracklogChartsSettingsPage: View {
    let droplet: TracklogDroplet
    @ObservedObject var state: TracklogAppState

    @State private var startDate: Date
    @State private var endDate: Date
    @State private var errorText = ""
    @State private var savedText = ""
    @State private var isSaving = false

    init(droplet: TracklogDroplet, state: TracklogAppState) {
        self.droplet = droplet
        self.state = state
        let calendar = ChartCalendar.current
        let selection = state.chartState.selection
        _startDate = State(initialValue: selection.customStart.startDate(in: calendar) ?? Date())
        _endDate = State(initialValue: selection.customEnd.startDate(in: calendar) ?? Date())
    }

    var body: some View {
        DropletSettingsPage {
            DropletSettingsSection {
                VStack(alignment: .leading, spacing: 2) {
                    settingsSectionHeader("Local Custom range")
                    Text(
                        "Dates apply to this Mac's local history in the current time zone. "
                            + "The takeover closes while you type, and saving only stores the range. "
                            + "Open Charts returns to it explicitly.",
                    )
                    .font(.body)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                }
            } content: {
                DropletSettingsCard {
                    DropletStackedRow(title: "Start date") {
                        DatePicker(
                            "Start date",
                            selection: $startDate,
                            in: ...endDate,
                            displayedComponents: [.date],
                        )
                        .labelsHidden()
                        .datePickerStyle(.compact)
                    }
                    DropletStackedRow(title: "End date") {
                        DatePicker(
                            "End date",
                            selection: $endDate,
                            in: startDate...,
                            displayedComponents: [.date],
                        )
                        .labelsHidden()
                        .datePickerStyle(.compact)
                    }
                    DropletStackedRow(title: "Save and return") {
                        HStack(spacing: DroppySpacing.sm) {
                            if isSaving {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Button("Save range") {
                                save()
                            }
                            .buttonStyle(DroppyAccentButtonStyle(size: .small))
                            .disabled(isSaving)
                            Button("Open Charts") {
                                droplet.presentCharts()
                            }
                            .buttonStyle(DroppyQuietButtonStyle(size: .small))
                        }
                    }
                    if !errorText.isEmpty {
                        Text(errorText)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(Text(errorText))
                    }
                    if !savedText.isEmpty {
                        Text(savedText)
                            .font(.caption)
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(Text(savedText))
                    }
                }
            }
        }
    }

    private func save() {
        let calendar = ChartCalendar.current
        let start = ChartDate(startDate, calendar: calendar)
        let end = ChartDate(endDate, calendar: calendar)
        guard end >= start else {
            errorText = ChartValidationError.reversedCustomRange.localizedDescription
            savedText = ""
            return
        }
        errorText = ""
        savedText = ""
        isSaving = true
        Task {
            do {
                try await droplet.saveChartCustomRange(start: start, end: end)
                isSaving = false
                savedText = "Saved \(start.formatted(in: calendar)) to \(end.formatted(in: calendar)). Open Charts to browse it."
            } catch {
                isSaving = false
                errorText = (error as? LocalizedError)?.errorDescription ?? "The range could not be saved."
            }
        }
    }
}
