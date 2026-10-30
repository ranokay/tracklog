import DroppyKit
import SwiftUI
import TracklogCore

/// The action set the widget overflow and the takeover overflow share. The
/// paired widget has no overflow of its own, so the takeover keeps every
/// action reachable there.
struct TracklogMenuItems: View {
    let droplet: TracklogDroplet
    let status: ScrobbleStatus
    let scrobblingEnabled: Bool
    let pausedUntil: Date?
    let hasTrack: Bool
    let includesListenControls: Bool

    var body: some View {
        if includesListenControls {
            if status.canUndo {
                Button("Undo cancel") {
                    droplet.undoCancelCurrentListen()
                }
            } else if status.canCancel {
                Button("Cancel this listen") {
                    droplet.cancelCurrentListen()
                }
            }
        }

        if pausedUntil != nil {
            Button("Resume") {
                droplet.resumeCapture()
            }
        } else if scrobblingEnabled {
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
        .disabled(!hasTrack)

        Button("Block this track") {
            droplet.quickBlockCurrentTrack()
        }
        .disabled(!hasTrack)

        Divider()
        Button("Stop scrobbling") {
            droplet.setScrobblingEnabled(false)
        }
        .disabled(!scrobblingEnabled)

        Button("Settings") {
            droplet.openSettings()
        }
    }
}
