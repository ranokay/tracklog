import DroppyKit
import SwiftUI
import TracklogCore

/// The track detail's local listen list. The summary above it comes from the
/// one EntityDetail; this view only pages the rows.
struct TracklogEntityTrackList: View {
    let droplet: TracklogDroplet
    @ObservedObject var state: TracklogAppState
    let track: TrackHistory

    var body: some View {
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

    private var loading: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(Text("Loading listens"))
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
                    Task { await droplet.reloadEntityDetail() }
                }
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
                Button("Back") {
                    droplet.backEntityDetail()
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
                Task { await droplet.reloadEntityDetail() }
            }
            .buttonStyle(DroppyQuietButtonStyle(size: .small))
        }
        .padding(.horizontal, DroppySpacing.xl)
        .padding(.bottom, DroppySpacing.xs)
    }

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
                        await droplet.loadMoreEntityListens()
                    }
                }
            }
            .droppyFlatGlassControls()
            .scrollTargetLayout()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
