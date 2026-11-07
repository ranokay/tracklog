import AppKit
import DroppyKitHarness
import Tracklog

/// Harness-only: runs the palette's host contract in a real harness session.
///
/// This is the regression guard for the real-host crash: the panel must be key
/// and main after activation, the activation must have begun, the key monitor
/// and observers must be installed, and close must clear the panel so a second
/// open works. On a panel that refuses main, the installed host contract
/// raises the same exception Droppy raises, so this check fails.
@MainActor
enum TracklogPanelCheck {
    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])

        let droplet = TracklogDroplet()
        let session = HarnessSession(
            droplet: droplet,
            manifest: nil,
            manifestProblem: "the panel check does not need the manifest",
        )
        session.activate()
        guard session.activationError == nil else {
            print("panel check: activation failed: \(session.activationError ?? "unknown")")
            exit(1)
        }

        Task { @MainActor in
            guard let result = await droplet.runPaletteContractCheck() else {
                print("panel check: the droplet did not run the harness check")
                exit(1)
            }
            print(result.summary)
            exit(result.passed ? 0 : 1)
        }
        RunLoop.main.run()
        exit(1)
    }
}
