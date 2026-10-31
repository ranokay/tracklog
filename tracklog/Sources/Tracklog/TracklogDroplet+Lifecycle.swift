import AppKit
import DroppyKit
import TracklogCore

public extension TracklogDroplet {
    /// Removal deletes every credential Tracklog saved, so no account's access
    /// outlives the droplet. Local history and settings stay, as Droppy keeps
    /// settings across removal; after a reinstall, activation unlinks each
    /// connection that has no credential and keeps its listens. Removal is
    /// never vetoed.
    func prepareForRemoval() -> Bool {
        guard host?.environment.isHarness != true else { return true }
        do {
            try KeychainCredentialStore().deleteAll()
        } catch {
            host?.log.error("Could not delete saved credentials on removal: \(error)")
        }
        return true
    }

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
