import DroppyKit
import SwiftUI
import TracklogCore

/// The status copy both surfaces use while a listen is cancelled.
let trackingCancelledText = "Tracking cancelled"

/// The Cancel, Undo and Edit controls shared by the shelf widget and the
/// now-playing strip. The surface supplies the transition its host uses for
/// swapped content: `element` in a card, `compactContent` in a strip.
struct ListenControls: View {
    let droplet: TracklogDroplet
    let status: ScrobbleStatus
    let transition: AnyTransition

    var body: some View {
        HStack(spacing: DroppySpacing.xs) {
            if status.canUndo {
                undoButton
            } else if status.canCancel {
                cancelButton
            }
            editButton
        }
    }

    private var cancelButton: some View {
        Button {
            droplet.cancelCurrentListen()
        } label: {
            Image(systemName: "xmark")
        }
        .buttonStyle(DroppyCircleButtonStyle(size: 24))
        .help("Cancel this listen")
        .accessibilityLabel("Cancel this listen")
        .transition(transition)
    }

    private var undoButton: some View {
        Button {
            droplet.undoCancelCurrentListen()
        } label: {
            Image(systemName: "arrow.uturn.backward")
        }
        .buttonStyle(DroppyCircleButtonStyle(size: 24))
        .help("Undo cancel")
        .accessibilityLabel("Undo cancel")
        .transition(transition)
    }

    private var editButton: some View {
        Button {
            droplet.editCurrentListen()
        } label: {
            Image(systemName: "pencil")
        }
        .buttonStyle(DroppyCircleButtonStyle(size: 24))
        .help("Edit this track")
        .accessibilityLabel("Edit this track")
    }
}
