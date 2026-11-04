import AppKit
import DroppyKit
import SwiftUI
import TracklogCore

/// The palette's window. The controller owns the panel, the key monitor, the
/// resign-key observers and the one activation, so every close path releases
/// all four and finishes the activation exactly once.
@MainActor
final class TracklogSearchPaletteController {
    let model = SearchPaletteModel()

    private weak var droplet: TracklogDroplet?
    private var panel: PalettePanel?
    private var activation: DroppyPanelActivation?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?

    var isOpen: Bool {
        panel?.isVisible == true
    }

    init(droplet: TracklogDroplet) {
        self.droplet = droplet
    }

    // MARK: - Opening

    func open(reusingSession: Bool = false, notice: String? = nil) {
        guard let droplet, droplet.host != nil, panel == nil else { return }

        model.collapsed = []
        model.expanded = []
        model.selectedID = nil
        model.notice = notice
        if reusingSession {
            model.query = droplet.state.catalogueSearch.query
        } else {
            droplet.runtime?.catalogueSearch?.beginSession()
            model.query = ""
        }

        let size = paletteSize()
        let panel = PalettePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.title = "Search and play"
        panel.setFrame(frame(for: size), display: false)

        let root = TracklogSearchPalette(
            droplet: droplet,
            state: droplet.state,
            model: model,
            announce: { [weak self] text in
                self?.announce(text)
            },
            close: { [weak self] in
                self?.close()
            },
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        self.panel = panel

        panel.makeKeyAndOrderFront(nil)
        activation = DroppyPanelActivation.begin(
            for: panel,
            returningTo: NSWorkspace.shared.frontmostApplication,
        )
        installMonitors(for: panel)
    }

    // MARK: - Closing

    func close(endingSearch: Bool = true) {
        guard panel != nil else { return }

        removeMonitors()
        if endingSearch {
            droplet?.runtime?.catalogueSearch?.endSession()
        }
        activation?.finish()
        activation = nil
        panel?.orderOut(nil)
        panel = nil
        model.onMove = nil
        model.onActivate = nil
        model.onCommandActivate = nil
        model.onEscape = nil
    }

    // MARK: - Accessibility

    func announce(_ text: String) {
        let element: Any = panel?.contentView ?? NSApplication.shared
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ],
        )
    }

    // MARK: - Keyboard

    private func installMonitors(for panel: PalettePanel) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return handle(event)
        }

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main,
        ) { [weak self] _ in
            Task { @MainActor in
                self?.close()
            }
        }
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main,
        ) { [weak self] _ in
            Task { @MainActor in
                self?.close()
            }
        }
    }

    private func removeMonitors() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        for observer in [resignObserver, activeObserver].compactMap(\.self) {
            NotificationCenter.default.removeObserver(observer)
        }
        resignObserver = nil
        activeObserver = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        // While an input method has marked text, every key belongs to the
        // field editor. Return commits the composition and Escape cancels it.
        let marked = (panel?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
        let action = PaletteKeyRouter.route(
            keyCode: event.keyCode,
            command: event.modifierFlags.contains(.command),
            hasMarkedText: marked,
        )
        switch action {
        case .passThrough:
            return event
        case .moveUp:
            model.onMove?(-1)
            return nil
        case .moveDown:
            model.onMove?(1)
            return nil
        case .activate:
            model.onActivate?()
            return nil
        case .commandActivate:
            model.onCommandActivate?()
            return nil
        case .escape:
            model.onEscape?()
            return nil
        }
    }

    // MARK: - Geometry

    private func paletteSize() -> NSSize {
        let screen = NSScreen.main?.visibleFrame
        let maximumWidth = max(320, (screen?.width ?? 900) - 48)
        let maximumHeight = max(240, (screen?.height ?? 700) - 48)
        return NSSize(
            width: min(680, maximumWidth),
            height: min(560, maximumHeight),
        )
    }

    private func frame(for size: NSSize) -> NSRect {
        guard let screen = NSScreen.main?.visibleFrame else {
            return NSRect(x: 200, y: 200, width: size.width, height: size.height)
        }
        let originX = screen.midX - size.width / 2
        let originY = screen.maxY - size.height - min(80, screen.height * 0.12)
        return NSRect(x: originX, y: originY, width: size.width, height: size.height)
    }
}

/// A borderless panel still has to become key so the field can take typing
/// and the local key monitor can address it.
private final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}
