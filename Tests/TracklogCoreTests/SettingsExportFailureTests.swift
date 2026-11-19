import Foundation
import Testing
@testable import TracklogCore

/// The droplet starts an export with `beginSettingsExport()` and reports a
/// read or write failure with `reportSettingsExportFailure(_:)`. The save
/// panel stays in the droplet target, which has no tests.
@Suite("Settings export failure")
@MainActor
struct SettingsExportFailureTests: CaptureTestHelpers {
    @Test func aFailedExportIsKeptForTheDataPageAndShowsTheStrip() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let probe = HUDProbe()
        let state = TracklogAppState()
        let runtime = CaptureRuntime(
            state: state,
            clock: FakeClock(base),
            source: ReplayedNowPlaying(),
            store: store,
            allowlist: store,
            edits: UnreadableEditStore(),
            blocks: store,
            hud: probe.session,
            settings: CaptureSettings(scrobblingEnabled: true),
        )

        // The droplet's export path: start, the rule read fails, report it.
        runtime.beginSettingsExport()
        do {
            _ = try await runtime.makeSettingsExport()
            Issue.record("the export should have failed")
        } catch let failure as SettingsExportReadFailure {
            runtime.reportSettingsExportFailure(failure.description)
        }

        let detail = try #require(state.exportFailure)
        #expect(detail.contains("simple edits"))
        #expect(probe.presentations.last?.id == HUDIdentifier.failureExport)
        #expect(probe.announcements.last == "Settings could not be exported. The Data page says why.")

        // A write failure after the panel reports the system's text the same way.
        runtime.reportSettingsExportFailure("You don't have permission to save the file.")
        #expect(state.exportFailure == "You don't have permission to save the file.")

        // The next attempt clears the old reason before anything else happens.
        runtime.beginSettingsExport()
        #expect(state.exportFailure == nil)
        #expect(probe.presentations.count(where: { $0.id == HUDIdentifier.failureExport }) == 2)
    }
}

private actor UnreadableEditStore: SimpleEditStore {
    func edits() async throws -> [SimpleEditRule] {
        throw DatabaseError.sqlite("read failed")
    }

    func save(_ rule: SimpleEditRule) async throws -> SimpleEditRule {
        rule
    }

    func deleteEdit(id _: Int64) async throws {
        // The fixture only exercises a failed read; there is nothing to delete.
    }
}
