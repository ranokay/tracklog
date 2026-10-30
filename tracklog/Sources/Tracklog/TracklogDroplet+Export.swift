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
        guard let runtime else {
            presentExportError(
                title: "Settings could not be exported",
                detail: "Tracklog is not active.",
            )
            return
        }

        Task {
            let export: SettingsExport
            let data: Data
            do {
                export = try await runtime.makeSettingsExport()
                data = try export.encoded()
            } catch let failure as SettingsExportReadFailure {
                presentExportError(
                    title: "Settings could not be exported",
                    detail: failure.description,
                )
                return
            } catch {
                presentExportError(
                    title: "Settings could not be exported",
                    detail: "\(error)",
                )
                return
            }

            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "Tracklog Settings.json"
            panel.canCreateDirectories = true
            panel.title = "Export Tracklog settings"
            guard panel.runModal() == .OK, let url = panel.url else {
                return
            }

            do {
                try data.write(to: url, options: .atomic)
                hudSession?.show(HUD.resolve(.exported))
            } catch {
                presentExportError(
                    title: "Settings could not be exported",
                    detail: error.localizedDescription,
                )
            }
        }
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
