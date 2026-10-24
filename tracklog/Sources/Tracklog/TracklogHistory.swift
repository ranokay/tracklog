import DroppyKit
import SwiftUI

/// The takeover in the three directions. Only History exists in this
/// milestone, so no section bar is drawn; the strip is the pinned player bar.
struct TracklogTakeover: View {
    let variant: ProtoVariant
    let state: ProtoState

    var body: some View {
        Group {
            switch variant {
            case .ledger: LedgerTakeover(state: state)
            case .sleeve: SleeveTakeover(state: state)
            case .gutter: GutterTakeover(state: state)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Ledger

/// Dense, text-first, system-utility. The feed is the point; artwork is a
/// 32pt label, not a subject.
private struct LedgerTakeover: View {
    let state: ProtoState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("History")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                Spacer(minLength: DroppySpacing.sm)
                Text("\(ProtoData.listenCount) listens")
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            }
            .padding(.bottom, DroppySpacing.md)

            LedgerBanner()
                .padding(.bottom, DroppySpacing.sm)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(ProtoData.days) { day in
                        Text(day.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                            .padding(.top, DroppySpacing.mdl)
                            .padding(.bottom, DroppySpacing.xs)
                        ForEach(day.listens) { listen in
                            LedgerRow(listen: listen)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            LedgerStrip(state: state)
                .padding(.top, DroppySpacing.md)
        }
        .padding(.horizontal, DroppySpacing.xxl)
        .padding(.top, DroppySpacing.xl)
        .padding(.bottom, DroppySpacing.lg)
    }
}

private struct LedgerRow: View {
    let listen: ProtoListen
    @State private var hovered = false

    var body: some View {
        HStack(spacing: DroppySpacing.smd) {
            ProtoArtwork(hue: listen.hue, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(listen.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(listen.artist)
                    .font(.system(size: 12))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: DroppySpacing.sm)
            Text(listen.time)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            ProtoDeliveryMark(state: listen.delivery)
        }
        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        .padding(.horizontal, DroppySpacing.sm)
        .frame(height: 48)
        .background(
            RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous)
                .fill(hovered ? AdaptiveColors.notchSurfaceCardFill : .clear)
        )
        .padding(.horizontal, -DroppySpacing.sm)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}

private struct LedgerBanner: View {
    var body: some View {
        HStack(spacing: DroppySpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.orange.opacity(0.9))
            Text("\(ProtoData.pendingCount) listens waiting")
                .font(.system(size: 12, weight: .semibold))
            Text("Last.fm rate limited")
                .font(.system(size: 11))
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            Spacer(minLength: DroppySpacing.sm)
            Button("Review") {}
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
        }
        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        .padding(.horizontal, DroppySpacing.smd)
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: DroppyRadius.ms, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
    }
}

private struct LedgerStrip: View {
    let state: ProtoState
    @State private var cancelled = false

    var body: some View {
        Group {
            if state == .idle {
                EmptyView()
            } else if state == .off {
                ProtoOffBar()
            } else if cancelled {
                cancelledBar
            } else {
                HStack(spacing: DroppySpacing.smd) {
                    ProtoArtwork(hue: ProtoData.nowPlaying.hue, size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ProtoData.nowPlaying.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text("\(ProtoData.nowPlaying.artist) · \(ProtoData.nowPlaying.album)")
                            .font(.system(size: 11))
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: DroppySpacing.sm)
                    if state == .paused {
                        Text("Paused")
                            .font(.system(size: 11))
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        Button("Resume") {}
                            .buttonStyle(DroppyAccentButtonStyle(size: .small))
                    } else {
                        Text(ProtoData.nowPlaying.remaining)
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        ProtoLoveButton(size: 20)
                        Button {
                            cancelled = true
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        }
                        .buttonStyle(DroppyCircleButtonStyle(size: 20))
                        .help("Cancel now playing")
                        ProtoOverflowMenu(size: 20)
                    }
                }
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .padding(.horizontal, DroppySpacing.sm)
                .padding(.top, DroppySpacing.sm)
                .padding(.bottom, DroppySpacing.xsm)
                .overlay(alignment: .bottom) {
                    ProtoProgress(value: ProtoData.nowPlaying.progress)
                        .padding(.horizontal, DroppySpacing.sm)
                        .padding(.bottom, DroppySpacing.xs)
                }
                .background(
                    RoundedRectangle(cornerRadius: DroppyRadius.medium, style: .continuous)
                        .fill(AdaptiveColors.notchSurfaceCardFill)
                )
            }
        }
    }

    private var cancelledBar: some View {
        HStack(spacing: DroppySpacing.sm) {
            Image(systemName: "xmark.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            Text("Tracking cancelled")
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: DroppySpacing.sm)
            Button("Undo") { cancelled = false }
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
        }
        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        .padding(.horizontal, DroppySpacing.smd)
        .padding(.vertical, DroppySpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DroppyRadius.medium, style: .continuous)
                .fill(AdaptiveColors.notchSurfaceCardFill)
        )
    }
}

// MARK: - Sleeve

/// Art-first and airy: the takeover reads like a small music app, with room
/// for album names and a strip tall enough to carry a sleeve.
private struct SleeveTakeover: View {
    let state: ProtoState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("History")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                Spacer(minLength: DroppySpacing.sm)
                Text("\(ProtoData.listenCount) listens")
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            }
            .padding(.bottom, DroppySpacing.lg)

            SleeveBanner()
                .padding(.bottom, DroppySpacing.smd)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(ProtoData.days) { day in
                        HStack(alignment: .firstTextBaseline) {
                            Text(day.title)
                                .font(.system(size: 19, weight: .semibold, design: .rounded))
                                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                            Spacer(minLength: DroppySpacing.sm)
                            Text("\(day.listens.count) listens")
                                .font(.system(size: 10))
                                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                        }
                        .padding(.top, DroppySpacing.xl)
                        .padding(.bottom, DroppySpacing.sm)

                        ForEach(day.listens) { listen in
                            SleeveRow(listen: listen)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            SleeveStrip(state: state)
                .padding(.top, DroppySpacing.mdl)
        }
        .padding(.horizontal, DroppySpacing.xxl)
        .padding(.top, DroppySpacing.xl)
        .padding(.bottom, DroppySpacing.lg)
    }
}

private struct SleeveRow: View {
    let listen: ProtoListen
    @State private var hovered = false

    var body: some View {
        HStack(spacing: DroppySpacing.mdl) {
            ProtoArtwork(hue: listen.hue, size: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(listen.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(listen.artist)
                    .font(.system(size: 13))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .lineLimit(1)
                Text(listen.album)
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: DroppySpacing.sm)
            VStack(alignment: .trailing, spacing: 4) {
                Text(listen.time)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                ProtoDeliveryMark(state: listen.delivery)
            }
        }
        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        .padding(.horizontal, DroppySpacing.sm)
        .frame(height: 68)
        .background(
            RoundedRectangle(cornerRadius: DroppyRadius.medium, style: .continuous)
                .fill(hovered ? AdaptiveColors.notchSurfaceCardFill : .clear)
        )
        .padding(.horizontal, -DroppySpacing.sm)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}

private struct SleeveBanner: View {
    var body: some View {
        HStack(spacing: DroppySpacing.md) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.16))
                    .frame(width: 28, height: 28)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.orange.opacity(0.95))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("\(ProtoData.pendingCount) listens waiting")
                    .font(.system(size: 13, weight: .semibold))
                Text("Last.fm is rate limited; retrying in 2 minutes.")
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            }
            Spacer(minLength: DroppySpacing.sm)
            Button("Review") {}
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
        }
        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        .padding(.horizontal, DroppySpacing.md)
        .padding(.vertical, DroppySpacing.smd)
        .background(
            RoundedRectangle(cornerRadius: DroppyRadius.ml, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
    }
}

private struct SleeveStrip: View {
    let state: ProtoState
    @State private var cancelled = false

