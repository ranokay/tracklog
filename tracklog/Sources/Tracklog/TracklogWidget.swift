import DroppyKit
import SwiftUI
import TracklogCore

/// The shelf card in the three directions. Solo and paired are separate
/// compositions, as the host requires; both draw straight on the shelf black.
struct TracklogWidget: View {
    @ObservedObject var droplet: TracklogDroplet
    let context: ShelfWidgetContext

    var body: some View {
        Group {
            switch ProtoConfig.variant {
            case .ledger:
                LedgerWidget(context: context, state: ProtoConfig.state)
            case .sleeve:
                SleeveWidget(context: context, state: ProtoConfig.state)
            case .gutter:
                GutterWidget(context: context, state: ProtoConfig.state)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(context.contentInsets)
    }
}

// MARK: - Ledger

private struct LedgerWidget: View {
    let context: ShelfWidgetContext
    let state: ProtoState

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xsm) {
            header
            if context.isPaired {
                paired
            } else {
                solo
            }
        }
    }

    private var header: some View {
        HStack(spacing: DroppySpacing.xsm) {
            Image(systemName: "waveform")
                .font(.system(size: 12, weight: .medium))
            Text("Tracklog")
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)
            if state != .idle {
                ProtoQueueBadge(compact: context.isPaired)
            }
            ProtoOverflowMenu(size: 20)
        }
        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
    }

    private var solo: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xsm) {
            switch state {
            case .playing:
                HStack(alignment: .top, spacing: DroppySpacing.md) {
                    ProtoArtwork(hue: ProtoData.nowPlaying.hue, size: 84)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(ProtoData.nowPlaying.title)
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                            .lineLimit(2)
                            .minimumScaleFactor(0.9)
                        Text("\(ProtoData.nowPlaying.artist) · \(ProtoData.nowPlaying.album)")
                            .font(.system(size: 12))
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        ProtoProgress(value: ProtoData.nowPlaying.progress)
                        HStack(spacing: DroppySpacing.xsm) {
                            Text("Scrobbling in \(ProtoData.nowPlaying.remaining)")
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            Spacer(minLength: DroppySpacing.xsm)
                            ProtoLoveButton(size: 20)
                        }
                    }
                }
                servicesLine
            case .paused:
                titleBlock("Paused")
                subtitle("Scrobbling resumes at 15:42.")
                Button("Resume") {}
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
            case .off:
                titleBlock("Scrobbling is off")
                subtitle("Your listening isn't being saved.")
                HStack(spacing: DroppySpacing.xsm) {
                    Button("Turn on") {}
                        .buttonStyle(DroppyAccentButtonStyle(size: .small))
                    Spacer(minLength: 0)
                    Button("Settings") {}
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
            case .idle:
                titleBlock("Nothing playing")
                subtitle("Play something to start scrobbling.")
                Spacer(minLength: 0)
            }
        }
    }

    private var paired: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xsm) {
            switch state {
            case .playing:
                HStack(alignment: .top, spacing: DroppySpacing.sm) {
                    ProtoArtwork(hue: ProtoData.nowPlaying.hue, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ProtoData.nowPlaying.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                            .lineLimit(2)
                        Text(ProtoData.nowPlaying.remaining)
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: DroppySpacing.xsm) {
                    Text("Scrobbling")
                        .font(.system(size: 10))
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    Spacer(minLength: 0)
                    ProtoLoveButton(size: 20)
                }
            case .paused:
                titleBlock("Paused")
                subtitle("Resumes at 15:42.")
                Button("Resume") {}
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
            case .off:
                titleBlock("Scrobbling is off")
                Button("Turn on") {}
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
            case .idle:
                titleBlock("Nothing playing")
                Spacer(minLength: 0)
            }
        }
    }

    private var servicesLine: some View {
        Text("Last.fm · ListenBrainz · Libre.fm")
            .font(.system(size: 9))
            .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            .lineLimit(1)
    }

    private func titleBlock(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 20, weight: .semibold, design: .rounded))
            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            .lineLimit(1)
    }

    private func subtitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            .lineLimit(2)
    }
}

// MARK: - Sleeve

