import DroppyKit
import SwiftUI
import TracklogCore

/// The Edits page id, shared by the root page's link, the host's page
/// request and the widget's Edit action. Stable interface value; never
/// rename it.
let tracklogEditsPageID = "edits"

/// The Edits page: the simple-edit rules in application order, with add, edit
/// and delete.
struct TracklogEditsPage: View {
    let droplet: TracklogDroplet
    @ObservedObject var state: TracklogAppState

    @State private var draft: EditDraft?
    @State private var errorMessage: String?

    var body: some View {
        DropletSettingsPage {
            if let draft {
                DropletSettingsSection {
                    settingsSectionHeader(draft.isNew ? "New edit" : "Edit")
                } content: {
                    DropletSettingsCard {
                        EditForm(
                            draft: Binding(
                                get: { self.draft ?? draft },
                                set: { self.draft = $0 },
                            ),
                            errorMessage: errorMessage,
                            onSave: { rule in
                                await save(rule)
                            },
                            onCancel: {
                                self.draft = nil
                                errorMessage = nil
                            },
                        )
                    }
                }
            }

            if let errorMessage, draft == nil {
                DropletSettingsSection {
                    settingsSectionHeader("Could not change edits")
                } content: {
                    DropletSettingsCard {
                        Text(errorMessage)
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            DropletSettingsSection {
                VStack(alignment: .leading, spacing: 2) {
                    settingsSectionHeader("Your edits")
                    Text(
                        "Applied most specific first. A Match switch that is off matches anything. "
                            + "Album and album artist can be cleared; track and artist cannot.",
                    )
                    .font(.body)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                }
            } content: {
                DropletSettingsCard {
                    if state.simpleEdits.isEmpty {
                        DropletControlRow(title: "No edits yet") {
                            Text("Add one to correct a recurring value.")
                                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        }
                    } else {
                        ForEach(state.simpleEdits) { rule in
                            ruleRow(rule)
                        }
                        .droppyFlatGlassControls()
                    }

                    if draft == nil {
                        DropletControlRow(title: "New edit") {
                            Button("Add") {
                                draft = EditDraft()
                                errorMessage = nil
                            }
                            .buttonStyle(DroppyQuietButtonStyle(size: .small))
                        }
                    }
                }
            }
        }
        .onAppear { applyEditPrefill() }
        .onChange(of: state.editPrefill) { _, _ in applyEditPrefill() }
    }

    /// The widget and now-playing strip's Edit action opens this page with a
    /// new draft made from the current listen's fields as the metadata
    /// pipeline matches them.
    private func applyEditPrefill() {
        guard let prefill = state.takeEditPrefill() else { return }
        draft = EditDraft(prefill: prefill.match)
        errorMessage = nil
    }

    // MARK: - Rows

    private func ruleRow(_ rule: SimpleEditRule) -> some View {
        DropletStackedRow(title: ruleTitle(rule)) {
            VStack(alignment: .leading, spacing: DroppySpacing.xs) {
                summary("Match", fields: matchFields(rule))
                summary("Replace", fields: replacementFields(rule))
                HStack(spacing: DroppySpacing.sm) {
                    Spacer(minLength: 0)
                    Button("Edit") {
                        draft = EditDraft(rule: rule)
                        errorMessage = nil
                    }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
                    Button("Delete") {
                        delete(rule)
                    }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small, destructive: true))
                }
            }
        }
    }

    private func summary(_ label: String, fields: [(label: String, value: String)]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DroppySpacing.sm) {
            Text(label)
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            Text(fields.map { "\($0.label) “\($0.value)”" }.joined(separator: ", "))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }

    private func ruleTitle(_ rule: SimpleEditRule) -> String {
        let names = matchFields(rule).map(\.label)
        return names.isEmpty ? "Edit" : names.joined(separator: " + ")
    }

    private func matchFields(_ rule: SimpleEditRule) -> [(label: String, value: String)] {
        [("Track", rule.match.track), ("Artist", rule.match.artist),
         ("Album", rule.match.album), ("Album artist", rule.match.albumArtist)]
            .compactMap { label, value in value.map { (label, $0) } }
    }

    private func replacementFields(_ rule: SimpleEditRule) -> [(label: String, value: String)] {
        [("Track", rule.replacement.track), ("Artist", rule.replacement.artist),
         ("Album", rule.replacement.album), ("Album artist", rule.replacement.albumArtist)]
            .compactMap { label, value in value.map { (label, $0.isEmpty ? "Clear" : $0) } }
    }

    // MARK: - Actions

    private func save(_ rule: SimpleEditRule) async {
        do {
            try await droplet.saveSimpleEdit(rule)
            draft = nil
            errorMessage = nil
        } catch let error as SimpleEditRuleValidationError {
            errorMessage = validationHint(for: error)
        } catch {
            errorMessage = "The edit could not be saved."
        }
    }

    private func delete(_ rule: SimpleEditRule) {
        guard let id = rule.id else { return }
        Task {
            do {
                try await droplet.deleteSimpleEdit(id: id)
                if draft?.id == id {
                    draft = nil
                }
                errorMessage = nil
            } catch {
                errorMessage = "The edit could not be deleted."
            }
        }
    }
}

// MARK: - Form

private struct EditForm: View {
    @Binding var draft: EditDraft
    let errorMessage: String?
    let onSave: (SimpleEditRule) async -> Void
    let onCancel: () -> Void

