import DroppyKit
import SwiftUI
import TracklogCore

extension TracklogWidget {
    func soloPlaying(_ sample: MediaSample) -> some View {
        HStack(alignment: .top, spacing: DroppySpacing.md) {
            ZStack(alignment: .bottomTrailing) {
                Button {
                    droplet.presentHistory()
                } label: {
                    HStack(alignment: .top, spacing: DroppySpacing.md) {
                        ArtworkSleeve(
                            size: 92,
                            artwork: state.nowPlayingArtwork,
                            identity: state.nowPlayingArtworkIdentity ?? sample.track.identity,
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sample.track.title)
                                .font(.system(.title2, design: .rounded, weight: .semibold))
                                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                                .lineLimit(2)
                                .minimumScaleFactor(0.9)
                            if !sample.track.artist.isEmpty {
                                Text(sample.track.artist)
                                    .font(.body)
                                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                                    .lineLimit(1)
                            }
                            if !sample.track.album.isEmpty {
                                Text(sample.track.album)
                                    .font(.subheadline)
                                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            ProgressView(value: progress(for: sample))
                                .progressViewStyle(.linear)
                                .tint(AdaptiveColors.notchSurfacePrimaryText)
                                .controlSize(.small)
                                .accessibilityHidden(true)
                            HStack(spacing: DroppySpacing.xs) {
                                Text(statusLine)
                                    .font(.system(.callout, design: .default, weight: .medium))
                                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                                    .lineLimit(1)
                                Spacer(minLength: state.status.canUndo ? 56 : 28)
                            }
                        }
                        .frame(height: 92, alignment: .topLeading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(trackLabel(sample)))
                .accessibilityValue(Text(soloValue(sample)))
                .accessibilityHint(Text("Opens History"))
                .accessibilitySortPriority(4)

                HStack(spacing: DroppySpacing.xs) {
                    if state.status.canUndo {
                        undoButton
                    }
                    loveButton
                }
                .padding(.bottom, 1)
            }
        }
    }

    func trackLabel(_ sample: MediaSample) -> String {
        [sample.track.title, sample.track.artist]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: ", ")
    }

    func soloValue(_ sample: MediaSample) -> String {
        if state.status.isCancelled {
            return trackingCancelledText
        }
        var parts = [elapsedValue(sample)]
        if state.status.isPlaying {
            switch state.status.phase {
            case .scrobbled:
                parts.append("scrobbled")
            case .armed:
                parts.append("scrobbles in \(spokenSeconds(state.status.remaining))")
            case .idle:
                break
            }
        } else {
            parts.append("paused")
        }
        if state.pendingCount > 0 {
            parts.append("\(state.pendingCount) waiting")
        }
        return parts.joined(separator: ", ")
    }
}
