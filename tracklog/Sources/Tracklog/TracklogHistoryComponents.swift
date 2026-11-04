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
    let showsDate: Bool
    let onOpen: (() -> Void)?

    @State private var isHovering = false
    @Environment(\.colorSchemeContrast) private var colorContrast

    init(
        listen: Listen,
        droplet: TracklogDroplet,
        artwork: Data?,
        deliveries: [Delivery],
        connections: [Connection],
        feedback: TrackFeedback?,
        feedbackSupport: FeedbackSupport,
        showsDate: Bool = false,
        onOpen: (() -> Void)? = nil,
    ) {
        self.listen = listen
        self.droplet = droplet
        self.artwork = artwork
        self.deliveries = deliveries
        self.connections = connections
        self.feedback = feedback
        self.feedbackSupport = feedbackSupport
        self.showsDate = showsDate
        self.onOpen = onOpen
    }

    var body: some View {
        HStack(spacing: 0) {
            infoArea
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
    }

    /// The row body is one element with the #26 label and value. When it opens
    /// track history it is represented as a real button, so VoiceOver gets the
    /// button trait and a default press action. The Actions menu stays a
    /// separate target beside it.
    @ViewBuilder
    private var infoArea: some View {
        if let onOpen {
            Button(action: onOpen) {
                infoContent
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityLabel(rowLabel)
            .accessibilityValue(deliveryValue)
            .accessibilityHint(Text("Shows this track's history"))
        } else {
            infoContent
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(rowLabel)
                .accessibilityValue(deliveryValue)
        }
    }

    private var infoContent: some View {
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
                Text(timeText)
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
    }

    private var timeText: String {
        if showsDate {
            listen.startedAt.formatted(date: .abbreviated, time: .shortened)
        } else {
            listen.startedAt.formatted(date: .omitted, time: .shortened)
        }
    }

    private var rowLabel: String {
        [listen.processed.title, listen.processed.artist, listen.processed.album, timeText]
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
                .frame(width: 24, height: 24)
        }
        .menuStyle(.button)
        .buttonStyle(DroppyCircleButtonStyle(size: 24))
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        .opacity(isHovering ? 1 : 0.01)
        .allowsHitTesting(isHovering)
        .help("Actions for \(listen.processed.title)")
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
