import DroppyKit
import SwiftUI
import TracklogCore

/// The shelf card: what is playing, and how far it is from a scrobble.
struct TracklogWidget: View {
    @ObservedObject var droplet: TracklogDroplet
    let context: ShelfWidgetContext

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xsm) {
            header
            content
            Spacer(minLength: 0)
        }
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: DroppySpacing.xsm) {
            Image(systemName: "waveform")
                .font(.system(size: 12, weight: .medium))
            Text("Tracklog")
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)
            if !context.isCompact {
                Button {
                    droplet.openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(DroppyCircleButtonStyle(size: 20))
                .help("Tracklog settings")
                .accessibilityLabel("Tracklog settings")
            }
        }
        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
    }

    @ViewBuilder
    private var content: some View {
        if !droplet.scrobblingEnabled {
            title("Scrobbling is off")
            subtitle(context.isCompact ? "Turn on in Settings" : "Turn it on in Tracklog settings.")
        } else if let sample = droplet.nowPlaying {
            Text(sample.track.title)
                .font(.system(size: context.isCompact ? 16 : 22, weight: .semibold, design: .rounded))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .lineLimit(context.isCompact ? 1 : 2)
                .minimumScaleFactor(0.9)

            Text(artistLine(sample))
                .font(.system(size: 13))
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                .lineLimit(1)

            if !context.isCompact {
                ProgressView(value: droplet.status.progress)
                    .progressViewStyle(.linear)
                    .tint(AdaptiveColors.notchSurfacePrimaryText)
                    .controlSize(.small)
            }

            Text(statusLine)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                .lineLimit(1)
        } else {
            title(droplet.helperAvailable ? "Nothing playing" : "Media feed unavailable")
            subtitle(
                droplet.helperAvailable
                    ? "Play something to start scrobbling."
                    : "Tracklog cannot read now playing in this host."
            )
        }
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: context.isCompact ? 16 : 22, weight: .semibold, design: .rounded))
            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            .lineLimit(1)
    }

    private func subtitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            .lineLimit(2)
    }

    private func artistLine(_ sample: MediaSample) -> String {
        let line = [sample.track.artist, sample.track.album]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " · ")
        return line.isEmpty ? "Unknown artist" : line
    }

    private var statusLine: String {
        if !droplet.status.isPlaying {
            return "Paused"
        }
        switch droplet.status.phase {
        case .scrobbled:
            return "Scrobbled"
        case .armed:
            return "Scrobbling in \(time(droplet.status.remaining))"
        case .idle:
            return "Waiting"
        }
    }

    private func time(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
