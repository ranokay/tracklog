import DroppyKit
import Foundation
import SwiftUI
import TracklogCore

/// The same count wording in the page header and in every day header.
func listenCountText(_ count: Int) -> String {
    "\(count.formatted()) \(count == 1 ? "listen" : "listens")"
}

/// Whether the surfaces should draw their increased-contrast separators. The
/// harness override exists because the runtime checks cannot change a system
/// accessibility setting; production only reads the environment value.
enum SurfaceContrast {
    static func isIncreased(_ contrast: ColorSchemeContrast) -> Bool {
        contrast == .increased
            || ProcessInfo.processInfo.environment["TRACKLOG_HARNESS_CONTRAST"] == "increased"
    }
}

/// A separator that appears only for people who ask for more contrast. It
/// strengthens the line between rows instead of changing the fill behind them.
struct SurfaceSeparator: View {
    var body: some View {
        Rectangle()
            .fill(AdaptiveColors.contrastTintAuto.opacity(0.32))
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

// MARK: - Day header

struct HistoryDayHeader: View {
    let day: HistoryDay
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DroppySpacing.md) {
            Text(day.date.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            Spacer(minLength: DroppySpacing.md)
            Text(listenCountText(count))
                .font(.caption.weight(.medium))
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
    let artwork: Data?
    let deliveries: [Delivery]
    let connections: [Connection]
    let feedback: TrackFeedback?
    let feedbackSupport: FeedbackSupport

    @State private var isHovering = false
    @Environment(\.colorSchemeContrast) private var colorContrast

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: DroppySpacing.md) {
                ArtworkSleeve(
                    size: 52,
                    artwork: artwork,
                    identity: listen.raw.identity,
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(listen.processed.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                        .lineLimit(1)
                    if !listen.processed.artist.isEmpty {
                        Text(listen.processed.artist)
                            .font(.subheadline)
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            .lineLimit(1)
                    }
                    if !listen.processed.album.isEmpty {
                        Text(listen.processed.album)
                            .font(.caption)
                            .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: DroppySpacing.sm)
                VStack(alignment: .trailing, spacing: DroppySpacing.xs) {
                    Text(listen.startedAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    Image(systemName: deliveryGlyph)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(deliveryGlyphColor)
                        .accessibilityHidden(true)
                }
                .accessibilityHidden(true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(rowLabel)
            .accessibilityValue(deliveryValue)

            rowMenu
        }
        .padding(.horizontal, DroppySpacing.xl)
        .frame(height: 68)
        .contentShape(Rectangle())
        .background(isHovering ? AdaptiveColors.overlayAuto(0.05) : .clear)
        .overlay(alignment: .bottom) {
            if SurfaceContrast.isIncreased(colorContrast) {
                SurfaceSeparator()
                    .padding(.horizontal, DroppySpacing.xl)
            }
        }
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

    private var deliveryValue: String {
        DeliverySummary(deliveries).accessibilityValue(connections: connections)
    }

    private var deliveryGlyph: String {
        switch DeliveryAggregate(deliveries) {
        case .delivered: "checkmark.circle.fill"
        case .pending: "clock.arrow.circlepath"
        case .notDelivered: "exclamationmark.circle.fill"
        case .none: "circle.dashed"
        }
    }

    private var deliveryGlyphColor: Color {
        switch DeliveryAggregate(deliveries) {
        case .delivered: AdaptiveColors.notchSurfaceSecondaryText
        case .pending: AdaptiveColors.notchSurfacePrimaryText
        case .notDelivered: AdaptiveColors.notchSurfacePrimaryText
        case .none: AdaptiveColors.notchSurfaceTertiaryText
        }
    }

    private var rowMenu: some View {
        Menu {
            rowMenuItems
        } label: {
            Image(systemName: "ellipsis")
                .font(.caption.weight(.bold))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText.opacity(0.9))
                .frame(width: 24, height: 24)
                .droppyGlassControlChrome(shape: AnyShape(Circle()), isHovering: isHovering)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity(isHovering ? 1 : 0.01)
        .allowsHitTesting(isHovering)
        .accessibilityLabel("Actions for \(listen.processed.title)")
    }

    @ViewBuilder
    private var rowMenuItems: some View {
        if deliveries.isEmpty {
            Text("No delivery targets")
        } else {
            Section("Deliveries") {
                ForEach(deliveries, id: \.id) { delivery in
                    Text(deliveryMenuText(delivery))
                }
            }
        }
        if feedbackSupport.canLove || feedbackSupport.canHate {
            Section("Feedback") {
                if feedbackSupport.canLove {
                    Button(feedback?.score == .loved ? "Unlove" : "Love") {
                        droplet.toggleLove(for: listen)
                    }
                }
                if feedbackSupport.canHate {
                    Button("Hate") {
                        droplet.hate(listen)
                    }
                }
            }
        }
        Button("Block") {
            droplet.quickBlock(listen)
        }
        Button("Copy metadata") {
            droplet.copyMetadata(for: listen)
        }
    }

    private func deliveryMenuText(_ delivery: Delivery) -> String {
        let name = delivery.serviceKind?.displayName
            ?? connections.first { $0.id == delivery.connectionID }?.kind.displayName
            ?? "Unknown service"
        switch delivery.state {
        case .waiting, .retrying:
            var parts = [
                "\(name) — \(delivery.state == .waiting ? "Waiting" : "Retrying")",
                "\(delivery.attempts) \(delivery.attempts == 1 ? "attempt" : "attempts")",
            ]
            if let error = delivery.lastError, !error.isEmpty {
                parts.append(error)
            }
            return parts.joined(separator: " · ")
        case .delivered:
            return "\(name) — Delivered"
        case .abandoned:
            guard let reason = delivery.abandonedReason, !reason.isEmpty else {
                return "\(name) — Not delivered"
            }
            return "\(name) — Not delivered · \(reason)"
        }
    }
}

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
                transition: DroppyTransition.compactContent,
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
        .disabled(!canLove)
        .help(loveHelp)
        .accessibilityLabel(isLoved ? "Unlove this track" : "Love this track")
        .accessibilityValue(Text(isLoved ? "Loved" : "Not loved"))
        .accessibilityHint(Text(loveHint))
        .accessibilityAddTraits(isLoved ? .isSelected : [])
        .transition(DroppyTransition.compactContent)
    }

    private var overflowMenu: some View {
        Menu {
            Button("Edit this track") {
                droplet.editCurrentListen()
            }
            Button("Block this track") {
                droplet.quickBlockCurrentTrack()
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.caption.weight(.bold))
                .frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
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
