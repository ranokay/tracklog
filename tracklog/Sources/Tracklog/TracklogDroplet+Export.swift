import AppKit
import DroppyKit
import SwiftUI
import TracklogCore
import UniformTypeIdentifiers

extension TracklogDroplet {
    /// The portable settings export. The document is built and encoded before
    /// the save panel opens, so a failed rule read shows an alert instead of a
    /// partial file. Cancellation is silent; a write failure gets a native
    /// alert because the HUD has no copy for it.
    func exportSettings() {
        guard exportTask == nil else { return }
        guard let runtime, host != nil else {
            presentExportError(
                title: "Settings could not be exported",
                detail: "Tracklog is not active.",
            )
            return
        }

        exportTask = Task { [weak self] in
            defer { self?.exportTask = nil }

            let export: SettingsExport
            let data: Data
            do {
                export = try await runtime.makeSettingsExport()
                data = try export.encoded()
            } catch {
                guard let self, isStillActive(runtime: runtime), !Task.isCancelled else { return }
                let detail = (error as? SettingsExportReadFailure)?.description ?? "\(error)"
                presentExportError(
                    title: "Settings could not be exported",
                    detail: detail,
                )
                return
            }

            guard let self, isStillActive(runtime: runtime), !Task.isCancelled else { return }

            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "Tracklog Settings.json"
            panel.canCreateDirectories = true
            panel.title = "Export Tracklog settings"
            exportPanel = panel
            let response = panel.runModal()
            exportPanel = nil

            guard response == .OK, let url = panel.url, isStillActive(runtime: runtime), !Task.isCancelled else { return }

            do {
                try data.write(to: url, options: .atomic)
                guard isStillActive(runtime: runtime), !Task.isCancelled else { return }
                hudSession?.show(HUD.resolve(.exported))
            } catch {
                guard isStillActive(runtime: runtime), !Task.isCancelled else { return }
                presentExportError(
                    title: "Settings could not be exported",
                    detail: error.localizedDescription,
                )
            }
        }
    }

    /// True while the export still belongs to the live activation that
    /// started it.
    private func isStillActive(runtime: CaptureRuntime) -> Bool {
        self.runtime === runtime && host != nil
    }

    var dropletVersion: String {
        Bundle(for: TracklogDroplet.self)
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "1.0.0"
    }

    func openURL(_ raw: String) {
        guard let url = URL(string: raw), url.scheme == "https" else { return }
        if host?.workspace.open(url) != true {
            host?.log.notice("Opening \(raw) was refused")
        }
    }

    private func presentExportError(title: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
