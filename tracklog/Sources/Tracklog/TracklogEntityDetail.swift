// swiftlint:disable file_length
import DroppyKit
import SwiftUI
import TracklogCore

// One entity detail page inside the takeover. It replaces the current
// section's list; Back returns to the page it came from, or to the list when
// this is the first page.
// swiftlint:disable:next type_body_length
struct TracklogEntityDetailView: View {
    let droplet: TracklogDroplet
    @ObservedObject var state: TracklogAppState
    let detail: EntityDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let pending = state.pendingListenDelete {
                HistoryDeleteBar(
                    listen: pending,
                    deliveries: state.deliveries(for: pending),
                    connections: state.connections,
                    isDeleting: state.deletingListen,
                    failure: state.deleteListenFailure,
                    onCancel: { droplet.cancelDeleteListen() },
                    onDelete: {
                        Task { await droplet.confirmDeleteListen() }
                    },
                )
            }
            if let error = state.imageOverrideError {
                imageErrorBar(error)
            }
            localSection
            if detail.request.kind == .track, let track = detail.track {
                TracklogEntityTrackList(droplet: droplet, state: state, track: track)
                    .frame(maxHeight: .infinity)
            } else {
                topTracks
                    .frame(maxHeight: .infinity)
            }
            serviceSection
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DroppySpacing.md) {
                Button {
                    droplet.backEntityDetail()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
                .accessibilityLabel(Text("Back"))
                Spacer(minLength: DroppySpacing.md)
                Text(EntityDetailCopy.localCount(detail.local.count))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .monospacedDigit()
            }

            HStack(alignment: .top, spacing: DroppySpacing.md) {
                ArtworkSleeve(
                    size: 84,
                    artwork: detail.imageData,
                    identity: detail.request.key,
                    isCircular: detail.request.kind == .artist,
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(detail.title)
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                        .lineLimit(2)
                        .accessibilityAddTraits(.isHeader)
                    if !detail.subtitle.isEmpty {
                        Text(detail.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            .lineLimit(2)
                    }
                    if detail.isApproximateImage {
                        Text("Approximate artist image")
                            .font(.caption)
                            .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    }
                    if detail.overrideIsUnreadable {
                        Text("The saved image could not be read. Choose another or remove it.")
                            .font(.caption)
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    }
                    listenRange
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                imageActions
            }
        }
        .padding(.horizontal, DroppySpacing.xl)
        .padding(.top, DroppySpacing.sm)
        .padding(.bottom, DroppySpacing.xs)
    }

    @ViewBuilder
    private var listenRange: some View {
        if let first = detail.local.firstListenedAt {
            Text(EntityDetailCopy.firstListen(first))
                .font(.caption)
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
        }
        if let last = detail.local.lastListenedAt {
            Text(EntityDetailCopy.lastListen(last))
                .font(.caption)
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
        }
    }

    @ViewBuilder
    private var imageActions: some View {
        if detail.canChangeImage {
            VStack(alignment: .trailing, spacing: DroppySpacing.xs) {
                Button("Change image…") {
                    droplet.beginImageOverride(for: detail)
                }
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
                if detail.canRemoveImage {
                    Button("Remove", role: .destructive) {
                        droplet.removeDetailImage(detail)
                    }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
            }
        }
    }

    private func imageErrorBar(_ message: String) -> some View {
        HStack(spacing: DroppySpacing.sm) {
            Image(systemName: "exclamationmark.circle")
                .font(.caption.weight(.semibold))
                .accessibilityHidden(true)
            Text(message)
                .font(.caption)
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DroppySpacing.sm)
            Button("Dismiss") {
                droplet.dismissImageOverrideError()
            }
            .buttonStyle(DroppyQuietButtonStyle(size: .small))
        }
        .padding(.horizontal, DroppySpacing.xl)
        .padding(.bottom, DroppySpacing.xs)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Local section

    @ViewBuilder
    private var localSection: some View {
        if let failure = detail.localFailure, detail.local.count == 0 {
            localFailure(failure)
        } else if detail.isLoadingLocal, detail.local.count == 0 {
            HStack(spacing: DroppySpacing.sm) {
                ProgressView()
                    .controlSize(.mini)
                Text("Reading this Mac's history…")
                    .font(.caption)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            }
            .padding(.horizontal, DroppySpacing.xl)
            .padding(.vertical, DroppySpacing.xs)
            .accessibilityElement(children: .combine)
        } else {
            HStack(spacing: DroppySpacing.md) {
                Label("On this Mac", systemImage: "internaldrive")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                if detail.local.count == 0 {
                    Text(EntityDetailCopy.emptyLocal(kind: detail.request.kind))
                        .font(.caption)
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                }
                Spacer(minLength: DroppySpacing.sm)
            }
            .padding(.horizontal, DroppySpacing.xl)
            .padding(.bottom, DroppySpacing.xs)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(localAccessibilityLabel))

            if let failure = detail.localFailure {
                localFailure(failure)
            }
        }
    }

    private var localAccessibilityLabel: String {
        var parts = ["On this Mac", EntityDetailCopy.localCount(detail.local.count)]
        if let first = detail.local.firstListenedAt {
            parts.append(EntityDetailCopy.firstListen(first))
        }
        if let last = detail.local.lastListenedAt {
            parts.append(EntityDetailCopy.lastListen(last))
        }
        if detail.local.count == 0 {
            parts.append(EntityDetailCopy.emptyLocal(kind: detail.request.kind))
        }
        return parts.joined(separator: ". ")
    }

    private func localFailure(_ failure: CaptureFailure) -> some View {
        HStack(spacing: DroppySpacing.sm) {
            Text("This Mac's history could not be read. \(failure.message)")
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

    // MARK: - Top tracks

    @ViewBuilder
    private var topTracks: some View {
        if detail.request.kind != .track {
            if detail.local.topTracks.isEmpty {
                Spacer(minLength: 0)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text(EntityDetailCopy.topTracksTitle(kind: detail.request.kind))
                        .font(.headline)
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                        .padding(.horizontal, DroppySpacing.xl)
                        .padding(.top, DroppySpacing.xs)
                        .padding(.bottom, DroppySpacing.xs)
                        .accessibilityAddTraits(.isHeader)
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(detail.local.topTracks) { item in
                                Button {
                                    pushTrack(item)
                                } label: {
                                    topTrackRow(item)
                                }
                                .buttonStyle(.plain)
                                .contentShape(Rectangle())
                                .accessibilityLabel(Text(topTrackLabel(item)))
                                .accessibilityHint(Text("Opens this track's page"))
                                .id(item.id)
                            }
                        }
                        .droppyFlatGlassControls()
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func pushTrack(_ item: ChartItem) {
        guard let request = EntityRequest.chartItem(item, type: .tracks) else { return }
        droplet.pushEntityDetail(request)
    }

    private func topTrackRow(_ item: ChartItem) -> some View {
        HStack(spacing: DroppySpacing.md) {
            Text("\(item.rank)")
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                .frame(width: 22, alignment: .trailing)
                .accessibilityHidden(true)
            ArtworkSleeve(
                size: 36,
                artwork: item.artworkHash.flatMap { state.artworkByHash[$0] },
                identity: item.identityKey,
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: DroppySpacing.sm)
            Text(EntityDetailCopy.localCount(item.count))
                .font(.caption)
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                .monospacedDigit()
                .accessibilityHidden(true)
        }
        .padding(.horizontal, DroppySpacing.xl)
        .frame(height: 52)
    }

    private func topTrackLabel(_ item: ChartItem) -> String {
        [item.title, item.subtitle, EntityDetailCopy.localCount(item.count)]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    // MARK: - Service section

    private var serviceSection: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xs) {
            HStack(spacing: DroppySpacing.sm) {
                Text(serviceHeading)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: DroppySpacing.sm)
                if case .loading = detail.service {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel(Text("Loading service details"))
                }
            }
            serviceContent
        }
        .padding(.horizontal, DroppySpacing.xl)
        .padding(.top, DroppySpacing.xs)
        .padding(.bottom, DroppySpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DroppyRadius.ms, style: .continuous)
                .fill(AdaptiveColors.overlayAuto(0.04)),
        )
        .padding(.horizontal, DroppySpacing.sm)
        .padding(.bottom, DroppySpacing.xs)
    }

    private var serviceHeading: String {
        guard let connection = state.currentConnection else {
            return "Service details · no connection"
        }
        return "\(connection.kind.displayName) · \(connection.displayName)"
    }

    @ViewBuilder
    private var serviceContent: some View {
        switch detail.service {
        case .loading:
            Text("Loading service details…")
                .font(.caption)
                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
        case let .facts(facts):
            factsView(facts)
        case let .missing(message):
            Text(message)
                .font(.caption)
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        case let .unavailable(message):
            VStack(alignment: .leading, spacing: DroppySpacing.xs) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                listenBrainzLink
            }
        case let .failed(failure):
            HStack(spacing: DroppySpacing.sm) {
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DroppySpacing.sm)
                if failure.needsSettings {
                    Button("Settings") {
                        droplet.openLastFMAppCredentialsPageFromDetail()
                    }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
                Button("Try again") {
                    Task { await droplet.retryEntityService() }
                }
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
            }
        }
    }

    private func factsView(_ facts: EntityServiceFacts) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(facts.facts.enumerated()), id: \.offset) { _, fact in
                HStack(alignment: .firstTextBaseline, spacing: DroppySpacing.sm) {
                    Text(fact.label)
                        .font(.caption)
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                        .frame(width: 150, alignment: .leading)
                    Text(fact.value)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        .monospacedDigit()
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: DroppySpacing.sm) {
                if let link = facts.link {
                    Button("Open on \(facts.serviceName)") {
                        droplet.openServiceLink(link)
                    }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
                listenBrainzLink
            }
            .padding(.top, DroppySpacing.xs)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var listenBrainzLink: some View {
        if state.currentConnection?.kind == .listenBrainz,
           let url = EntityServiceCopy.listenBrainzLink(
               kind: detail.request.kind,
               providerID: detail.request.providerID,
           ) {
            Button("Open on ListenBrainz") {
                droplet.openListenBrainzLink(url)
            }
            .buttonStyle(DroppyQuietButtonStyle(size: .small))
        }
    }
}
