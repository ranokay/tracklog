import Foundation

/// The host side of HUD presentation. Production forwards to Droppy's HUD
/// service; tests record the calls.
@MainActor
public protocol HUDHosting: AnyObject {
    /// Shows a HUD and reports whether the host accepted it. A refusal is
    /// final: the caller must not retry or queue it.
    @discardableResult
    func present(_ presentation: HUDPresentation) -> Bool

    /// Takes down one of this droplet's HUDs. Does nothing when it is not
    /// showing.
    func dismiss(id: String)
}

/// Owns Tracklog's one HUD slot. The host has one slot too, but the host's
/// priority bands can refuse a newer low-priority request while an older
/// normal HUD still holds it. Tracklog's rule is latest-wins, so a different
/// id dismisses our own active HUD before presenting the new one; the same id
/// is re-presented in place for the host's morph.
@MainActor
public final class HUDHostSession {
    public private(set) var activeID: String?

    private let host: any HUDHosting
    private let announce: @MainActor (HUDPresentation) -> Void
    private let logRefusal: @MainActor (HUDPresentation) -> Void

    public init(
        host: any HUDHosting,
        announce: @escaping @MainActor (HUDPresentation) -> Void,
        logRefusal: @escaping @MainActor (HUDPresentation) -> Void,
    ) {
        self.host = host
        self.announce = announce
        self.logRefusal = logRefusal
    }

    /// Presents the latest HUD. An accepted presentation announces its exact
    /// spoken string once. A refused presentation logs once and leaves nothing
    /// queued.
    public func show(_ presentation: HUDPresentation) {
        if let activeID, activeID != presentation.id {
            host.dismiss(id: activeID)
            self.activeID = nil
        }

        if host.present(presentation) {
            activeID = presentation.id
            announce(presentation)
        } else {
            activeID = nil
            logRefusal(presentation)
        }
    }

    /// Dismisses Tracklog's HUD when the droplet deactivates. Idempotent.
    public func deactivate() {
        guard let activeID else { return }
        host.dismiss(id: activeID)
        self.activeID = nil
    }
}
