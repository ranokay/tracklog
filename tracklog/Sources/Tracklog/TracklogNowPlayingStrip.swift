import DroppyKit
import Foundation
import SwiftUI
import TracklogCore

// MARK: - Now playing

struct NowPlayingStrip: View {
    let droplet: TracklogDroplet
    let sample: MediaSample
    let status: ScrobbleStatus
    let isLoved: Bool
    let canLove: Bool

    var body: some View {
        VStack(spacing: DroppySpacing.sm) {
            HStack(spacing: DroppySpacing.md) {
                ArtworkSleeve(
                    size: 56,
                    artwork: droplet.state.nowPlayingArtwork,
                    identity: droplet.state.nowPlayingArtworkIdentity ?? sample.track.identity,
                )
                info
                Spacer(minLength: DroppySpacing.md)
                controls
                overflowMenu
            }
            progressLine
        }
        .padding(.horizontal, DroppySpacing.xl)
        .frame(height: 76, alignment: .bottom)
        .onAppear { TracklogMotion.logReducedPathOnce() }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: DroppySpacing.xs) {
                Text(sample.track.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .lineLimit(1)
                if !sample.track.artist.isEmpty {
                    Text("— \(sample.track.artist)")
                        .font(.subheadline)
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        .lineLimit(1)
                }
            }
            Text(elapsedText)
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sample.track.title)
        .accessibilityValue(elapsedText)
    }

    private var controls: some View {
        HStack(spacing: DroppySpacing.xs) {
            loveButton
            ListenControls(
                droplet: droplet,
                status: status,
                transition: TracklogMotion.compactContent,
            )
        }
    }

    private var loveButton: some View {
        Button {
            droplet.toggleLoveForCurrentTrack()
        } label: {
            Image(systemName: isLoved ? "heart.fill" : "heart")
                .frame(width: 24, height: 24)
        }
        .buttonStyle(DroppyCircleButtonStyle(size: 24))
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
        .disabled(!canLove)
        .help(loveHelp)
        .accessibilityLabel(isLoved ? "Unlove this track" : "Love this track")
        .accessibilityValue(Text(isLoved ? "Loved" : "Not loved"))
        .accessibilityHint(Text(loveHint))
        .accessibilityAddTraits(isLoved ? .isSelected : [])
        .transition(TracklogMotion.compactContent)
    }

    private var overflowMenu: some View {
        Menu {
            Button("Search and play this track") {
                droplet.searchAndPlay(
                    title: sample.track.title,
                    artist: sample.track.artist,
                )
            }
            Divider()
            TracklogMenuItems(
                droplet: droplet,
                status: status,
                scrobblingEnabled: droplet.state.scrobblingEnabled,
                pausedUntil: droplet.state.pausedUntil,
                hasTrack: true,
                includesListenControls: false,
            )
        } label: {
            Image(systemName: "ellipsis")
                .font(.caption.weight(.bold))
                .frame(width: 24, height: 24)
        }
        .menuStyle(.button)
        .buttonStyle(DroppyCircleButtonStyle(size: 24))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel(Text("More"))
    }

    private var loveHelp: String {
        guard canLove else {
            return "Connect a service that supports love"
        }
        return isLoved ? "Unlove this track" : "Love this track"
    }

    private var loveHint: String {
        canLove ? "" : "Connect a service that supports love."
    }

    private var elapsedText: String {
        if status.isCancelled {
            return trackingCancelledText
        }
        let elapsed = time(sample.elapsed)
        guard sample.track.duration > 0 else { return "\(elapsed) played" }
        return "\(elapsed) of \(time(sample.track.duration))"
    }

    private var progress: Double {
        if sample.track.duration > 0 {
            return min(1, max(0, sample.elapsed / sample.track.duration))
        }
        return status.progress
    }

    private var progressLine: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(AdaptiveColors.overlayAuto(0.12))
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(AdaptiveColors.notchSurfacePrimaryText.opacity(0.85))
                    .frame(width: geometry.size.width * progress)
            }
        }
        .frame(height: 3)
    }

    private func time(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