private struct SleeveWidget: View {
    let context: ShelfWidgetContext
    let state: ProtoState

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            header
            if context.isPaired {
                paired
            } else {
                solo
            }
        }
    }

    private var header: some View {
        HStack(spacing: DroppySpacing.xsm) {
            Image(systemName: "waveform")
                .font(.system(size: 12, weight: .medium))
            Text("Tracklog")
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)
            if state != .idle {
                ProtoQueueBadge(compact: context.isPaired)
            }
            ProtoOverflowMenu(size: 20)
        }
        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
    }

    private var solo: some View {
        Group {
            switch state {
            case .playing:
                HStack(alignment: .top, spacing: DroppySpacing.mdl) {
                    ProtoArtwork(hue: ProtoData.nowPlaying.hue, size: 92)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ProtoData.nowPlaying.title)
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                            .lineLimit(2)
                            .minimumScaleFactor(0.9)
                        Text(ProtoData.nowPlaying.artist)
                            .font(.system(size: 13))
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            .lineLimit(1)
                        Text(ProtoData.nowPlaying.album)
                            .font(.system(size: 11))
                            .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        ProtoProgress(value: ProtoData.nowPlaying.progress)
                        HStack(spacing: DroppySpacing.xsm) {
                            Text("Scrobbling in \(ProtoData.nowPlaying.remaining)")
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            Spacer(minLength: DroppySpacing.xsm)
                            ProtoLoveButton(size: 20)
                        }
                    }
                }
            case .paused:
                titleBlock("Paused")
                subtitle("Scrobbling resumes at 15:42.")
                Button("Resume") {}
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
            case .off:
                titleBlock("Scrobbling is off")
                subtitle("Your listening isn't being saved.")
                HStack(spacing: DroppySpacing.xsm) {
                    Button("Turn on") {}
                        .buttonStyle(DroppyAccentButtonStyle(size: .small))
                    Spacer(minLength: 0)
                    Button("Settings") {}
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
            case .idle:
                titleBlock("Nothing playing")
                subtitle("Play something to start scrobbling.")
                Spacer(minLength: 0)
            }
        }
    }

    private var paired: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xsm) {
            switch state {
            case .playing:
                HStack(alignment: .top, spacing: DroppySpacing.sm) {
                    ProtoArtwork(hue: ProtoData.nowPlaying.hue, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ProtoData.nowPlaying.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                            .lineLimit(2)
                        Text(ProtoData.nowPlaying.artist)
                            .font(.system(size: 11))
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: DroppySpacing.xsm) {
                    Text(ProtoData.nowPlaying.remaining)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    Spacer(minLength: 0)
                    ProtoLoveButton(size: 20)
                }
            case .paused:
                titleBlock("Paused")
                subtitle("Resumes at 15:42.")
                Button("Resume") {}
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
            case .off:
                titleBlock("Scrobbling is off")
                Button("Turn on") {}
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
            case .idle:
                titleBlock("Nothing playing")
                Spacer(minLength: 0)
            }
        }
    }

    private func titleBlock(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 20, weight: .semibold, design: .rounded))
            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            .lineLimit(1)
    }

    private func subtitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            .lineLimit(2)
    }
}

// MARK: - Gutter

private struct GutterWidget: View {
    let context: ShelfWidgetContext
    let state: ProtoState

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            header
            if context.isPaired {
                paired
            } else {
                solo
            }
        }
    }

    private var header: some View {
        HStack(spacing: DroppySpacing.xsm) {
            Image(systemName: "waveform")
                .font(.system(size: 12, weight: .medium))
            Text("Tracklog")
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)
            if state != .idle {
                ProtoQueueBadge(compact: context.isPaired)
            }
            ProtoOverflowMenu(size: 20)
        }
        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
    }

    private var solo: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xsm) {
            switch state {
            case .playing:
                HStack(alignment: .top, spacing: DroppySpacing.md) {
                    ProtoArtwork(hue: ProtoData.nowPlaying.hue, size: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ProtoData.nowPlaying.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                            .lineLimit(1)
                        Text(ProtoData.nowPlaying.artist)
                            .font(.system(size: 12))
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            .lineLimit(1)
                        Text("\(ProtoData.pendingCount) waiting")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.orange.opacity(0.9))
                    }
                    Spacer(minLength: DroppySpacing.xsm)
                    Text(ProtoData.nowPlaying.remaining)
                        .font(.system(size: 18, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                }
                ProtoProgress(value: ProtoData.nowPlaying.progress)
                HStack {
                    Text("\(ProtoData.nowPlaying.elapsed) elapsed")
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    Spacer(minLength: 0)
                    ProtoLoveButton(size: 20)
                }
            case .paused:
                HStack {
                    titleBlock("Paused")
                    Spacer(minLength: 0)
                    Button("Resume") {}
                        .buttonStyle(DroppyAccentButtonStyle(size: .small))
                }
                subtitle("Scrobbling resumes at 15:42.")
            case .off:
                titleBlock("Scrobbling is off")
                subtitle("Your listening isn't being saved.")
                HStack(spacing: DroppySpacing.xsm) {
                    Button("Turn on") {}
                        .buttonStyle(DroppyAccentButtonStyle(size: .small))
                    Spacer(minLength: 0)
                    Button("Settings") {}
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
            case .idle:
                titleBlock("Nothing playing")
                subtitle("Play something to start scrobbling.")
                Spacer(minLength: 0)
            }
        }
    }

    private var paired: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xsm) {
            switch state {
            case .playing:
                Text(ProtoData.nowPlaying.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .lineLimit(2)
                HStack(alignment: .firstTextBaseline) {
                    Text(ProtoData.nowPlaying.remaining)
                        .font(.system(size: 20, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    Spacer(minLength: 0)
                    ProtoLoveButton(size: 20)
                }
                Spacer(minLength: 0)
                Text("\(ProtoData.pendingCount) waiting")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.orange.opacity(0.9))
            case .paused:
                titleBlock("Paused")
                subtitle("Resumes at 15:42.")
                Button("Resume") {}
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
            case .off:
                titleBlock("Scrobbling is off")
                Button("Turn on") {}
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
            case .idle:
                titleBlock("Nothing playing")
                Spacer(minLength: 0)
            }
        }
    }

    private func titleBlock(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 20, weight: .semibold, design: .rounded))
            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            .lineLimit(1)
    }

    private func subtitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            .lineLimit(2)
    }
}
