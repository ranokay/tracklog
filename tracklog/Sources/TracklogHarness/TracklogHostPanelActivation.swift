import AppKit
import DroppyKit

/// Harness-only: installs the host's panel activation contract.
///
/// The real Playground makes a droplet's panel key and main through
/// `DroppyPanelActivation`. A panel that refuses main makes the host raise
/// `NSInternalInconsistencyException` from `_changeJustMain`. The harness does
/// not install that provider on its own, which is why it never saw the crash.
/// This fixture installs the same contract so the palette is tested against
/// the host's rule.
@MainActor
enum TracklogHostPanelActivation {
    static func installIfRequested() {
        guard ProcessInfo.processInfo.environment["TRACKLOG_HARNESS_HOST_PANEL_ACTIVATION"] == "1" else {
            return
        }
        DroppyKitSurfaceBridge.installPanelActivationProvider { panel, returningTo in
            guard panel.canBecomeMain else {
                NSException(
                    name: .internalInconsistencyException,
                    reason: "Invalid parameter not satisfying: [self canBecomeMainWindow]",
                    userInfo: nil,
                ).raise()
                fatalError("NSException.raise() returned")
            }
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            if !panel.isMainWindow {
                panel.makeMain()
            }
            return DroppyPanelActivation(finish: {
                if let returningTo, !returningTo.isTerminated {
                    returningTo.activate(options: [])
                }
            })
        }
    }
}
