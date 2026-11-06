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
    private var pendingPresentation: DispatchWorkItem?
    private var isPreparing = false

    var isOpen: Bool {
        panel?.isVisible == true
    }

    /// Whether a session is prepared or a panel is up. The takeover's search
    /// button prepares inside the click's gesture and presents on the next
    /// run-loop turn; a second summon while that turn is pending closes it.
    var isPrepared: Bool {
        isPreparing || panel != nil
    }

    /// What the harness's panel contract check reads. It is not used by the
    /// droplet's own surfaces.
    struct ContractSnapshot {
        let panelExists: Bool
        let isVisible: Bool
        let isKey: Bool
        let isMain: Bool
        let appActive: Bool
        let canBecomeKey: Bool
        let canBecomeMain: Bool
        let activationBegan: Bool
        let monitorsInstalled: Bool
        let frame: NSRect?
        let visibleFrame: NSRect?
    }

    var contract: ContractSnapshot {
        ContractSnapshot(
            panelExists: panel != nil,
            isVisible: panel?.isVisible == true,
            isKey: panel?.isKeyWindow == true,
            isMain: panel?.isMainWindow == true,
            appActive: NSApp.isActive,
            canBecomeKey: panel?.canBecomeKey == true,
            canBecomeMain: panel?.canBecomeMain == true,
            activationBegan: activation != nil,
            monitorsInstalled: keyMonitor != nil
                && resignObserver != nil
                && activeObserver != nil,
            frame: panel?.frame,
            visibleFrame: NSScreen.main?.visibleFrame,
        )
    }

    init(droplet: TracklogDroplet) {
        self.droplet = droplet
    }

    // MARK: - Opening

    func open(reusingSession: Bool = false, notice: String? = nil) {
        prepare(reusingSession: reusingSession, notice: notice)
        present()
    }

    /// Starts the session and fills the model without ordering a window
    /// front. The takeover's search button runs this inside the click's
    /// gesture; `presentAfterGesture()` orders the panel front on the next
    /// run-loop turn, after that gesture has returned.
    func prepare(reusingSession: Bool = false, notice: String? = nil) {
        guard let droplet, droplet.host != nil, !isPrepared else { return }

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
        isPreparing = true
    }

    /// Orders the prepared panel front. A refusal that reopens the palette
    /// calls this synchronously; the takeover's search button defers it.
    func present() {
        guard let droplet, droplet.host != nil, isPreparing, panel == nil else { return }
        isPreparing = false
        pendingPresentation = nil

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
        if !panel.isKeyWindow {
            panel.makeKey()
        }
        installMonitors(for: panel)
    }

    /// Presents the prepared panel on the next run-loop turn. The click's
    /// gesture must return before a droplet's panel is ordered front, so the
    /// host's panel activation never runs inside that gesture.
    func presentAfterGesture() {
        guard isPrepared else { return }
        pendingPresentation?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.present()
        }
        pendingPresentation = item
        DispatchQueue.main.async(execute: item)
    }

    // MARK: - Closing

    func close(endingSearch: Bool = true) {
        guard isPrepared else { return }
        pendingPresentation?.cancel()
        pendingPresentation = nil
        isPreparing = false

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
        model.onOptionActivate = nil
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
            option: event.modifierFlags.contains(.option),
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
        case .optionActivate:
            model.onOptionActivate?()
            return nil
        case .commandActivate:
            model.onCommandActivate?()
            return nil
        case .escape:
            model.onEscape?()
            return nil
        }
    }
}

extension TracklogSearchPaletteController {
    // MARK: - Geometry

    /// The distance from the top of the screen to the bottom of the host's
    /// shelf, which the palette has to start below.
    ///
    /// Observed on the real host at `b1fbef9`: with the palette at layer 101
    /// and the shelf at layer 100, the shelf still drew over the palette's field
    /// and first result row, and it stayed open while the palette was up. Why
    /// the shelf wins is not known, so the palette is placed clear of the
    /// shelf's extent rather than relying on the window level.
    ///
    /// The shelf window starts at the screen's top edge. Its extent is the
    /// shell's top inset (the notch height plus 10, or 16 on an island), this
    /// droplet's widget card (`.fixed(150)`), the slot and bottom insets, and
    /// the host's page pill below the shell. A 37pt notch (DroppyKit's
    /// `physicalNotchHeight`) makes the shell 216pt, the shell bottom the real
    /// host measured; a 32pt notch would make it 211. The page pill bottom
    /// measured 258pt, 42pt below the shell; 48 keeps 6pt more.
    ///
    /// `frame(for:in:)` measures from the visible frame's top, which sits
    /// lower than the screen's top by the menu bar's height. That extra height
    /// is margin on top of this number, not part of it.
    var shelfClearance: CGFloat {
        let geometry = droplet?.host?.environment.notchGeometry
        let usesNotch = geometry?.isHardwareNotch == true
        let notchHeight = geometry?.closedHeight ?? 32
        let insets = DroppyShellMetrics.shelfContentInsets(
            usesNotchStyle: usesNotch,
            notchHeight: notchHeight,
        )
        let widgetHeight: CGFloat = if let descriptor = droplet?.widgetDescriptors
            .first(where: { $0.id == "tracklog" }) {
            switch descriptor.layoutTraits.contentHeight {
            case .standard: DroppyShellMetrics.shelfWidgetStandardContentHeight
            case let .fixed(height): height
            @unknown default: DroppyShellMetrics.shelfWidgetStandardContentHeight
            }
        } else {
            150
        }
        let shell = insets.top + widgetHeight
            + DroppyShellMetrics.shelfWidgetSlotInset * 2 + insets.bottom
        return shell + 48
    }

    private func paletteSize() -> NSSize {
        paletteSize(for: NSScreen.main?.visibleFrame)
    }

    private func paletteSize(for screen: NSRect?) -> NSSize {
        let maximumWidth = max(320, (screen?.width ?? 900) - 48)
        let maximumHeight = max(240, (screen?.height ?? 700) - 48)
        let belowShelf = max(240, (screen?.height ?? 700) - shelfClearance - 12 - 16)
        return NSSize(
            width: min(680, maximumWidth),
            height: min(560, min(maximumHeight, belowShelf)),
        )
    }

    private func frame(for size: NSSize) -> NSRect {
        guard let screen = NSScreen.main?.visibleFrame else {
            return NSRect(x: 200, y: 200, width: size.width, height: size.height)
        }
        return frame(for: size, in: screen)
    }

    private func frame(for size: NSSize, in screen: NSRect) -> NSRect {
        let originX = screen.midX - size.width / 2
        let clearance = shelfClearance + 12
        let topOffset = min(clearance, max(0, screen.height - size.height - 16))
        let originY = screen.maxY - size.height - topOffset
        return NSRect(x: originX, y: originY, width: size.width, height: size.height)
    }

    /// The frame the palette takes in `screen`. The harness uses a synthetic
    /// small screen to prove the layout still fits and clears the shelf there.
    func paletteFrame(in screen: NSRect) -> NSRect {
        frame(for: paletteSize(for: screen), in: screen)
    }
}

/// A borderless panel still has to become key and main so the field can take
/// typing, the local key monitor can address it, and `DroppyPanelActivation`
/// can make it main. A panel that refuses main makes the host raise
/// `NSInternalInconsistencyException` from `_changeJustMain` and terminate.
private final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}
