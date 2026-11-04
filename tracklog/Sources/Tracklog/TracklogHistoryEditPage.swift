import DroppyKit
import SwiftUI
import TracklogCore

let tracklogHistoryEditPageID = "history-edit"

/// One history row's typed correction. The takeover stays browse-only; the
/// one-off edit and its optional rule live here, beside the date jump.
struct TracklogHistoryEditPage: View {
    let droplet: TracklogDroplet
    @ObservedObject var state: TracklogAppState

    @State private var draft: ListenEditDraft?
    @State private var errorMessage: String?
    @State private var isSaving = false

    var body: some View {
        DropletSettingsPage {
            if let listen = state.listenEdit {
                content(for: listen)
            } else {
                noSelection
            }
        }
        .onAppear { loadDraft() }
        .onChange(of: state.listenEdit) { _, _ in loadDraft() }
    }

    @ViewBuilder
    // swiftlint:disable:next function_body_length
    private func content(for listen: Listen) -> some View {
        let notice = ListenMutationNoticeBuilder.edit(
            deliveries: state.deliveries(for: listen),
            connections: state.connections,
        )

        DropletSettingsSection {
            VStack(alignment: .leading, spacing: 2) {
                settingsSectionHeader("Edit listen")
                Text("\(notice.body) \(notice.footer)")
                    .font(.body)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } content: {
            DropletSettingsCard {
                DropletStackedRow(title: "Track") {
                    TextField("Track", text: binding(\.title))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(Text("Track"))
                }
                DropletStackedRow(title: "Artist") {
                    TextField("Artist", text: binding(\.artist))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(Text("Artist"))
                }
                DropletStackedRow(title: "Album") {
                    TextField("Album", text: binding(\.album))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(Text("Album"))
                }
                DropletStackedRow(title: "Album artist") {
                    TextField("Album artist", text: binding(\.albumArtist))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(Text("Album artist"))
                }
                DropletToggleRow(
                    title: "Remember as rule",
                    subtitle: "Corrects future plays of this track. Existing history is not rewritten.",
                    isOn: binding(\.rememberAsRule),
                )
            }
        }

        if let draft, !draft.serviceLines(notice).isEmpty {
            DropletSettingsSection {
                settingsSectionHeader("Services")
            } content: {
                DropletSettingsCard {
                    ForEach(Array(draft.serviceLines(notice).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.callout)
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }

        if let message = errorMessage ?? draft?.validationMessage {
            DropletSettingsSection {
                settingsSectionHeader("Not saved yet")
            } content: {
                DropletSettingsCard {
                    Text(message)
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        HStack(spacing: DroppySpacing.sm) {
            Spacer(minLength: 0)
            Button("Cancel") {
                droplet.finishListenEdit()
            }
            .buttonStyle(DroppyQuietButtonStyle(size: .small))
            .keyboardShortcut(.cancelAction)
            .disabled(isSaving)
            Button("Save") {
                Task { await save(listen) }
            }
            .buttonStyle(DroppyAccentButtonStyle(size: .small))
            .disabled(isSaving || draft?.canSave != true)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var noSelection: some View {
        DropletSettingsSection {
            settingsSectionHeader("No listen selected")
        } content: {
            DropletSettingsCard {
                Text("Open History and choose Edit listen on a row.")
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Back to History") {
                    droplet.finishListenEdit()
                }
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<ListenEditDraft, String>) -> Binding<String> {
        Binding(
            get: { draft?[keyPath: keyPath] ?? "" },
            set: { value in
                draft?[keyPath: keyPath] = value
                errorMessage = nil
            },
        )
    }

    private func binding(_ keyPath: WritableKeyPath<ListenEditDraft, Bool>) -> Binding<Bool> {
        Binding(
            get: { draft?[keyPath: keyPath] ?? false },
            set: { value in
                draft?[keyPath: keyPath] = value
                errorMessage = nil
            },
        )
    }

    private func loadDraft() {
        guard let listen = state.listenEdit else {
            draft = nil
            errorMessage = nil
            return
        }
        if draft?.listenID != listen.id {
            draft = ListenEditDraft(listen: listen)
            errorMessage = nil
        }
    }

    private func save(_ listen: Listen) async {
        guard let draft else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            _ = try await droplet.saveListenEdit(
                listen,
                metadata: draft.metadata,
                rememberAsRule: draft.rememberAsRule,
            )
            droplet.finishListenEdit()
        } catch let error as ListenMutationError {
            errorMessage = error.message
        } catch {
            errorMessage = "This listen could not be updated."
        }
    }
}

private struct ListenEditDraft {
    let listenID: Int64?
    let original: ListenMetadata
    var title: String
    var artist: String
    var album: String
    var albumArtist: String
    var rememberAsRule = false

    init(listen: Listen) {
        listenID = listen.id
        original = listen.processed
        title = listen.processed.title
        artist = listen.processed.artist
        album = listen.processed.album
        albumArtist = listen.processed.albumArtist
    }

    var metadata: ListenMetadata {
        ListenMetadata(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            artist: artist.trimmingCharacters(in: .whitespacesAndNewlines),
            album: album.trimmingCharacters(in: .whitespacesAndNewlines),
            albumArtist: albumArtist.trimmingCharacters(in: .whitespacesAndNewlines),
        )
    }

    var validationMessage: String? {
        if metadata.title.isEmpty {
            return "Track cannot be empty."
        }
        if metadata.artist.isEmpty {
            return "Artist cannot be empty."
        }
        return nil
    }

    var canSave: Bool {
        validationMessage == nil && metadata != original
    }

    func serviceLines(_ notice: ListenMutationNotice) -> [String] {
        notice.serviceLines
    }
}
