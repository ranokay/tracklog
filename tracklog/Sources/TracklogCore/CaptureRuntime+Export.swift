import Foundation

// MARK: - Export

public extension CaptureRuntime {
    /// Builds the portable settings document from the runtime's durable
    /// settings and the rules the store holds right now.
    ///
    /// The published page arrays are deliberately not used: a failed or stale
    /// UI load must never shrink an export. Each section is read from its
    /// store, and a failure is thrown before anything is written, so the
    /// caller can surface it instead of producing a partial file.
    func makeSettingsExport() async throws -> SettingsExport {
        guard let editStore, let blockStore else {
            throw SettingsExportReadFailure(
                section: "settings",
                message: "Tracklog is not connected to its local database.",
            )
        }

        let apps: [SeenApp]
        do {
            apps = try await allowlist.apps()
        } catch {
            throw SettingsExportReadFailure(section: "app allowlist", message: "\(error)")
        }

        let edits: [SimpleEditRule]
        do {
            edits = try await editStore.edits()
        } catch {
            throw SettingsExportReadFailure(section: "simple edits", message: "\(error)")
        }

        let blocks: [BlockRule]
        do {
            blocks = try await blockStore.blocks()
        } catch {
            throw SettingsExportReadFailure(section: "blocks", message: "\(error)")
        }

        return SettingsExport(
            settings: CaptureSettings(
                scrobblingEnabled: state.scrobblingEnabled,
                nowPlayingEnabled: state.nowPlayingEnabled,
                minimumDuration: state.minimumDuration,
                artistImageLookupsEnabled: state.artistImageLookupsEnabled,
            ),
            apps: apps,
            edits: edits,
            blocks: blocks,
            searchTemplate: state.playbackTemplate?.rawValue,
        )
    }

    /// Clears the last export's failure when a new export starts, so the Data
    /// page never shows an old reason beside a new attempt.
    func beginSettingsExport() {
        state.setExportFailure(nil)
    }

    /// Records why an export failed, for the Data page, and shows the "Not
    /// exported" strip. Cancelling the save panel is not a failure and never
    /// reaches here.
    func reportSettingsExportFailure(_ detail: String) {
        state.setExportFailure(detail)
        showHUD(.exportFailed)
    }
}
