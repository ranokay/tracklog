import DroppyKit
import SwiftUI
import TracklogCore

/// The Sleeve shelf widget. Solo and paired are separate compositions; both
/// draw directly on the shelf with one host inset at the root.
struct TracklogWidget: View {
    let droplet: TracklogDroplet
    @ObservedObject var state: TracklogAppState
    let context: ShelfWidgetContext
    @Environment(\.colorSchemeContrast) private var colorContrast

    var body: some View {
        Group {
            if context.isPaired {
                paired
            } else {
                solo
            }
        }
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(TracklogMotion.stateAnimation, value: phaseKey)
        .onAppear { TracklogMotion.logReducedPathOnce() }
    }

    private var phaseKey: String {
        switch phase {
        case let .playing(sample): "playing.\(sample.track.identity)"
        case let .paused(until): "paused.\(until.timeIntervalSince1970)"
        case .offWithoutConnections: "off.connect"
        case .off: "off"
        case .historyUnavailable: "history"
        case .feedUnavailable: "feed"
        case .idle: "idle"
        }
    }

    // MARK: - Phase

    enum Phase {
        case playing(MediaSample)
        case paused(Date)
        case offWithoutConnections
        case off
        case historyUnavailable
        case feedUnavailable
        case idle
    }

    var phase: Phase {
        if !state.scrobblingEnabled {
            return state.connections.isEmpty ? .offWithoutConnections : .off
        }
        if let until = state.pausedUntil {
            return .paused(until)
        }
        if !state.captureAvailable {
            return .historyUnavailable
        }
        if !state.feedAvailable {
            return .feedUnavailable
        }
        if let sample = state.nowPlaying {
            return .playing(sample)
        }
        return .idle
    }

    // MARK: - Solo

    private var solo: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xsm) {
            soloHeader
            if SurfaceContrast.isIncreased(colorContrast) {
                SurfaceSeparator()
            }
            switch phase {
            case let .playing(sample):
                soloPlaying(sample)
            case let .paused(until):
                stateBlock(
                    title: "Paused",
                    subtitle: "Resumes at \(clockTime(until))",
                    actionTitle: "Resume",
                    action: { droplet.resumeCapture() },
                )
            case .offWithoutConnections:
                stateBlock(
                    title: "Connect a service",
                    subtitle: "Choose one in Tracklog settings.",
                )
            case .off:
                stateBlock(
                    title: "Scrobbling is off",
                    subtitle: "Turn it on in Tracklog settings.",
                )
            case .historyUnavailable:
                stateBlock(
                    title: "History unavailable",
                    subtitle: "Tracklog cannot save listens right now.",
                )
            case .feedUnavailable:
                stateBlock(
                    title: "Media feed unavailable",
                    subtitle: "Playback will not be scrobbled.",
                )
            case .idle:
                stateBlock(
                    title: "Nothing playing",
                    subtitle: "Play something to start scrobbling.",
                )
            }
        }
    }

    private var soloHeader: some View {
        HStack(spacing: DroppySpacing.xsm) {
            Image(systemName: "waveform")
                .font(.system(.caption, design: .default, weight: .medium))
                .accessibilityHidden(true)
            Text("Tracklog")
                .font(.system(.callout, design: .default, weight: .semibold))
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            queueButton
            overflowMenu
        }
        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
    }
}
