// swiftlint:disable file_length
import DroppyKit
import SwiftUI
import TracklogCore

/// The Loved section: the current connection's currently-loved tracks, read
/// fresh each time the section opens. The list never mixes accounts and never
/// claims a range total.
struct TracklogLovedView: View { // swiftlint:disable:this type_body_length
    let droplet: TracklogDroplet
    @ObservedObject var state: TracklogAppState

    var body: some View {
        VStack(spacing: 0) {
            header
            if let failure = state.lovedState.actionFailure {
                LovedNoticeBar(
                    icon: "heart.slash",
                    message: failure.message,
                    actionTitle: "Dismiss",
                    action: droplet.dismissLovedActionFailure,
                )
            }
            if let failure = state.lovedState.refreshFailure {
                refreshFailureBar(failure)
            }
            if state.lovedState.unloveUnavailableReason != nil,
               !state.lovedState.rows.isEmpty {
                actionReasonBar
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await droplet.showLoved() }
        .onDisappear { droplet.hideLoved() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: DroppySpacing.md) {
            Text("Loved")
                .font(.system(.title, design: .rounded, weight: .semibold))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .accessibilityAddTraits(.isHeader)
            if let label = state.lovedState.sourceLabel {
                Text(label)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: DroppySpacing.md)
            Button {
                Task { await droplet.refreshLoved() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(DroppyQuietButtonStyle(size: .small))
            .disabled(isRetryBlocked)
            .help("Refresh loved tracks")
            .accessibilityLabel(Text("Refresh loved tracks"))
        }
        .padding(.horizontal, DroppySpacing.xl)
        .padding(.top, DroppySpacing.lg)
        .padding(.bottom, DroppySpacing.sm)
    }

    @ViewBuilder
    private var actionReasonBar: some View {
        if let reason = state.lovedState.unloveUnavailableReason {
            LovedNoticeBar(
                icon: "heart",
                message: reason,
                actionTitle: actionRemedyTitle,
                action: openActionRemedy,
            )
        }
    }

    private func refreshFailureBar(_ failure: LovedFailure) -> some View {
        let message = LovedCopy.refreshFailure + " "
            + failureMessage(failure)
        return LovedNoticeBar(
            icon: "arrow.clockwise",
            message: message,
            actionTitle: canRetry(failure) ? "Try again" : nil,
            action: {
                Task { await droplet.refreshLoved() }
            },
        )
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch state.lovedState.phase {
        case .idle, .loading:
            loadingState
        case .ready:
            feed
        case .empty:
            emptyState
        case .metadataUnavailable:
            metadataUnavailableState
        case let .unavailable(message):
            unavailableState(message)
        case let .failed(failure):
            failedState(failure)
        }
    }

    private var loadingState: some View {
        VStack(spacing: DroppySpacing.xsm) {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(Text("Loading loved tracks"))
            Text("Loading loved tracks…")
                .font(.body)
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: DroppySpacing.xsm) {
            Text(
                state.lovedState.omitted > 0
                    ? "No loved tracks to show on \(serviceName)"
                    : "No loved tracks on \(serviceName)",
            )
            .font(.headline)
            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            if state.lovedState.omitted > 0 {
                Text(LovedCopy.omittedNote(count: state.lovedState.omitted))
                    .font(.body)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Tracks you love there appear here.")
                    .font(.body)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            }
            if state.lovedState.hasMore {
                Button("Load more loved tracks") {
                    Task { await droplet.loadMoreLoved() }
                }
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
                .disabled(isRetryBlocked)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, DroppySpacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var metadataUnavailableState: some View {
        VStack(spacing: DroppySpacing.xsm) {
            Text("Loved tracks need metadata")
                .font(.headline)
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            Text(LovedCopy.omittedOnly(service: serviceName, count: state.lovedState.omitted))
                .font(.body)
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if state.lovedState.hasMore {
                Button("Load more loved tracks") {
                    Task { await droplet.loadMoreLoved() }
                }
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
                .disabled(isRetryBlocked)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, DroppySpacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unavailableState(_ message: String) -> some View {
        VStack(spacing: DroppySpacing.xsm) {
            Text("Loved tracks unavailable")
                .font(.headline)
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            Text(message)
                .font(.body)
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Services") {
                droplet.openLovedServices()
            }
            .buttonStyle(DroppyQuietButtonStyle(size: .small))
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, DroppySpacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedState(_ failure: LovedFailure) -> some View {
        VStack(spacing: DroppySpacing.xsm) {
            Text("Loved tracks could not be loaded")
                .font(.headline)
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            Text(failureMessage(failure))
                .font(.body)
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DroppySpacing.sm) {
                if canRetry(failure) {
                    Button("Try again") {
                        Task { await droplet.refreshLoved() }
                    }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
                if failure.needsServices {
                    Button("Open Services") {
                        droplet.openLovedServices()
                    }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
                if failure.needsSettings {
                    Button("Open Settings") {
                        droplet.openLovedAppCredentials()
                    }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, DroppySpacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var feed: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                if state.lovedState.omitted > 0 {
                    Text(LovedCopy.omittedNote(count: state.lovedState.omitted))
                        .font(.caption)
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, DroppySpacing.xl)
                        .padding(.bottom, DroppySpacing.xs)
                }
                ForEach(state.lovedState.rows) { row in
                    LovedRowView(
                        row: row,
                        serviceName: serviceName,
                        canUnlove: state.lovedState.canUnlove,
                        onOpen: {
                            droplet.openEntityDetailFromLoved(row, kind: .track)
                        },
                        onOpenArtist: {
                            droplet.openEntityDetailFromLoved(row, kind: .artist)
                        },
                        onOpenAlbum: {
                            droplet.openEntityDetailFromLoved(row, kind: .album)
                        },
                        onUnlove: {
                            Task { await droplet.unloveLovedRow(row) }
                        },
                    )
                }
                footer
            }
            .droppyFlatGlassControls()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var footer: some View {
        if state.lovedState.isLoadingMore {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DroppySpacing.md)
                .accessibilityLabel(Text("Loading more loved tracks"))
        } else if let failure = state.lovedState.loadMoreFailure {
            VStack(spacing: DroppySpacing.xs) {
                Text(LovedCopy.loadMoreFailure)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                Text(failureMessage(failure))
                    .font(.caption)
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    .multilineTextAlignment(.center)
                if canRetry(failure) {
                    Button("Try again") {
                        Task { await droplet.loadMoreLoved() }
                    }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DroppySpacing.md)
        } else if state.lovedState.hasMore {
            Color.clear
                .frame(height: 1)
                .task(id: state.lovedState.rows) {
                    await droplet.loadMoreLoved()
                }
        }
    }

    // MARK: - Copy and remedies

    private var serviceName: String {
        state.currentConnection?.kind.displayName
            ?? state.lovedState.sourceLabel
            ?? "the service"
    }

    private var lastFailure: LovedFailure? {
        if case let .failed(failure) = state.lovedState.phase {
            return failure
        }
        return state.lovedState.refreshFailure ?? state.lovedState.loadMoreFailure
    }

    private var actionRemedyTitle: String? {
        if let lastFailure, case .rateLimited = lastFailure {
            return nil
        }
        return lastFailure?.needsSettings == true ? "Open Settings" : "Open Services"
    }

    private func openActionRemedy() {
        if lastFailure?.needsSettings == true {
            droplet.openLovedAppCredentials()
        } else {
            droplet.openLovedServices()
        }
    }

    private var isRetryBlocked: Bool {
        guard let deadline = state.lovedState.retryNotBefore else { return false }
        return deadline > Date()
    }

    private func canRetry(_ failure: LovedFailure) -> Bool {
        if case .rateLimited = failure {
            return !isRetryBlocked
        }
        return true
    }

    private func failureMessage(_ failure: LovedFailure) -> String {
        LovedCopy.failureMessage(
            failure,
            service: serviceName,
            retryAt: state.lovedState.retryNotBefore,
        )
    }
}

// MARK: - Row

private struct LovedRowView: View {
    let row: LovedRow
    let serviceName: String
    let canUnlove: Bool
    let onOpen: () -> Void
    let onOpenArtist: () -> Void
    let onOpenAlbum: () -> Void
    let onUnlove: () -> Void

    var body: some View {
        HStack(spacing: DroppySpacing.md) {
            Button(action: onOpen) {
                info
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityLabel(Text(rowLabel))
            .accessibilityValue(Text("Loved on \(serviceName)"))
            .accessibilityHint(Text("Opens this track's page"))
            .accessibilityActions {
                if !row.artist.isEmpty {
                    Button("Open artist", action: onOpenArtist)
                }
                if !row.album.isEmpty {
                    Button("Open album", action: onOpenAlbum)
                }
            }
            .contextMenu {
                Button("Open track", action: onOpen)
                if !row.artist.isEmpty {
                    Button("Open artist", action: onOpenArtist)
                }
                if !row.album.isEmpty {
                    Button("Open album", action: onOpenAlbum)
                }
            }
            Spacer(minLength: DroppySpacing.sm)
            if canUnlove {
                Button(action: onUnlove) {
                    Image(systemName: "heart.fill")
                        .font(.system(.body, design: .default, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(DroppyCircleButtonStyle(size: 24))
                .help("Unlove \(row.title)")
                .accessibilityLabel(Text("Unlove \(row.title)"))
                .accessibilityHint(
                    Text("Removes the love on \(serviceName) and every connected service that supports love."),
                )
            }
        }
        .padding(.horizontal, DroppySpacing.xl)
        .frame(height: 68)
        .contentShape(Rectangle())
    }

    private var info: some View {
        HStack(spacing: DroppySpacing.md) {
            ArtworkSleeve(size: 52, artwork: nil, identity: row.id)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .lineLimit(1)
                if !row.artist.isEmpty {
                    Text(row.artist)
                        .font(.subheadline)
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        .lineLimit(1)
                }
                if !row.album.isEmpty {
                    Text(row.album)
                        .font(.caption)
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                        .lineLimit(1)
                }
            }
        }
    }

    private var rowLabel: String {
        [row.title, row.artist, row.album]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

// MARK: - Notice bar

private struct LovedNoticeBar: View {
    let icon: String
    let message: String
    let actionTitle: String?
    let action: () -> Void
    @Environment(\.colorSchemeContrast) private var colorContrast

    var body: some View {
        HStack(spacing: DroppySpacing.md) {
            Image(systemName: icon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DroppySpacing.sm)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
            }
        }
        .padding(.horizontal, DroppySpacing.lg)
        .padding(.vertical, DroppySpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DroppyRadius.ms, style: .continuous)
                .fill(AdaptiveColors.overlayAuto(0.08)),
        )
        .overlay {
            if SurfaceContrast.isIncreased(colorContrast) {
                RoundedRectangle(cornerRadius: DroppyRadius.ms, style: .continuous)
                    .stroke(AdaptiveColors.contrastTintAuto.opacity(0.32), lineWidth: 1)
            }
        }
        .padding(.horizontal, DroppySpacing.xl)
        .padding(.bottom, DroppySpacing.xs)
    }
}
