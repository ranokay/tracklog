import AppKit
import DroppyKit
import SwiftUI
import TracklogCore

/// Droplet-owned motion. Normal motion stays the host's own
/// `DroppyTransition`; with Reduce Motion the droplet swaps content with a
/// short crossfade, which keeps every droplet-owned change below 200 ms even
/// when the host's reduced spring is longer.
enum TracklogMotion {
    static let reducedDuration = AccessibilityMotion.reducedCrossfade

    /// The harness cannot change an OS accessibility setting, so the runtime
    /// checks set this environment override. Production reads the real
    /// workspace preference only.
    private nonisolated(unsafe) static var loggedReducedPath = false

    static var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || ProcessInfo.processInfo.environment["TRACKLOG_HARNESS_REDUCE_MOTION"] == "1"
    }

    /// Nil in normal motion: the host transitions own that case. The reduced
    /// path is an explicit 0.16 s crossfade.
    static var stateAnimation: Animation? {
        prefersReducedMotion ? .easeOut(duration: reducedDuration) : nil
    }

    static var element: AnyTransition {
        prefersReducedMotion
            ? .opacity.animation(.easeOut(duration: reducedDuration))
            : DroppyTransition.element
    }

    static var compactContent: AnyTransition {
        prefersReducedMotion
            ? .opacity.animation(.easeOut(duration: reducedDuration))
            : DroppyTransition.compactContent
    }

    /// One line for the harness runtime record. It carries no user data.
    static func logReducedPathOnce() {
        guard prefersReducedMotion, !loggedReducedPath else { return }
        loggedReducedPath = true
        NSLog("Tracklog motion: reduced crossfade 0.16s")
    }
}
