import DroppyKit
import SwiftUI
import TracklogCore

/// The Blocks page id, shared by the root page's link and the host's page
/// request. Stable interface value; never rename it.
let tracklogBlocksPageID = "blocks"

/// The Blocks page: the saved blocks in evaluation order, with add, edit and
/// delete. A blank field is a wildcard and an all-blank block is refused.
struct TracklogBlocksPage: View {
    let droplet: TracklogDroplet
    @ObservedObject var state: TracklogAppState

    @State private var draft: BlockDraft?
    @State private var errorMessage: String?

    var body: some View {
        DropletSettingsPage {
            if let draft {
                DropletSettingsSection {
                    settingsSectionHeader(draft.isNew ? "New block" : "Edit block")
                } content: {
                    DropletSettingsCard {
                        BlockForm(
                            draft: Binding(
                                get: { self.draft ?? draft },
                                set: { self.draft = $0 },
                            ),
                            errorMessage: errorMessage,
                            onSave: { block in
                                await save(block)
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
                    settingsSectionHeader("Could not change blocks")
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
                    settingsSectionHeader("Your blocks")
                    Text(
                        "Blocks are checked most specific first. A blank field matches anything, "
                            + "and a block with every field blank cannot be saved. "
                            + "A match cancels the listen: no now playing, no history and no delivery. "
                            + "Existing history stays where it is.",
                    )
                    .font(.body)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                }
            } content: {
                DropletSettingsCard {
                    if state.blocksFailure != nil {
                        DropletControlRow(title: "Blocks could not be read") {
                            Text("Capture continues with the last loaded blocks.")
                                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        }
                    }

                    if state.blocks.isEmpty {
                        DropletControlRow(
                            title: state.blocksFailure != nil ? "No blocks loaded" : "No blocks yet",
                        ) {
                            Text(
                                state.blocksFailure != nil
                                    ? "Nothing is blocked until the store can be read or a block is saved."
                                    : "Add one to hide a track, artist, album or album artist.",
                            )
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        }
                    } else {
                        ForEach(state.blocks) { block in
                            blockRow(block)
                        }
                        .droppyFlatGlassControls()
                    }

                    if draft == nil {
                        DropletControlRow(title: "New block") {
                            Button("Add") {
                                draft = BlockDraft()
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

    private func blockRow(_ block: BlockRule) -> some View {
        DropletStackedRow(title: blockTitle(block)) {
            VStack(alignment: .leading, spacing: DroppySpacing.xs) {
                Text(summary(block))
                    .font(.callout)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DroppySpacing.sm) {
                    Spacer(minLength: 0)
                    Button("Edit") {
                        draft = BlockDraft(block: block)
                        errorMessage = nil
                    }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
                    Button("Delete") {
                        delete(block)
                    }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small, destructive: true))
                }
            }
        }
    }

    private func blockTitle(_ block: BlockRule) -> String {
        let names = fields(block).map(\.label)
        return names.isEmpty ? "Block" : names.joined(separator: " + ")
    }

    private func summary(_ block: BlockRule) -> String {
        let values = fields(block).map { "\($0.label) “\($0.value)”" }
        return values.isEmpty ? "No fields" : values.joined(separator: ", ")
    }

    private func fields(_ block: BlockRule) -> [(label: String, value: String)] {
        [("Track", block.track), ("Artist", block.artist),
         ("Album", block.album), ("Album artist", block.albumArtist)]
            .filter { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    // MARK: - Actions

    private func save(_ block: BlockRule) async {
        do {
            try await droplet.saveBlock(block)
            draft = nil
            errorMessage = nil
        } catch let error as BlockRuleValidationError {
            errorMessage = blockValidationHint(for: error)
        } catch {
            errorMessage = "The block could not be saved."
        }
    }

    private func delete(_ block: BlockRule) {
        guard let id = block.id else { return }
        Task {
            do {
                try await droplet.deleteBlock(id: id)
                if draft?.id == id {
                    draft = nil
                }
                errorMessage = nil
            } catch {
                errorMessage = "The block could not be deleted."
            }
        }
    }
}

// MARK: - Form

private struct BlockForm: View {
    @Binding var draft: BlockDraft
    let errorMessage: String?
    let onSave: (BlockRule) async -> Void
    let onCancel: () -> Void

    @State private var isSaving = false

    var body: some View {
        BlockFieldEditor(title: "Track", value: $draft.track)
        BlockFieldEditor(title: "Artist", value: $draft.artist)
        BlockFieldEditor(title: "Album", value: $draft.album)
        BlockFieldEditor(title: "Album artist", value: $draft.albumArtist)

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
                    await onSave(draft.block)
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

private struct BlockFieldEditor: View {
    let title: String
    @Binding var value: String

    var body: some View {
        DropletStackedRow(title: title) {
            TextField("Any \(title.lowercased())", text: $value)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(title)
        }
    }
}

// MARK: - Draft

private struct BlockDraft {
    var id: Int64?
    var track = ""
    var artist = ""
    var album = ""
    var albumArtist = ""

    var isNew: Bool {
        id == nil
    }

    init() {}

    init(block: BlockRule) {
        id = block.id
        track = block.track
        artist = block.artist
        album = block.album
        albumArtist = block.albumArtist
    }

    var block: BlockRule {
        BlockRule(
            id: id,
            track: track.trimmingCharacters(in: .whitespacesAndNewlines),
            artist: artist.trimmingCharacters(in: .whitespacesAndNewlines),
            album: album.trimmingCharacters(in: .whitespacesAndNewlines),
            albumArtist: albumArtist.trimmingCharacters(in: .whitespacesAndNewlines),
        )
    }

    var validationError: BlockRuleValidationError? {
        block.validationError
    }

    var validationMessage: String? {
        blockValidationHint(for: validationError)
    }
}

private func blockValidationHint(for error: BlockRuleValidationError?) -> String? {
    switch error {
    case .none: nil
    case .noFields: "Fill in at least one field. Every field blank is a wildcard and would block everything."
    }
}
