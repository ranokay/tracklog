import DroppyKit
import SwiftUI
import TracklogCore

/// The Edits page id, shared by the root page's link, the host's page
/// request and the widget's future Edit action. Stable interface value; never
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
                    Text("Applied most specific first. Album and album artist can be cleared; track and artist cannot.")
                        .font(.body)
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                }
            } content: {
                DropletSettingsCard {
                    if state.simpleEdits.isEmpty {
                        DropletControlRow(title: "No edits yet") {
                            Text("Add one to fix a recurring tag.")
                                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        }
                    } else {
                        ForEach(state.simpleEdits) { rule in
                            ruleRow(rule)
                        }
                    }

                    if draft == nil {
                        DropletControlRow(title: "Fix another tag") {
                            Button("Add edit") {
                                draft = EditDraft()
                                errorMessage = nil
                            }
                            .buttonStyle(DroppyQuietButtonStyle(size: .small))
                        }
                    }
                }
            }
        }
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

    private func summary(_ label: String, fields: [(String, String)]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DroppySpacing.sm) {
            Text(label)
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            Text(fields.map { "\($0.0) “\($0.1)”" }.joined(separator: ", "))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }

    private func ruleTitle(_ rule: SimpleEditRule) -> String {
        let names = matchFields(rule).map(\.0)
        return names.isEmpty ? "Edit" : names.joined(separator: " + ")
    }

    private func matchFields(_ rule: SimpleEditRule) -> [(String, String)] {
        [("Track", rule.match.track), ("Artist", rule.match.artist),
         ("Album", rule.match.album), ("Album artist", rule.match.albumArtist)]
            .compactMap { name, value in value.map { (name, $0) } }
    }

    private func replacementFields(_ rule: SimpleEditRule) -> [(String, String)] {
        [("Track", rule.replacement.track), ("Artist", rule.replacement.artist),
         ("Album", rule.replacement.album), ("Album artist", rule.replacement.albumArtist)]
            .compactMap { name, value in value.map { (name, $0.isEmpty ? "Clear" : $0) } }
    }

    // MARK: - Actions

    private func save(_ rule: SimpleEditRule) async {
        do {
            try await droplet.saveSimpleEdit(rule)
            draft = nil
            errorMessage = nil
        } catch let error as SimpleEditRuleValidationError {
            errorMessage = validationMessage(for: error)
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

    private func validationMessage(for error: SimpleEditRuleValidationError) -> String {
        switch error {
        case .noMatchFields:
            "Turn on at least one match field."
        case .noReplacements:
            "Turn on at least one replacement."
        case .cannotClearTrack:
            "Track cannot be cleared. Turn off Replace or enter a title."
        case .cannotClearArtist:
            "Artist cannot be cleared. Turn off Replace or enter an artist."
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
        DropletStackedRow(title: title) {
            VStack(alignment: .leading, spacing: DroppySpacing.xs) {
                HStack(spacing: DroppySpacing.sm) {
                    Toggle("Match", isOn: $field.matchEnabled)
                        .toggleStyle(.switch)
                        .fixedSize()
                        .accessibilityLabel("Match \(title.lowercased())")
                    TextField("Value to match", text: $field.match)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!field.matchEnabled)
                }
                HStack(spacing: DroppySpacing.sm) {
                    Toggle("Replace", isOn: $field.replacementEnabled)
                        .toggleStyle(.switch)
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

    init(rule: SimpleEditRule) {
        id = rule.id
        track = EditFieldDraft(
            matchEnabled: rule.match.track != nil,
            match: rule.match.track ?? "",
            replacementEnabled: rule.replacement.track != nil,
            replacement: rule.replacement.track ?? "",
        )
        artist = EditFieldDraft(
            matchEnabled: rule.match.artist != nil,
            match: rule.match.artist ?? "",
            replacementEnabled: rule.replacement.artist != nil,
            replacement: rule.replacement.artist ?? "",
        )
        album = EditFieldDraft(
            matchEnabled: rule.match.album != nil,
            match: rule.match.album ?? "",
            replacementEnabled: rule.replacement.album != nil,
            replacement: rule.replacement.album ?? "",
        )
        albumArtist = EditFieldDraft(
            matchEnabled: rule.match.albumArtist != nil,
            match: rule.match.albumArtist ?? "",
            replacementEnabled: rule.replacement.albumArtist != nil,
            replacement: rule.replacement.albumArtist ?? "",
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
        switch validationError {
        case .none: nil
        case .noMatchFields: "Turn on at least one match field."
        case .noReplacements: "Turn on at least one replacement."
        case .cannotClearTrack: "Track cannot be cleared. Turn off Replace or enter a title."
        case .cannotClearArtist: "Artist cannot be cleared. Turn off Replace or enter an artist."
        }
    }
}

private struct EditFieldDraft {
    var matchEnabled = false
    var match = ""
    var replacementEnabled = false
    var replacement = ""

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
