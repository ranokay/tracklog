import DroppyKit
import SwiftUI
import TracklogCore

/// The same count wording in the page header and in every day header.
func listenCountText(_ count: Int) -> String {
    "\(count.formatted()) \(count == 1 ? "listen" : "listens")"
}

// MARK: - Day header

struct HistoryDayHeader: View {
    let day: HistoryDay
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DroppySpacing.md) {
            Text(day.date.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            Spacer(minLength: DroppySpacing.md)
            Text(listenCountText(count))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                .monospacedDigit()
        }
        .padding(.horizontal, DroppySpacing.xl)
        .padding(.top, DroppySpacing.lg)
        .padding(.bottom, DroppySpacing.xsm)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Row

struct HistoryRow: View {
    let listen: Listen
    let droplet: TracklogDroplet

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: DroppySpacing.md) {
                HistorySleeve(size: 52)
                VStack(alignment: .leading, spacing: 1) {
                    Text(listen.processed.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                        .lineLimit(1)
                    if !listen.processed.artist.isEmpty {
                        Text(listen.processed.artist)
                            .font(.system(size: 13))
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            .lineLimit(1)
                    }
                    if !listen.processed.album.isEmpty {
                        Text(listen.processed.album)
                            .font(.system(size: 11))
                            .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: DroppySpacing.sm)
                VStack(alignment: .trailing, spacing: DroppySpacing.xs) {
                    Text(listen.startedAt.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    Image(systemName: "circle.dashed")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                        .accessibilityHidden(true)
                }
                .accessibilityHidden(true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(rowLabel)
            .accessibilityValue("Delivery not recorded")

            rowMenu
        }
        .padding(.horizontal, DroppySpacing.xl)
        .frame(height: 68)
        .contentShape(Rectangle())
        .background(isHovering ? AdaptiveColors.overlayAuto(0.05) : .clear)
        .onHover { isHovering = $0 }
        .contextMenu { rowMenuItems }
    }

    private var rowLabel: String {
        [listen.processed.title, listen.processed.artist, listen.processed.album,
         listen.startedAt.formatted(date: .omitted, time: .shortened)]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private var rowMenu: some View {
        Menu {
            rowMenuItems
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText.opacity(0.9))
                .frame(width: 24, height: 24)
                .droppyGlassControlChrome(shape: AnyShape(Circle()), isHovering: isHovering)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity(isHovering ? 1 : 0)
        .allowsHitTesting(isHovering)
        .accessibilityLabel("Actions for \(listen.processed.title)")
    }

    private var rowMenuItems: some View {
        Button("Copy metadata") {
            droplet.copyMetadata(for: listen)
        }
    }
}

// MARK: - Now playing

struct NowPlayingStrip: View {
    let sample: MediaSample
    let status: ScrobbleStatus

    var body: some View {
        VStack(spacing: DroppySpacing.sm) {
            HStack(spacing: DroppySpacing.md) {
                HistorySleeve(size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: DroppySpacing.xs) {
                        Text(sample.track.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                            .lineLimit(1)
                        if !sample.track.artist.isEmpty {
                            Text("— \(sample.track.artist)")
                                .font(.system(size: 13))
                                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                                .lineLimit(1)
                        }
                    }
                    Text(elapsedText)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                }
                Spacer(minLength: DroppySpacing.md)
            }
            progressLine
        }
        .padding(.horizontal, DroppySpacing.xl)
        .frame(height: 76, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sample.track.title)
        .accessibilityValue(elapsedText)
    }

    private var elapsedText: String {
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

// MARK: - Sleeve

struct HistorySleeve: View {
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: DroppyRadius.ms, style: .continuous)
            .fill(AdaptiveColors.notchSurfaceCardFill)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.32, weight: .medium))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            }
            .accessibilityHidden(true)
    }
}