    var body: some View {
        Group {
            if state == .idle {
                EmptyView()
            } else if state == .off {
                ProtoOffBar()
            } else if cancelled {
                HStack(spacing: DroppySpacing.sm) {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    Text("Tracking cancelled")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: DroppySpacing.sm)
                    Button("Undo") { cancelled = false }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .padding(.horizontal, DroppySpacing.md)
                .padding(.vertical, DroppySpacing.smd)
                .background(
                    RoundedRectangle(cornerRadius: DroppyRadius.ml, style: .continuous)
                        .fill(AdaptiveColors.notchSurfaceCardFill)
                )
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: DroppySpacing.md) {
                        ProtoArtwork(hue: ProtoData.nowPlaying.hue, size: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ProtoData.nowPlaying.title)
                                .font(.system(size: 15, weight: .semibold))
                                .lineLimit(1)
                            Text(ProtoData.nowPlaying.artist)
                                .font(.system(size: 12))
                                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                                .lineLimit(1)
                            Text("\(ProtoData.nowPlaying.elapsed) elapsed")
                                .font(.system(size: 11))
                                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                        }
                        Spacer(minLength: DroppySpacing.sm)
                        if state == .paused {
                            Text("Paused")
                                .font(.system(size: 11))
                                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            Button("Resume") {}
                                .buttonStyle(DroppyAccentButtonStyle(size: .small))
                        } else {
                            ProtoLoveButton(size: 24)
                            Button {
                                cancelled = true
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            }
                            .buttonStyle(DroppyCircleButtonStyle(size: 22))
                            .help("Cancel now playing")
                            ProtoOverflowMenu(size: 22)
                        }
                    }
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .padding(.horizontal, DroppySpacing.md)
                    .padding(.top, DroppySpacing.md)
                    .padding(.bottom, DroppySpacing.smd)

                    ProtoProgress(value: ProtoData.nowPlaying.progress, height: 3)
                        .padding(.horizontal, DroppySpacing.md)
                        .padding(.bottom, DroppySpacing.md)
                }
                .background(
                    RoundedRectangle(cornerRadius: DroppyRadius.ml, style: .continuous)
                        .fill(AdaptiveColors.notchSurfaceCardFill)
                )
            }
        }
    }
}

