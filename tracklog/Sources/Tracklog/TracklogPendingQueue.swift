import DroppyKit
import SwiftUI
import TracklogCore

// MARK: - Banner

/// The one problem pinned above the feed. The text is one accessibility
/// element and the action is its own button.
struct HistoryBannerView: View {
    let banner: HistoryBanner
    let droplet: TracklogDroplet
    @ObservedObject var state: TracklogAppState
    @Environment(\.colorSchemeContrast) private var colorContrast

    var body: some View {
        HStack(spacing: DroppySpacing.md) {
            Image(systemName: systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: DroppySpacing.sm)
            Button(actionTitle) {
                performAction()
            }
            .buttonStyle(DroppyQuietButtonStyle(size: .small))
        }
        .padding(.horizontal, DroppySpacing.lg)
        .padding(.vertical, DroppySpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DroppyRadius.ms, style: .continuous)
                .fill(AdaptiveColors.overlayAuto(0.08)),
        )
        .overlay {
            if colorContrast == .increased {
                RoundedRectangle(cornerRadius: DroppyRadius.ms, style: .continuous)
                    .stroke(AdaptiveColors.contrastTintAuto.opacity(0.32), lineWidth: 1)
            }
        }
        .padding(.horizontal, DroppySpacing.xl)
        .padding(.bottom, DroppySpacing.xs)
    }

    private var systemImage: String {
        switch banner {
        case .mediaFeedUnavailable: "waveform.slash"
        case .needsSignIn: "person.crop.circle.badge.exclamationmark"
        case .rateLimited: "clock.arrow.circlepath"
        case .pending: "tray.full"
        }
    }

    private var title: String {
        switch banner {
        case .mediaFeedUnavailable:
            "Media feed unavailable"
        case let .needsSignIn(connections):
            connections.count == 1
                ? "\(connections[0].kind.displayName) needs sign-in"
                : "\(connections.count) services need sign-in"
        case let .rateLimited(connections):
            connections.count == 1
                ? "\(connections[0].kind.displayName) is rate limited"
                : "\(connections.count) services are rate limited"
        case let .pending(queue):
            "\(queue.count) \(queue.count == 1 ? "scrobble" : "scrobbles") waiting"
        }
    }

    private var detail: String {
        switch banner {
        case .mediaFeedUnavailable:
            "Playback will not be scrobbled."
        case .needsSignIn:
            "Scrobbles are waiting."
        case .rateLimited:
            "Retrying automatically."
        case .pending:
            "Still waiting to be sent."
        }
    }

    private var actionTitle: String {
        switch banner {
        case .mediaFeedUnavailable:
            "Settings"
        case .needsSignIn:
            "Sign in"
        case .rateLimited:
            "Retry"
        case .pending:
            state.pendingListExpanded ? "Hide" : "Review"
        }
    }

    private func performAction() {
        switch banner {
        case .mediaFeedUnavailable:
            droplet.openSettings()
        case .needsSignIn:
            droplet.openServicesPage()
        case let .rateLimited(connections):
            droplet.retryDeliveries(forConnections: connections)
        case .pending:
            state.togglePendingList()
        }
    }
}

// MARK: - Pending list

/// The expanded pending list: one group per connection, oldest listen first.
struct PendingQueuePanel: View {
    let queue: PendingQueue
    let droplet: TracklogDroplet
    @ObservedObject var state: TracklogAppState
    @Environment(\.colorSchemeContrast) private var colorContrast

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DroppySpacing.sm) {
                Text("Pending scrobbles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                Spacer(minLength: DroppySpacing.sm)
                Button("Hide") {
                    state.setPendingListExpanded(false)
                }
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
            }
            .padding(.horizontal, DroppySpacing.md)
            .padding(.vertical, DroppySpacing.xs)

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(queue.groups) { group in
                        PendingConnectionGroupView(group: group, droplet: droplet)
                    }
                }
                .droppyFlatGlassControls()
            }
            .frame(maxHeight: 220)
        }
        .padding(.bottom, DroppySpacing.xs)
        .background(
            RoundedRectangle(cornerRadius: DroppyRadius.ms, style: .continuous)
                .fill(AdaptiveColors.overlayAuto(0.04)),
        )
        .overlay {
            if colorContrast == .increased {
                RoundedRectangle(cornerRadius: DroppyRadius.ms, style: .continuous)
                    .stroke(AdaptiveColors.contrastTintAuto.opacity(0.32), lineWidth: 1)
            }
        }
        .padding(.horizontal, DroppySpacing.xl)
        .padding(.bottom, DroppySpacing.xs)
    }
}

private struct PendingConnectionGroupView: View {
    let group: PendingDeliveryGroup
    let droplet: TracklogDroplet

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DroppySpacing.sm) {
                Text(group.connection.kind.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                Text(group.connection.identity)
                    .font(.caption)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .lineLimit(1)
                Spacer(minLength: DroppySpacing.sm)
                Button("Retry") {
                    guard let id = group.connection.id else { return }
                    droplet.retryDeliveries(forConnection: id)
                }
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
                .accessibilityLabel("Retry \(group.connection.kind.displayName) deliveries")
            }
            .padding(.horizontal, DroppySpacing.md)
            .padding(.vertical, DroppySpacing.xs)

            ForEach(group.items) { item in
                PendingDeliveryRow(item: item, droplet: droplet)
            }
        }
    }
}

private struct PendingDeliveryRow: View {
    let item: PendingDeliveryItem
    let droplet: TracklogDroplet
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: DroppySpacing.sm) {
            VStack(alignment: .leading, spacing: 1) {
                Text(trackTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .lineLimit(1)
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .lineLimit(1)
                if let error = item.delivery.lastError, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                        .lineLimit(2)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: DroppySpacing.sm)
            Button {
                droplet.deleteDelivery(item.delivery)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(DroppyCircleButtonStyle(size: 24))
            .opacity(isHovering ? 1 : 0.55)
            .help("Delete this delivery")
            .accessibilityLabel("Delete \(trackTitle) delivery to \(item.connection.kind.displayName)")
        }
        .padding(.horizontal, DroppySpacing.md)
        .padding(.vertical, DroppySpacing.xs)
        .background(isHovering ? AdaptiveColors.overlayAuto(0.05) : .clear)
        .onHover { isHovering = $0 }
    }

    private var trackTitle: String {
        let artist = item.listen.processed.artist
        guard !artist.isEmpty else { return item.listen.processed.title }
        return "\(item.listen.processed.title) — \(artist)"
    }

    private var statusLine: String {
        var parts = [stateText]
        if item.delivery.attempts > 0 {
            parts.append("\(item.delivery.attempts) \(item.delivery.attempts == 1 ? "attempt" : "attempts")")
        }
        parts.append(lastAttemptText)
        return parts.joined(separator: " · ")
    }

    private var stateText: String {
        switch item.delivery.state {
        case .waiting: "Waiting"
        case .retrying: "Retrying"
        case .delivered: "Delivered"
        case .abandoned: "Not delivered"
        }
    }

    private var lastAttemptText: String {
        guard let lastAttempt = item.delivery.lastAttemptAt else { return "Not tried yet" }
        if Calendar.current.isDateInToday(lastAttempt) {
            return "Last tried \(lastAttempt.formatted(date: .omitted, time: .shortened))"
        }
        return "Last tried \(lastAttempt.formatted(date: .abbreviated, time: .shortened))"
    }
}
