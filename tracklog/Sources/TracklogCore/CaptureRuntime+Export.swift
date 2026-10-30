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
            ),
            apps: apps,
            edits: edits,
            blocks: blocks,
        )
    }
}
