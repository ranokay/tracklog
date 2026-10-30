import AppKit
import DroppyKit
import TracklogCore

public extension TracklogDroplet {
    func deactivate() {
        exportTask?.cancel()
        exportTask = nil
        exportPanel?.cancel(nil)
        exportPanel = nil
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
