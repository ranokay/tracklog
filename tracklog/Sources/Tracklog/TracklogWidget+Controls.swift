import DroppyKit
import SwiftUI
import TracklogCore

extension TracklogWidget {
    // MARK: - Controls

    var undoButton: some View {
        Button {
            droplet.undoCancelCurrentListen()
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(.body, design: .default, weight: .semibold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(DroppyCircleButtonStyle(size: 24))
        .help("Undo cancel")
        .accessibilityLabel("Undo cancel")
        .accessibilitySortPriority(3)
    }

    var loveButton: some View {
        let loved = state.nowPlayingIsLoved
        return Button {
            droplet.toggleLoveForCurrentTrack()
        } label: {
            Image(systemName: loved ? "heart.fill" : "heart")
                .font(.system(.body, design: .default, weight: .semibold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(DroppyCircleButtonStyle(size: 24))
        .disabled(!state.feedbackSupport.canLove || state.nowPlaying == nil)
        .help(loveHelp)
        .accessibilityLabel(loved ? "Unlove this track" : "Love this track")
        .accessibilityValue(Text(loved ? "Loved" : "Not loved"))
        .accessibilityHint(Text(loveHint))
        .accessibilityAddTraits(loved ? .isSelected : [])
        .accessibilitySortPriority(3)
    }

    var loveHelp: String {
        guard state.feedbackSupport.canLove else {
            return "Connect a service that supports love"
        }
        return state.nowPlayingIsLoved ? "Unlove this track" : "Love this track"
    }

    var loveHint: String {
        state.feedbackSupport.canLove ? "" : "Connect a service that supports love."
    }

    /// Shown only when something is waiting. It is the one-click path to the
    /// pending list, not to the top of History.
    @ViewBuilder var queueButton: some View {
        if state.pendingCount > 0 {
            Button {
                droplet.presentHistory(expandingPending: true)
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "tray.full")
                    Text("\(state.pendingCount)")
                        .monospacedDigit()
                }
                .font(.caption.weight(.semibold))
                .frame(minWidth: 24, minHeight: 24)
            }
            .buttonStyle(DroppyQuietButtonStyle(size: .small))
            .help("Pending scrobbles")
            .accessibilityLabel(
                Text("\(state.pendingCount) \(state.pendingCount == 1 ? "scrobble" : "scrobbles") waiting"),
            )
            .accessibilityHint(Text("Opens History with the pending list"))
            .accessibilitySortPriority(2)
        }
    }

    var overflowMenu: some View {
        Menu {
            menuItems
        } label: {
            Image(systemName: "ellipsis")
                .font(.caption.weight(.bold))
                .frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel(Text("More"))
        .accessibilitySortPriority(1)
    }

    @ViewBuilder private var menuItems: some View {
        if state.status.canUndo {
            Button("Undo cancel") {
                droplet.undoCancelCurrentListen()
            }
        } else if state.status.canCancel {
            Button("Cancel this listen") {
                droplet.cancelCurrentListen()
            }
        }

        if state.pausedUntil != nil {
            Button("Resume") {
                droplet.resumeCapture()
            }
        } else {
            Menu("Pause") {
                Button("30 minutes") { droplet.pauseCapture(for: 30 * 60) }
                Button("1 hour") { droplet.pauseCapture(for: 60 * 60) }
                Button("2 hours") { droplet.pauseCapture(for: 2 * 60 * 60) }
                Button("4 hours") { droplet.pauseCapture(for: 4 * 60 * 60) }
            }
        }

        Divider()
        Button("Edit this track") {
            droplet.editCurrentListen()
        }
        .disabled(state.nowPlaying == nil)

        Button("Block this track") {
            droplet.quickBlockCurrentTrack()
        }
        .disabled(state.nowPlaying == nil)

        Divider()
        Button("Stop scrobbling") {
            droplet.setScrobblingEnabled(false)
        }
        .disabled(!state.scrobblingEnabled)

        Button("Settings") {
            droplet.openSettings()
        }
    }
}
