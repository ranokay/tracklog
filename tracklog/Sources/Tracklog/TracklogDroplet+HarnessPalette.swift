import AppKit
import DroppyKit

/// Harness-only result of the palette's host contract check.
public struct TracklogPaletteContract: Sendable {
    public let failures: [String]
    /// The open palette's frame and the clearance it was checked against. A
    /// passing run prints it, so the numbers in the report come from that run.
    public var measurement: String?

    public var passed: Bool {
        failures.isEmpty
    }

    public var summary: String {
        if !passed {
            return "panel check: " + failures.joined(separator: "; ")
        }
        return "panel check: passed" + (measurement.map { " (\($0))" } ?? "")
    }
}

extension TracklogDroplet {
    /// Harness-only. Drives the palette through its real entry point and
    /// asserts the host contract the real Playground enforces: the panel is
    /// key and main, `DroppyPanelActivation` began, the key monitor and
    /// observers are installed, and close clears the panel so a second open
    /// works.
    ///
    /// `nil` outside the harness. The harness installs the host's panel
    /// activation provider before activation, so a panel that refuses main
    /// raises the same exception the host raises.
    public func runPaletteContractCheck() async -> TracklogPaletteContract? {
        guard host?.environment.isHarness == true else { return nil }
        var failures: [String] = []

        openSearchPalette()
        guard await waitForPalette() else {
            failures.append("the palette did not open")
            return TracklogPaletteContract(failures: failures)
        }
        _ = await waitForKeyAndMain()
        appendContractFailures("the open palette", to: &failures)
        let measurement = paletteMeasurement()

        searchPaletteController.close()
        let closed = searchPaletteController.contract
        if closed.panelExists {
            failures.append("close left the panel")
        }
        if closed.monitorsInstalled {
            failures.append("close left the key monitor and observers installed")
        }
        if searchPaletteController.isOpen {
            failures.append("close left the palette visible")
        }

        openSearchPalette()
        guard await waitForPalette() else {
            failures.append("the palette did not reopen")
            return TracklogPaletteContract(failures: failures)
        }
        _ = await waitForKeyAndMain()
        appendContractFailures("the reopened palette", to: &failures)
        searchPaletteController.close()
        return TracklogPaletteContract(failures: failures, measurement: measurement)
    }

    /// The open palette's frame, the shelf clearance and the synthetic 1280×600
    /// frame, as text for the passing run's summary.
    private func paletteMeasurement() -> String {
        let contract = searchPaletteController.contract
        let smallScreen = NSRect(x: 0, y: 0, width: 1280, height: 600)
        return "frame \(String(describing: contract.frame)), "
            + "visible \(String(describing: contract.visibleFrame)), "
            + "shelf clearance \(searchPaletteController.shelfClearance)pt, "
            + "1280×600 frame \(searchPaletteController.paletteFrame(in: smallScreen))"
    }

    private func appendContractFailures(_ label: String, to failures: inout [String]) {
        let contract = searchPaletteController.contract
        let state = "app active: \(contract.appActive), visible: \(contract.isVisible), "
            + "canBecomeKey: \(contract.canBecomeKey), canBecomeMain: \(contract.canBecomeMain)"
        if !contract.isKey {
            failures.append("\(label) is not key (\(state))")
        }
        if !contract.isMain {
            failures.append("\(label) is not main (\(state))")
        }
        if !contract.activationBegan {
            failures.append("\(label) did not begin an activation")
        }
        if !contract.monitorsInstalled {
            failures.append("\(label) has no key monitor and observers")
        }
        appendFrameFailures(label, contract: contract, to: &failures)
    }

    /// Appends failures when the open palette's frame does not clear the shelf
    /// clearance, leaves its visible frame, or fails to fit the synthetic screens.
    private func appendFrameFailures(
        _ label: String,
        contract: TracklogSearchPaletteController.ContractSnapshot,
        to failures: inout [String],
    ) {
        guard let frame = contract.frame, let visible = contract.visibleFrame else {
            failures.append("\(label) has no frame to check")
            return
        }
        let clearance = searchPaletteController.shelfClearance
        let topOffset = visible.maxY - frame.maxY
        if topOffset < clearance {
            failures.append(
                "\(label) starts \(topOffset)pt below the visible frame top; "
                    + "the shelf needs \(clearance)pt",
            )
        }
        if !visible.contains(frame) {
            failures.append("\(label) frame \(frame) is not inside the visible frame \(visible)")
        }
        if frame.width < 320 || frame.height < 240 {
            failures.append("\(label) frame \(frame) is smaller than the minimum palette")
        }

        let smallScreen = NSRect(x: 0, y: 0, width: 1280, height: 600)
        let smallFrame = searchPaletteController.paletteFrame(in: smallScreen)
        if !smallScreen.contains(smallFrame) {
            failures.append("\(label) does not fit a 1280×600 screen: \(smallFrame)")
        }
        if smallScreen.maxY - smallFrame.maxY < clearance {
            failures.append("\(label) overlaps the shelf on a 1280×600 screen: \(smallFrame)")
        }
        if smallFrame.width < 320 || smallFrame.height < 240 {
            failures.append("\(label) is smaller than the minimum palette on a 1280×600 screen")
        }

        // A shorter screen shrinks the palette rather than letting its minimum
        // height pull it under the shelf clearance.
        let shortScreen = NSRect(x: 0, y: 0, width: 1280, height: 420)
        let shortFrame = searchPaletteController.paletteFrame(in: shortScreen)
        if !shortScreen.contains(shortFrame) {
            failures.append("\(label) does not fit a 1280×420 screen: \(shortFrame)")
        }
        if shortScreen.maxY - shortFrame.maxY < clearance {
            failures.append("\(label) overlaps the shelf on a 1280×420 screen: \(shortFrame)")
        }
    }

    /// Bounded wait on the palette's own open signal. It fails with the
    /// condition it awaited, not after a fixed number of turns.
    private func waitForPalette(timeout: Duration = .seconds(2)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !searchPaletteController.isOpen {
            if ContinuousClock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// The host makes the panel key and main as part of activation. Wait for
    /// that signal, bounded, before reading the contract.
    private func waitForKeyAndMain(timeout: Duration = .seconds(2)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !(searchPaletteController.contract.isKey && searchPaletteController.contract.isMain) {
            if ContinuousClock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}
