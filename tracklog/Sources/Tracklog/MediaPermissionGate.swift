import DroppyKit
import TracklogCore
import TracklogMedia

/// Bridges the host's permissions and preferences services to the media
/// layer's Automation gate.
///
/// The host owns every TCC prompt, so the arbiter asks here and this gate asks
/// Droppy. A denial is written to preferences: the next fallback reads it and
/// never prompts again, and a fix in System Settings clears it without a
/// relaunch.
@MainActor
final class HostAutomationPermissionGate: MediaAutomationPermissionGate {
    private static let denialKey = "automationDenied"

    private let host: DropletHost

    init(host: DropletHost) {
        self.host = host
    }

    func authorization() -> MediaStatus.AutomationState {
        guard host.isGranted(.appleEvents) else { return .unavailable }
        switch map(host.permissions.status(for: .appleEvents)) {
        case .available:
            clearRememberedDenial()
            return .available
        case .denied:
            return .denied
        case .notRequested:
            return isDenied ? .denied : .notRequested
        case .unavailable:
            return .unavailable
        }
    }

    func requestAuthorization() async -> MediaStatus.AutomationState {
        guard host.isGranted(.appleEvents) else { return .unavailable }
        let result = await host.permissions.request(.appleEvents)
        let status = map(result)
        switch status {
        case .available:
            clearRememberedDenial()
        case .denied:
            rememberDenial()
        case .notRequested, .unavailable:
            break
        }
        return status
    }

    func rememberDenial() {
        host.preferences.setValue(true, forKey: Self.denialKey)
    }

    /// Clears the remembered denial after the user asks to fix it in System
    /// Settings, so the next fallback may ask again.
    func forgetDenial() {
        host.preferences.setValue(false, forKey: Self.denialKey)
    }

    private var isDenied: Bool {
        host.preferences.value(forKey: Self.denialKey, default: false)
    }

    private func clearRememberedDenial() {
        guard isDenied else { return }
        host.preferences.setValue(false, forKey: Self.denialKey)
    }

    private func map(_ status: DropletPermissionStatus) -> MediaStatus.AutomationState {
        switch status {
        case .granted: .available
        case .notDetermined: .notRequested
        case .denied: .denied
        case .unavailable: .unavailable
        @unknown default: .unavailable
        }
    }
}
