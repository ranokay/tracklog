import DroppyKit
import SwiftUI
import TracklogCore

/// The shared takeover: section pills, the current-connection read switcher
/// on Charts, the chosen section, and the pinned now-playing strip.
struct TracklogTakeover: View {
    let droplet: TracklogDroplet
    @ObservedObject var state: TracklogAppState

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                TakeoverHeader(
                    droplet: droplet,
                    state: state,
                    width: proxy.size.width,
                )
                Group {
                    if state.takeoverSection == .charts {
                        TracklogChartsView(droplet: droplet, state: state)
                    } else {
                        TracklogHistoryContent(droplet: droplet, state: state)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                TakeoverPinnedStrip(droplet: droplet, state: state)
            }
            .frame(
                width: proxy.size.width,
                height: proxy.size.height,
                alignment: .topLeading,
            )
            .animation(TracklogMotion.stateAnimation, value: takeoverKey)
            .onDisappear { droplet.takeoverDidDisappear() }
        }
    }

    private var takeoverKey: String {
        "\(state.takeoverSection.rawValue)|\(takeoverPinnedKey(state))"
    }
}

// MARK: - Header

struct TakeoverHeader: View {
    let droplet: TracklogDroplet
    @ObservedObject var state: TracklogAppState
    let width: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Picker(
                "Sections",
                selection: Binding(
                    get: { state.takeoverSection },
                    set: { state.setTakeoverSection($0) },
                ),
            ) {
                Text("History").tag(TakeoverSection.history)
                Text("Charts").tag(TakeoverSection.charts)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .frame(width: 164)
            .accessibilityLabel(Text("Sections"))

            Spacer(minLength: DroppySpacing.md)

            if state.takeoverSection == .charts {
                connectionSwitcher
                    .frame(width: 208, alignment: .trailing)
            }
        }
        .padding(.leading, DroppySpacing.xl)
        .padding(.trailing, DroppySpacing.xl)
        .frame(width: width, height: 36, alignment: .topLeading)
    }

    @ViewBuilder
    private var connectionSwitcher: some View {
        if state.connections.isEmpty {
            Text("None")
                .font(.caption.weight(.medium))
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                .lineLimit(1)
                .padding(.trailing, DroppySpacing.md)
                .frame(width: 208, alignment: .trailing)
                .accessibilityLabel(Text("Current connection, none"))
        } else {
            Menu {
                Button("No connection") {
                    Task { try? await droplet.setChartCurrentConnection(nil) }
                }
                ForEach(state.connections) { connection in
                    Button("\(connection.kind.displayName) · \(connection.displayName)") {
                        Task { try? await droplet.setChartCurrentConnection(connection.id) }
                    }
                }
            } label: {
                HStack(spacing: DroppySpacing.xs) {
                    Text(currentConnectionTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                .frame(width: 208, alignment: .trailing)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel(Text("Current connection"))
            .accessibilityValue(Text(currentConnectionAccessibilityValue))
        }
    }

    private var currentConnectionTitle: String {
        guard let connection = state.currentConnection else { return "No connection" }
        return "\(connection.kind.displayName) · \(connection.displayName)"
    }

    private var currentConnectionAccessibilityValue: String {
        guard let connection = state.currentConnection else { return "No connection" }
        return "\(connection.kind.displayName), \(connection.displayName)"
    }
}

// MARK: - Pinned strip

/// Playing, paused and off stay in one place across History and Charts. The
/// strip is absent when nothing is playing and capture is healthy.
struct TakeoverPinnedStrip: View {
    let droplet: TracklogDroplet
    @ObservedObject var state: TracklogAppState

    var body: some View {
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
}

@MainActor
func takeoverPinnedKey(_ state: TracklogAppState) -> String {
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
