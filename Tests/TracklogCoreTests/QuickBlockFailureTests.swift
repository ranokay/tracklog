import Foundation
import Testing
@testable import TracklogCore

/// A quick block has no form for an error, so a failed save shows the
/// "Not blocked" strip. The Blocks settings page keeps its inline error.
@Suite("Quick block failure")
@MainActor
struct QuickBlockFailureTests: CaptureTestHelpers {
    private func runtime(
        store: SQLiteListenStore,
        probe: HUDProbe,
        source: ReplayedNowPlaying = ReplayedNowPlaying(),
    ) -> CaptureRuntime {
        CaptureRuntime(
            state: TracklogAppState(),
            clock: FakeClock(base),
            source: source,
            store: store,
            allowlist: InMemoryAppAllowlist(),
            edits: store,
            blocks: WriteFailingBlockStore(),
            credentials: MemoryCredentialStore(),
            serviceAdapters: [],
            hud: probe.session,
            settings: CaptureSettings(scrobblingEnabled: true),
        )
    }

    @Test func aFailedHistoryRowBlockShowsTheNotBlockedStrip() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let probe = HUDProbe()
        let listen = try await insertHistoryListen(store, title: "Song", base: base)
        let runtime = runtime(store: store, probe: probe)
        await runtime.start()

        await #expect(throws: DatabaseError.self) {
            try await runtime.quickBlock(listen)
        }

        let strip = try #require(probe.presentations.last)
        #expect(strip.id == HUDIdentifier.failureBlock)
        #expect(strip.word == "Not blocked")
        #expect(probe.announcements.last == "Could not block Song. It may still scrobble.")
        #expect(!probe.presentations.contains { $0.id == HUDIdentifier.confirmBlock })
    }

    @Test func aFailedCurrentTrackBlockShowsTheNotBlockedStrip() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let probe = HUDProbe()
        let runtime = runtime(store: store, probe: probe)
        await runtime.start()
        await runtime.ingest(sample(track(title: "Live Song", artist: "Artist"), at: 2, elapsed: 2))

        await #expect(throws: DatabaseError.self) {
            try await runtime.quickBlockCurrentTrack()
        }

        #expect(probe.presentations.last?.id == HUDIdentifier.failureBlock)
        #expect(probe.announcements.last == "Could not block Live Song. It may still scrobble.")
    }
}

/// Reads succeed with no blocks; every save fails the way a full disk or a
/// locked database would.
private actor WriteFailingBlockStore: BlockStore {
    func blocks() async throws -> [BlockRule] {
        []
    }

    func save(_: BlockRule) async throws -> BlockRule {
        throw DatabaseError.sqlite("disk I/O error")
    }

    func deleteBlock(id _: Int64) async throws {
        // Deletion is not exercised by these tests.
    }
}
