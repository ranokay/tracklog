import DroppyKit
import SwiftUI
import TracklogCore

/// The history takeover's only surface.
let tracklogHistorySurfaceID: ExpandedSurfaceID = "history"

/// The content area this surface wants: the largest shelf takeover, about
/// 899 × 558, clamped to what the display actually allows.
private let tracklogHistoryPreferredSize = CGSize(width: 899, height: 558)

extension TracklogDroplet: ExpandedSurfaceProviding, ExpandedSurfaceHosting {
    public var expandedSurfaceProvider: (any ExpandedSurfaceProviding)? {
        self
    }

    public var expandedSurfaces: [ExpandedSurfaceDescriptor] {
        [
            ExpandedSurfaceDescriptor(
                id: tracklogHistorySurfaceID,
                title: "History",
                systemImage: "clock.arrow.circlepath",
                // The feed is a browse surface, not a form: outside click and
                // swipe still close it, and the host's shelf shortcut still
                // works. Only the widgets and the auto-collapse timer stand
                // down.
                suppresses: [.shelfWidgets, .autoCollapse],
            ),
        ]
    }

    public func makeExpandedSurfaceView(_ id: ExpandedSurfaceID, context: ExpandedSurfaceContext) -> AnyView {
        guard id == tracklogHistorySurfaceID else { return AnyView(EmptyView()) }
        return AnyView(
            TracklogHistory(droplet: self, state: state, context: context)
                .id(context.presentation.id),
        )
    }

    public func expandedSurfaceSize(
        _ id: ExpandedSurfaceID,
        fitting proposal: ExpandedSurfaceSizeProposal,
    ) -> CGSize? {
        guard id == tracklogHistorySurfaceID else { return nil }
        return CGSize(
            width: min(tracklogHistoryPreferredSize.width, proposal.maximumSize.width),
            height: min(tracklogHistoryPreferredSize.height, proposal.maximumSize.height),
        )
    }

    public func expandedSurfaceDidDismiss(
        _: ExpandedSurfaceID,
        presentation _: ExpandedSurfacePresentation,
        reason _: ExpandedSurfaceDismissalReason,
    ) {
        // The view owns only transient scroll state; the next presentation is
        // a fresh view that reloads the first page.
    }
}

// MARK: - The surface

private struct TracklogHistory: View {
    let droplet: TracklogDroplet
    @ObservedObject var state: TracklogAppState
    let context: ExpandedSurfaceContext

    /// The first item at the top edge, tracked so a listen arriving above the
    /// viewport does not move the row the user is reading.
    @State private var topAnchor: HistoryAnchor?

