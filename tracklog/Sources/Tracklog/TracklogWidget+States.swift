import DroppyKit
import SwiftUI
import TracklogCore

extension TracklogWidget {
    // MARK: - Paired

    /// The compact composition is exactly the sleeve, title, countdown, Love
    /// and Queue. It has no header, artist, album, progress or overflow.
    var paired: some View {
        Group {
            switch phase {
            case let .playing(sample):
                pairedPlaying(sample)
            case let .paused(until):
                pairedState(
                    title: "Paused",
                    subtitle: "Resumes at \(clockTime(until))",
                    actionTitle: "Resume",
                    action: { droplet.resumeCapture() },
                )
            case .offWithoutConnections:
                pairedState(title: "Connect a service", subtitle: nil)
            case .off:
                pairedState(title: "Scrobbling is off", subtitle: nil)
            case .historyUnavailable:
                pairedState(title: "History unavailable", subtitle: nil)
            case .feedUnavailable:
                pairedState(title: "Media feed unavailable", subtitle: "Playback will not be scrobbled.")
            case .idle:
                pairedState(title: "Nothing playing", subtitle: nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    func pairedPlaying(_ sample: MediaSample) -> some View {
        HStack(alignment: .center, spacing: DroppySpacing.sm) {
            Button {
                droplet.presentHistory()
            } label: {
                HStack(alignment: .center, spacing: DroppySpacing.sm) {
                    ArtworkSleeve(
                        size: 48,
                        artwork: state.nowPlayingArtwork,
                        identity: state.nowPlayingArtworkIdentity ?? sample.track.identity,
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sample.track.title)
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                        Text(pairedCountdown(sample))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(sample.track.title))
            .accessibilityValue(Text(pairedAccessibilityValue(sample)))
            .accessibilityHint(Text("Opens History"))
            .accessibilitySortPriority(3)

            VStack(spacing: DroppySpacing.xs) {
                loveButton
                queueButton
            }
        }
    }

    func pairedState(
        title: String,
        subtitle: String?,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
    ) -> some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xs) {
            HStack(alignment: .top, spacing: DroppySpacing.sm) {
                Button {
                    droplet.presentHistory()
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                            .lineLimit(1)
                        if let subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(title))
                .accessibilityValue(Text(subtitle ?? ""))
                .accessibilityHint(Text("Opens History"))

                if state.pendingCount > 0 {
                    queueButton
                }
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
            }
        }
    }

    func pairedAccessibilityValue(_ sample: MediaSample) -> String {
        if state.status.isCancelled {
            return trackingCancelledText
        }
        if !state.status.isPlaying {
            return "Paused"
        }
        switch state.status.phase {
        case .scrobbled:
            return "Scrobbled"
        case .armed:
            return "Scrobbles in \(spokenSeconds(state.status.remaining))"
        case .idle:
            return time(sample.elapsed)
        }
    }

    func pairedCountdown(_ sample: MediaSample) -> String {
        if state.status.isCancelled {
            return trackingCancelledText
        }
        if !state.status.isPlaying {
            return "Paused"
        }
        switch state.status.phase {
        case .scrobbled:
            return "Scrobbled"
        case .armed:
            return time(state.status.remaining)
        case .idle:
            return time(sample.elapsed)
        }
    }

    // MARK: - Shared state block

    func stateBlock(
        title: String,
        subtitle: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
    ) -> some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xs) {
            Button {
                droplet.presentHistory()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(subtitle))
            .accessibilityHint(Text("Opens History"))

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
            }
        }
    }
}
