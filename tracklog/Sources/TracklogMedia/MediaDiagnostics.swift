import Foundation
import TracklogCore

/// The text behind Settings' Copy diagnostics.
///
/// It carries the four fields a bug report needs: the helper path, the macOS
/// version, Droppy's version and the last failure. No credential, token or
/// track metadata is included.
public enum MediaDiagnostics {
    public static func text(
        status: MediaStatus,
        macOSVersion: String,
        droppyVersion: String,
    ) -> String {
        [
            "Tracklog media diagnostics",
            "Droppy version: \(droppyVersion)",
            "macOS: \(macOSVersion)",
            "Media source: \(status.source.displayName)",
            "Media helper: \(status.helperHealth.summary)",
            "Automation: \(status.automation.summary)",
            "Helper path: \(status.helperPath)",
            "Last failure: \(status.lastFailure ?? "None")",
        ].joined(separator: "\n")
    }
}
