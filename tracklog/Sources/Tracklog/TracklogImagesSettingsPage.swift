import DroppyKit
import SwiftUI
import TracklogCore

// MARK: - Images

/// The one place an artist or album image is chosen, replaced or removed.
/// The detail page's Change image… opens this page with a pending entity; the
/// page also lists every saved override and carries the Apple lookup switch.
struct TracklogImagesSettingsPage: View {
    let droplet: TracklogDroplet
    @ObservedObject var state: TracklogAppState

    var body: some View {
        DropletSettingsPage {
            if let draft = state.imageOverrideDraft {
                DropletSettingsSection {
                    VStack(alignment: .leading, spacing: 2) {
                        settingsSectionHeader("Chosen image")
                        Text(draft.displayName)
                            .font(.body)
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    }
                } content: {
                    DropletSettingsCard {
                        DropletStackedRow(title: "Image") {
                            HStack(alignment: .center, spacing: DroppySpacing.md) {
                                ArtworkSleeve(
                                    size: 64,
                                    artwork: overridePreview(draft),
                                    identity: "\(draft.kind.rawValue)\u{1F}\(draft.key)",
                                    isCircular: draft.kind == .artist,
                                )
                                VStack(alignment: .leading, spacing: DroppySpacing.xs) {
                                    Button("Choose image…") {
                                        droplet.chooseImageOverrideFile()
                                    }
                                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
                                    if state.imageOverride(
                                        kind: draft.kind,
                                        key: draft.key,
                                    ) != nil {
                                        Button("Remove image", role: .destructive) {
                                            remove(draft)
                                        }
                                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                                    }
                                }
                                Spacer(minLength: DroppySpacing.sm)
                            }
                        }
                    }
                }
            }

            if let error = state.imageOverrideError {
                DropletSettingsCard {
                    HStack(alignment: .top, spacing: DroppySpacing.sm) {
                        Image(systemName: "exclamationmark.circle")
                            .font(.body.weight(.semibold))
                            .accessibilityHidden(true)
                        Text(error)
                            .font(.body)
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: DroppySpacing.sm)
                        Button("Dismiss") {
                            droplet.dismissImageOverrideError()
                        }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                    }
                }
            }

            DropletSettingsSection {
                VStack(alignment: .leading, spacing: 2) {
                    settingsSectionHeader("Saved images")
                    Text(
                        "Every artist and album image you chose. Removing one restores "
                            + "the page's next available image, or the neutral sleeve.",
                    )
                    .font(.body)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                }
            } content: {
                DropletSettingsCard {
                    if state.imageOverrides.isEmpty {
                        DropletControlRow(title: "No saved images") {
                            Text("Choose one from an artist or album page.")
                                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        }
                    } else {
                        ForEach(state.imageOverrides) { override in
                            DropletStackedRow(title: override.displayName) {
                                let readable = state.isImageOverrideReadable(override)
                                VStack(alignment: .leading, spacing: DroppySpacing.xs) {
                                    HStack(spacing: DroppySpacing.md) {
                                        ArtworkSleeve(
                                            size: 44,
                                            artwork: state.artworkByHash[override.artworkHash],
                                            identity: override.key,
                                            isCircular: override.kind == .artist,
                                        )
                                        Spacer(minLength: DroppySpacing.sm)
                                        Button("Replace") {
                                            replace(override)
                                        }
                                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                                        .accessibilityLabel(Text("Replace image for \(override.displayName)"))
                                        Button("Remove", role: .destructive) {
                                            droplet.removeImageOverride(override)
                                        }
                                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                                        .accessibilityLabel(Text("Remove image for \(override.displayName)"))
                                    }
                                    if !readable {
                                        Text("The saved copy could not be read. Replace or remove it.")
                                            .font(.caption)
                                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .accessibilityLabel(
                                                Text(
                                                    "The saved image for \(override.displayName) "
                                                        + "could not be read. Replace or remove it.",
                                                ),
                                            )
                                    }
                                }
                            }
                        }
                    }
                }
            }

            DropletSettingsSection {
                VStack(alignment: .leading, spacing: 2) {
                    settingsSectionHeader("Artist images")
                    Text(
                        "Artist names are sent to Apple when an artist page opens, so "
                            + "Tracklog can show an approximate image from an album cover. "
                            + "Turn this off to keep names on this Mac; chosen images and "
                            + "neutral sleeves still work.",
                    )
                    .font(.body)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                }
            } content: {
                DropletSettingsCard {
                    DropletToggleRow(
                        title: "Look up artist images",
                        subtitle: "Sends artist names to Apple. On by default.",
                        isOn: droplet.artistImageLookupsBinding,
                    )
                }
            }
        }
        .onDisappear {
            droplet.finishImagesSettingsPage()
        }
    }

    private func overridePreview(_ draft: ImageOverrideDraft) -> Data? {
        guard let override = state.imageOverride(
            kind: draft.kind,
            key: draft.key,
        ) else { return nil }
        return state.artworkByHash[override.artworkHash]
    }

    private func replace(_ override: ImageOverride) {
        state.setImageOverrideDraft(
            ImageOverrideDraft(
                kind: override.kind,
                key: override.key,
                title: override.title,
                subtitle: override.subtitle,
            ),
        )
        state.setImageOverrideError(nil)
        droplet.chooseImageOverrideFile()
    }

    private func remove(_ draft: ImageOverrideDraft) {
        Task {
            do {
                try await droplet.runtime?.removeImageOverride(
                    kind: draft.kind,
                    key: draft.key,
                )
            } catch {
                state.setImageOverrideError("The image could not be removed. \(error)")
            }
        }
    }
}