    var body: some View {
        VStack(spacing: 0) {
            header
            if let banner = state.pendingBanner {
                HistoryBannerView(banner: banner, droplet: droplet, state: state)
            }
            if state.pendingListExpanded, !state.pendingQueue.isEmpty {
                PendingQueuePanel(queue: state.pendingQueue, droplet: droplet, state: state)
            }
            content
            bottomBar
        }
        .frame(
            width: context.availableSize.width,
            height: context.availableSize.height,
            alignment: .topLeading,
        )
        .animation(TracklogMotion.stateAnimation, value: bottomBarKey)
        .task { await droplet.reloadHistory() }
        .onDisappear { state.setPendingListExpanded(false) }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: DroppySpacing.md) {
            Text("History")
                .font(.system(.title, design: .rounded, weight: .semibold))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            Spacer(minLength: DroppySpacing.md)
            Text(listenCountText(totalCount))
                .font(.callout.weight(.medium))
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                .monospacedDigit()
        }
        .padding(.horizontal, DroppySpacing.xl)
        .padding(.top, DroppySpacing.lg)
        .padding(.bottom, DroppySpacing.sm)
    }

    /// Paused and off turn the pinned strip into a state bar, so recovery is
    /// in the same place whether or not a track is playing.
    @ViewBuilder private var bottomBar: some View {
        if !state.scrobblingEnabled {
            if state.connections.isEmpty {
                HistoryStateBar(
                    droplet: droplet,
                    text: "Scrobbling is off",
                    actionTitle: "Connect a service",
                    action: { droplet.openServicesPage() },
                )
            } else {
                HistoryStateBar(
                    droplet: droplet,
                    text: "Scrobbling is off",
                    actionTitle: "Turn on",
                    action: { droplet.setScrobblingEnabled(true) },
                )
            }
        } else if let until = state.pausedUntil {
            HistoryStateBar(
                droplet: droplet,
                text: "Scrobbling paused until \(until.formatted(date: .omitted, time: .shortened))",
                actionTitle: "Resume",
                action: { droplet.resumeCapture() },
            )
        } else if let sample = state.nowPlaying {
            NowPlayingStrip(
                droplet: droplet,
                sample: sample,
                status: state.status,
                isLoved: state.nowPlayingIsLoved,
                canLove: state.feedbackSupport.canLove,
            )
        }
    }

    private var bottomBarKey: String {
        if !state.scrobblingEnabled {
            return state.connections.isEmpty ? "off.connect" : "off.connections"
        }
        if let until = state.pausedUntil {
            return "paused.\(until.timeIntervalSince1970)"
        }
        if let sample = state.nowPlaying {
            return "track.\(sample.track.identity)"
        }
        return "none"
    }

    private var totalCount: Int {
        max(state.historyCount, state.listens.count)
    }

    /// A store that could not open is a capture failure, not a history read
    /// failure; both leave the surface with nothing to show.
    private var unavailableFailure: CaptureFailure? {
        state.captureAvailable ? state.historyFailure : state.failure
    }

    // MARK: Body

    @ViewBuilder
    private var content: some View {
        if state.listens.isEmpty, let failure = unavailableFailure {
            unavailable(failure)
        } else if totalCount == 0 {
            empty
        } else {
            feed
        }
    }

    private var empty: some View {
        VStack(spacing: DroppySpacing.xsm) {
            Text("Nothing played yet")
                .font(.headline)
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            Text("Play something to start your history.")
                .font(.body)
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unavailable(_ failure: CaptureFailure) -> some View {
        VStack(spacing: DroppySpacing.xsm) {
            Text("History unavailable")
                .font(.headline)
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            Text(failure.message)
                .font(.body)
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var feed: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(feedItems) { item in
                        itemView(item)
                            .id(item.id)
                    }
                    if state.historyHasMore, !state.listens.isEmpty, state.historyFailure == nil {
                        Color.clear
                            .frame(height: 1)
                            .id(HistoryAnchor.footer)
                            // Restarts when the loaded row count changes, so a
                            // dropped page request recovers as soon as the next
                            // store change lands.
                            .task(id: state.listens) {
                                await droplet.loadMoreHistory()
                            }
                    } else if state.historyFailure != nil, !state.listens.isEmpty {
                        Text("Older history could not be loaded.")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, DroppySpacing.md)
                    }
                }
                .droppyFlatGlassControls()
                .scrollTargetLayout()
            }
            .scrollPosition(id: $topAnchor, anchor: .top)
            .onChange(of: state.listens) { old, new in
                preserveScroll(from: old, to: new, proxy: proxy)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var feedItems: [HistoryItem] {
        HistoryFeed.days(from: state.listens).flatMap { day in
            [.day(day)] + day.listens.map(HistoryItem.listen)
        }
    }

    @ViewBuilder
    private func itemView(_ item: HistoryItem) -> some View {
        switch item {
        case let .day(day):
            HistoryDayHeader(day: day, count: state.historyDayCounts[day.date] ?? day.count)
        case let .listen(listen):
            HistoryRow(
                listen: listen,
                droplet: droplet,
                artwork: droplet.artworkData(for: listen),
                deliveries: state.deliveries(for: listen),
                connections: state.connections,
                feedback: state.feedback(for: listen.processed.identity),
                feedbackSupport: state.feedbackSupport,
            )
        }
    }

    // MARK: Scroll preservation

    private func preserveScroll(
        from old: [Listen],
        to new: [Listen],
        proxy: ScrollViewProxy,
    ) {
        guard let anchor = topAnchor else { return }
        if isTop(anchor, in: old) {
            if let first = feedItems.first {
                scroll(to: first.id, proxy: proxy)
            }
        } else if contains(anchor, in: new) {
            scroll(to: anchor, proxy: proxy)
        } else if let fallback = fallbackAnchor(for: anchor, from: old, in: new) {
            scroll(to: fallback, proxy: proxy)
        }
    }

    /// A fixed page can drop its oldest row when a listen arrives. Anchor to
    /// the nearest surviving row instead of leaving the viewport where the
    /// replacement happens to put it.
    private func fallbackAnchor(
        for anchor: HistoryAnchor,
        from old: [Listen],
        in new: [Listen],
    ) -> HistoryAnchor? {
        guard !new.isEmpty else { return nil }
        switch anchor {
        case let .listen(id):
            guard let index = old.firstIndex(where: { $0.id == id }) else {
                return new.first.flatMap { $0.id.map(HistoryAnchor.listen) }
            }
            for row in old[index...] {
                if let rowID = row.id, new.contains(where: { $0.id == rowID }) {
                    return .listen(rowID)
                }
            }
            for row in old[..<index].reversed() {
                if let rowID = row.id, new.contains(where: { $0.id == rowID }) {
                    return .listen(rowID)
                }
            }
            return new.first.flatMap { $0.id.map(HistoryAnchor.listen) }
        case .day:
            return HistoryFeed.days(from: new).first.map { .day($0.date) }
        case .footer:
            return new.last.flatMap { $0.id.map(HistoryAnchor.listen) } ?? .footer
        }
    }

    private func isTop(_ anchor: HistoryAnchor, in listens: [Listen]) -> Bool {
        guard let firstDay = HistoryFeed.days(from: listens).first else { return false }
        return anchor == .day(firstDay.date)
    }

    private func contains(_ anchor: HistoryAnchor, in listens: [Listen]) -> Bool {
        switch anchor {
        case let .day(date):
            HistoryFeed.days(from: listens).contains { $0.date == date }
        case let .listen(id):
            listens.contains { $0.id == id }
        case .footer:
            !listens.isEmpty
        }
    }

    private func scroll(to anchor: HistoryAnchor, proxy: ScrollViewProxy) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(anchor, anchor: .top)
        }
    }
}

// MARK: - Feed identity

private enum HistoryAnchor: Hashable {
    case day(Date)
    case listen(Int64)
    case footer
}

private enum HistoryItem: Identifiable {
    case day(HistoryDay)
    case listen(Listen)

    var id: HistoryAnchor {
        switch self {
        case let .day(day):
            .day(day.date)
        case let .listen(listen):
            .listen(listen.id ?? -1)
        }
    }
}
