import DroppyKit
import SwiftUI
import TracklogCore

let tracklogChartsPageID = "charts"

/// Charts' only typed surface. The dates choose what this Mac's local history
/// shows; saving keeps this page open and Open Charts shows the saved range.
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
                        "Choose the dates to include from this Mac's listening history. "
                            + "Saving keeps this page open. Open Charts shows the saved range; "
                            + "dates you have not saved are not used there.",
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
                        .disabled(isSaving)
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
                        .disabled(isSaving)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Saved range: \(savedRangeText)")
                            .font(.caption)
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        if hasDateChanges {
                            Text("Unsaved changes. Open Charts uses the saved range.")
                                .font(.caption)
                                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, DroppySpacing.xs)

                    DropletStackedRow(title: "Range actions") {
                        HStack(spacing: DroppySpacing.sm) {
                            if isSaving {
                                ProgressView()
                                    .controlSize(.small)
                                    .accessibilityLabel(Text("Saving range"))
                            }
                            Button("Save range") {
                                save()
                            }
                            .buttonStyle(DroppyAccentButtonStyle(size: .small))
                            .disabled(isSaving)
                            Button("Open Charts") {
                                Task { await droplet.openSavedCharts() }
                            }
                            .buttonStyle(DroppyQuietButtonStyle(size: .small))
                            .disabled(isSaving)
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
        .onChange(of: startDate) {
            errorText = ""
            savedText = ""
        }
        .onChange(of: endDate) {
            errorText = ""
            savedText = ""
        }
    }

    private var savedRangeText: String {
        let calendar = ChartCalendar.current
        let start = state.chartState.selection.customStart.formatted(in: calendar)
        let end = state.chartState.selection.customEnd.formatted(in: calendar)
        return "\(start) – \(end)"
    }

    private var hasDateChanges: Bool {
        let calendar = ChartCalendar.current
        return ChartDate(startDate, calendar: calendar) != state.chartState.selection.customStart
            || ChartDate(endDate, calendar: calendar) != state.chartState.selection.customEnd
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
                savedText = "Saved \(start.formatted(in: calendar)) to \(end.formatted(in: calendar)). Open Charts shows this range."
            } catch {
                isSaving = false
                errorText = (error as? LocalizedError)?.errorDescription ?? "The range could not be saved."
            }
        }
    }
}
