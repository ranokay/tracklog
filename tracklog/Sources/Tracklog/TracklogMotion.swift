import AppKit
import DroppyKit
import SwiftUI
import TracklogCore

/// The harness cannot change an OS accessibility setting, so its runtime
/// checks set environment overrides instead. They are read only while the
/// harness hosts the droplet; a real host sees the system preference alone.
enum HarnessEnvironment {
    /// Set by `activate(host:)` before any surface is built.
    nonisolated(unsafe) static var isActive = false

    static func value(_ name: String) -> String? {
        isActive ? ProcessInfo.processInfo.environment[name] : nil
    }
}

/// Droplet-owned motion. Normal motion stays the host's own
/// `DroppyTransition`; with Reduce Motion the droplet swaps content with a
/// short crossfade, which keeps every droplet-owned change below 200 ms even
/// when the host's reduced spring is longer.
enum TracklogMotion {
    static let reducedDuration = AccessibilityMotion.reducedCrossfade

    private nonisolated(unsafe) static var loggedReducedPath = false

    static var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || HarnessEnvironment.value("TRACKLOG_HARNESS_REDUCE_MOTION") == "1"
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

    /// One line for the harness runtime record. It carries no user data and
    /// is not written in a real host.
    static func logReducedPathOnce() {
        guard HarnessEnvironment.isActive, prefersReducedMotion, !loggedReducedPath else { return }
        loggedReducedPath = true
        NSLog("Tracklog motion: reduced crossfade 0.16s")
    }
}
