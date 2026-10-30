import DroppyKit
import SwiftUI
import TracklogCore

/// The status copy both surfaces use while a listen is cancelled.
let trackingCancelledText = "Tracking cancelled"

/// The Cancel and Undo controls shared by the now-playing strip. The widget
/// reaches the same actions through its overflow menu. The surface supplies
/// the transition its host uses for swapped content.
struct ListenControls: View {
    let droplet: TracklogDroplet
    let status: ScrobbleStatus
    let transition: AnyTransition

    var body: some View {
        if status.canUndo {
            Button {
                droplet.undoCancelCurrentListen()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(DroppyCircleButtonStyle(size: 24))
            .help("Undo cancel")
            .accessibilityLabel("Undo cancel")
            .transition(transition)
        } else if status.canCancel {
            Button {
                droplet.cancelCurrentListen()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(DroppyCircleButtonStyle(size: 24))
            .help("Cancel this listen")
            .accessibilityLabel("Cancel this listen")
            .transition(transition)
        }
    }
}
