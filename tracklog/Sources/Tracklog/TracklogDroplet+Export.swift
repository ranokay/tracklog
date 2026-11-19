import AppKit
import DroppyKit
import SwiftUI
import TracklogCore
import UniformTypeIdentifiers

// swiftformat:disable redundantSelf
// Explicit self is required by the compiler inside the escaping export task.

extension TracklogDroplet {
    /// The portable settings export. The document is built and encoded before
    /// the save panel opens, so a failed rule read writes no partial file.
    /// Cancellation is silent. A failure shows the "Not exported" strip and
    /// leaves its reason under Export on the Data page until the next attempt.
    func exportSettings() {
        guard exportTask == nil, let runtime, host != nil else { return }

        state.setExportFailure(nil)
        let operationID = UUID()
        exportOperationID = operationID
        exportTask = Task { [weak self] in
            defer {
                if let self, self.exportOperationID == operationID {
                    self.exportTask = nil
                    self.exportOperationID = nil
                }
            }

            let export: SettingsExport
            let data: Data
            do {
                export = try await runtime.makeSettingsExport()
                data = try export.encoded()
            } catch {
                guard let self,
                      self.isCurrentExport(operationID, runtime: runtime),
                      !Task.isCancelled
                else { return }
                let detail = (error as? SettingsExportReadFailure)?.description ?? "\(error)"
                self.reportExportFailure(detail, operationID: operationID, runtime: runtime)
                return
            }

            guard let self,
                  self.isCurrentExport(operationID, runtime: runtime),
                  !Task.isCancelled
            else { return }

            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "Tracklog Settings.json"
            panel.canCreateDirectories = true
            panel.title = "Export Tracklog settings"
            exportPanel = panel
            let response = panel.runModal()
            if exportPanel === panel {
                exportPanel = nil
            }

            guard response == .OK,
                  let url = panel.url,
                  self.isCurrentExport(operationID, runtime: runtime),
                  !Task.isCancelled
            else { return }

            do {
                try data.write(to: url, options: .atomic)
                guard self.isCurrentExport(operationID, runtime: runtime), !Task.isCancelled else { return }
                self.hudSession?.show(HUD.resolve(.exported))
            } catch {
                guard self.isCurrentExport(operationID, runtime: runtime), !Task.isCancelled else { return }
                self.reportExportFailure(error.localizedDescription, operationID: operationID, runtime: runtime)
            }
        }
    }

    /// True while the export belongs to the live activation and the operation
    /// that started it. It prevents an old task's cleanup from clearing a
    /// newer activation's task, panel or HUD.
    private func isCurrentExport(_ operationID: UUID, runtime: CaptureRuntime) -> Bool {
        exportOperationID == operationID && self.runtime === runtime && host != nil
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

    /// No modal alert: deactivation has no loop to end, and the reason stays
    /// on the Data page where the export started.
    private func reportExportFailure(_ detail: String, operationID: UUID, runtime: CaptureRuntime) {
        guard self.isCurrentExport(operationID, runtime: runtime) else { return }
        state.setExportFailure(detail)
        hudSession?.show(HUD.resolve(.exportFailed))
    }
}

// swiftformat:enable redundantSelf