    @State private var isSaving = false

    var body: some View {
        FieldEditor(title: "Track", field: $draft.track)
        FieldEditor(title: "Artist", field: $draft.artist)
        FieldEditor(title: "Album", field: $draft.album)
        FieldEditor(title: "Album artist", field: $draft.albumArtist)

        if let message = errorMessage ?? draft.validationMessage {
            DropletStackedRow(title: "Not saved yet") {
                Text(message)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HStack(spacing: DroppySpacing.sm) {
            Spacer(minLength: 0)
            Button("Cancel") {
                onCancel()
            }
            .buttonStyle(DroppyQuietButtonStyle(size: .small))

            Button("Save") {
                Task {
                    isSaving = true
                    await onSave(draft.rule)
                    isSaving = false
                }
            }
            .buttonStyle(DroppyAccentButtonStyle(size: .small))
            .disabled(isSaving)
            .disabled(draft.validationError != nil)
            .keyboardShortcut(.defaultAction)
        }
    }
}

private struct FieldEditor: View {
    let title: String
    @Binding var field: EditFieldDraft

    var body: some View {
        // A switch and its field are one control group; the SDK's toggle rows
        // hold a single control each.
        DropletStackedRow(title: title) {
            VStack(alignment: .leading, spacing: DroppySpacing.xs) {
                HStack(spacing: DroppySpacing.sm) {
                    Toggle("Match", isOn: $field.matchEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .fixedSize()
                        .accessibilityLabel("Match \(title.lowercased())")
                    TextField("Value to match", text: $field.match)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!field.matchEnabled)
                }
                HStack(spacing: DroppySpacing.sm) {
                    Toggle("Replace", isOn: $field.replacementEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .fixedSize()
                        .accessibilityLabel("Replace \(title.lowercased())")
                    TextField("Replacement", text: $field.replacement)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!field.replacementEnabled)
                }
            }
        }
    }
}

// MARK: - Draft

private struct EditDraft {
    var id: Int64?
    var track = EditFieldDraft()
    var artist = EditFieldDraft()
    var album = EditFieldDraft()
    var albumArtist = EditFieldDraft()

    var isNew: Bool {
        id == nil
    }

    init() {}

    init(prefill: SimpleEditRule.Match) {
        track = EditFieldDraft(match: prefill.track, replacement: nil)
        artist = EditFieldDraft(match: prefill.artist, replacement: nil)
        album = EditFieldDraft(match: prefill.album, replacement: nil)
        albumArtist = EditFieldDraft(match: prefill.albumArtist, replacement: nil)
    }

    init(rule: SimpleEditRule) {
        id = rule.id
        track = EditFieldDraft(match: rule.match.track, replacement: rule.replacement.track)
        artist = EditFieldDraft(match: rule.match.artist, replacement: rule.replacement.artist)
        album = EditFieldDraft(match: rule.match.album, replacement: rule.replacement.album)
        albumArtist = EditFieldDraft(
            match: rule.match.albumArtist,
            replacement: rule.replacement.albumArtist,
        )
    }

    var rule: SimpleEditRule {
        SimpleEditRule(
            id: id,
            match: SimpleEditRule.Match(
                track: track.matchValue,
                artist: artist.matchValue,
                album: album.matchValue,
                albumArtist: albumArtist.matchValue,
            ),
            replacement: SimpleEditRule.Replacement(
                track: track.replacementValue,
                artist: artist.replacementValue,
                album: album.replacementValue,
                albumArtist: albumArtist.replacementValue,
            ),
        )
    }

    var validationError: SimpleEditRuleValidationError? {
        rule.validationError
    }

    var validationMessage: String? {
        validationHint(for: validationError)
    }
}

private struct EditFieldDraft {
    var matchEnabled = false
    var match = ""
    var replacementEnabled = false
    var replacement = ""

    init() {}

    init(match: String?, replacement: String?) {
        matchEnabled = match != nil
        self.match = match ?? ""
        replacementEnabled = replacement != nil
        self.replacement = replacement ?? ""
    }

    var matchValue: String? {
        matchEnabled ? trimmed(match) : nil
    }

    var replacementValue: String? {
        replacementEnabled ? trimmed(replacement) : nil
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private func validationHint(for error: SimpleEditRuleValidationError?) -> String? {
    switch error {
    case .none: nil
    case .noMatchFields: "Turn on at least one match field."
    case .noReplacements: "Turn on at least one replacement."
    case .cannotClearTrack: "Track cannot be cleared. Turn off Replace or enter a title."
    case .cannotClearArtist: "Artist cannot be cleared. Turn off Replace or enter an artist."
    }
}
