import AppKit
import DroppyKit
import TracklogCore

public extension TracklogDroplet {
    func deactivate() {
        exportOperationID = nil
        exportTask?.cancel()
        exportTask = nil
        exportPanel?.cancel(nil)
        exportPanel = nil
        if let alert = exportAlert {
            exportAlert = nil
            let ownsCurrentModal = NSApp.modalWindow === alert.window
            alert.window.close()
            if ownsCurrentModal {
                // Only end the modal loop when it is our alert's. A host
                // dialog nested above it must keep its own modal session.
                NSApp.abortModal()
            }
        }
        activationTask?.cancel()
        activationTask = nil
        lastFMLink?.cancel()
        lastFMLink = nil
        reauthLink?.model.cancel()
        reauthLink = nil
        state.setReauthConnection(nil)
        serviceTransport = nil
        libreFMLink?.model.cancel()
        libreFMLink = nil
        libreFMAdapter = nil
        lastFMAppCredentialsProvider = nil
        networkReachability?.stop()
        networkReachability = nil
        runtime?.stop()
        runtime = nil
        hudSession?.deactivate()
        hudSession = nil
        automationGate = nil
        state.setHarnessSettingsPage(nil)
        host = nil
    }
}