// MARK: - Gutter

/// A chronological ledger: the time column does the scanning, rows stay low,
/// and the widget splits now playing from queue state.
private struct GutterTakeover: View {
    let state: ProtoState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("History")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                Spacer(minLength: DroppySpacing.sm)
                Text("\(ProtoData.listenCount) listens")
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            }
            .padding(.bottom, DroppySpacing.smd)

            GutterBanner()
                .padding(.bottom, DroppySpacing.sm)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(ProtoData.days) { day in
                        HStack(spacing: DroppySpacing.smd) {
                            Circle()
                                .fill(AdaptiveColors.notchSurfaceTertiaryText)
                                .frame(width: 3, height: 3)
                            Text(day.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, 40)
                        .padding(.top, DroppySpacing.md)
                        .padding(.bottom, DroppySpacing.xs)

                        ForEach(day.listens) { listen in
                            GutterRow(listen: listen)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            GutterStrip(state: state)
                .padding(.top, DroppySpacing.smd)
        }
        .padding(.horizontal, DroppySpacing.xxl)
        .padding(.top, DroppySpacing.xl)
        .padding(.bottom, DroppySpacing.lg)
    }
}

private struct GutterRow: View {
    let listen: ProtoListen
    @State private var hovered = false

    var body: some View {
        HStack(spacing: DroppySpacing.smd) {
            Text(listen.time)
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                .frame(width: 40, alignment: .trailing)
            ProtoArtwork(hue: listen.hue, size: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text(listen.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(listen.artist)
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: DroppySpacing.sm)
            ProtoDeliveryMark(state: listen.delivery)
        }
        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        .padding(.horizontal, DroppySpacing.sm)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous)
                .fill(hovered ? AdaptiveColors.notchSurfaceCardFill : .clear)
        )
        .padding(.horizontal, -DroppySpacing.sm)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}

private struct GutterBanner: View {
    var body: some View {
        HStack(spacing: DroppySpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.orange.opacity(0.9))
            Text("\(ProtoData.pendingCount) waiting")
                .font(.system(size: 12, weight: .semibold))
            Text("Last.fm rate limited")
                .font(.system(size: 11))
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            Spacer(minLength: DroppySpacing.sm)
            Button("Review") {}
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
        }
        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        .padding(.horizontal, DroppySpacing.smd)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
    }
}

private struct GutterStrip: View {
    let state: ProtoState
    @State private var cancelled = false

    var body: some View {
        Group {
            if state == .idle {
                EmptyView()
            } else if state == .off {
                ProtoOffBar()
            } else if cancelled {
                HStack(spacing: DroppySpacing.sm) {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    Text("Tracking cancelled")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: DroppySpacing.sm)
                    Button("Undo") { cancelled = false }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .padding(.horizontal, DroppySpacing.smd)
                .padding(.vertical, DroppySpacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: DroppyRadius.ms, style: .continuous)
                        .fill(AdaptiveColors.notchSurfaceCardFill)
                )
            } else {
                HStack(spacing: DroppySpacing.smd) {
                    ProtoArtwork(hue: ProtoData.nowPlaying.hue, size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ProtoData.nowPlaying.title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text(ProtoData.nowPlaying.artist)
                            .font(.system(size: 11))
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: DroppySpacing.sm)
                    if state == .paused {
                        Text("Paused")
                            .font(.system(size: 11))
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        Button("Resume") {}
                            .buttonStyle(DroppyAccentButtonStyle(size: .small))
                    } else {
                        Text(ProtoData.nowPlaying.remaining)
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        ProtoLoveButton(size: 20)
                        Button {
                            cancelled = true
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        }
                        .buttonStyle(DroppyCircleButtonStyle(size: 20))
                        .help("Cancel now playing")
                        ProtoOverflowMenu(size: 20)
                    }
                }
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .padding(.horizontal, DroppySpacing.smd)
                .padding(.vertical, DroppySpacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: DroppyRadius.ms, style: .continuous)
                        .fill(AdaptiveColors.notchSurfaceCardFill)
                )
            }
        }
    }
}
