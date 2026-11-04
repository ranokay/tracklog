import DroppyKit
import SwiftUI
import TracklogCore

/// One track's local history, shown inside the History section. The header
/// carries the full count and first listen computed over the whole database;
/// the rows page independently of the loaded History feed.
struct TracklogTrackHistoryContent: View {
    let droplet: TracklogDroplet
    @ObservedObject var state: TracklogAppState
    let track: TrackHistory

    var body: some View {
        VStack(spacing: 0) {
            header
            if let failure = track.failure, track.listens.isEmpty {
                failureState(failure)
            } else if track.isLoading, track.listens.isEmpty {
                loading
            } else if track.totalCount == 0 {
                empty
            } else {
                if let failure = track.failure {
                    failureBar(failure)
                }
                feed
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DroppySpacing.md) {
                Button {
                    droplet.closeTrackHistory()
                } label: {
                    Label("History", systemImage: "chevron.left")
                }
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
                .accessibilityLabel(Text("Back to History"))
                Spacer(minLength: DroppySpacing.md)
                Text(listenCountText(track.totalCount))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .monospacedDigit()
            }
            Text(track.title)
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            if !track.subtitle.isEmpty {
                Text(track.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .lineLimit(1)
            }
            if let first = track.firstListenedAt {
                Text("First listened \(first.formatted(date: .long, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            }
        }
        .padding(.horizontal, DroppySpacing.xl)
        .padding(.top, DroppySpacing.sm)
        .padding(.bottom, DroppySpacing.sm)
    }

    // MARK: States

    private var loading: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(Text("Loading track history"))
    }

    private var empty: some View {
        VStack(spacing: DroppySpacing.xsm) {
            Text("No listens for this track")
                .font(.headline)
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            Text("It is no longer in this Mac's local history.")
                .font(.body)
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failureState(_ failure: CaptureFailure) -> some View {
        VStack(spacing: DroppySpacing.sm) {
            Text("Track history unavailable")
                .font(.headline)
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            Text(failure.message)
                .font(.body)
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                .multilineTextAlignment(.center)
            HStack(spacing: DroppySpacing.sm) {
                Button("Try again") {
                    Task { await droplet.reloadTrackHistory() }
                }
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
                Button("Back to History") {
                    droplet.closeTrackHistory()
                }
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
            }
        }
        .padding(.horizontal, DroppySpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failureBar(_ failure: CaptureFailure) -> some View {
        HStack(spacing: DroppySpacing.md) {
            Text(failure.message)
                .font(.caption)
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                .lineLimit(2)
            Spacer(minLength: DroppySpacing.sm)
            Button("Try again") {
                Task { await droplet.reloadTrackHistory() }
            }
            .buttonStyle(DroppyQuietButtonStyle(size: .small))
        }
        .padding(.horizontal, DroppySpacing.xl)
        .padding(.bottom, DroppySpacing.xs)
    }

    // MARK: Feed

    private var feed: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(track.listens) { listen in
                    HistoryRow(
                        listen: listen,
                        droplet: droplet,
                        artwork: droplet.artworkData(for: listen),
                        deliveries: state.deliveries(for: listen),
                        connections: state.connections,
                        feedback: state.feedback(for: listen.processed.identity),
                        feedbackSupport: state.feedbackSupport,
                        showsDate: true,
                    )
                    .id(listen.id ?? -1)
                }
                if track.hasMore {
                    Group {
                        if track.isLoading {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel(Text("Loading older listens"))
                        } else {
                            Color.clear.frame(height: 1)
                        }
                    }
                    // Restarts when the loaded row count changes, so a dropped
                    // page request recovers as soon as the next read lands.
                    .task(id: track.listens.count) {
                        await droplet.loadMoreTrackHistory()
                    }
                }
            }
            .droppyFlatGlassControls()
            .scrollTargetLayout()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
