import Foundation
import Testing
@testable import TracklogCore

@Suite("Search template settings")
@MainActor
struct SearchTemplateSettingsTests: CaptureTestHelpers {
    private func runtime(
        persist: @escaping @MainActor (String?) -> Void,
    ) async throws -> (TemporaryDatabase, CaptureRuntime) {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let runtime = CaptureRuntime(
            clock: FakeClock(base),
            source: ReplayedNowPlaying(),
            store: store,
            allowlist: InMemoryAppAllowlist(),
            edits: store,
            blocks: store,
            persistPlaybackTemplate: persist,
        )
        return (database, runtime)
    }

    @Test func savingPublishesAndPersistsOnlyAValidTemplate() async throws {
        var writes: [String?] = []
        let (database, runtime) = try await runtime { writes.append($0) }
        defer { withExtendedLifetime(database) {} }

        #expect(runtime.state.playbackTemplate == nil)

        let raw = "https://music.example/search?q={query}"
        try runtime.savePlaybackTemplate(raw)
        #expect(runtime.state.playbackTemplate?.rawValue == raw)
        #expect(writes == [raw])

        do {
            try runtime.savePlaybackTemplate("https://music.example/search")
            Issue.record("a template without {query} should have been refused")
        } catch let error as SearchTemplateError {
            #expect(error == .missingPlaceholder)
        }
        #expect(runtime.state.playbackTemplate?.rawValue == raw)
        #expect(writes == [raw])

        runtime.removePlaybackTemplate()
        #expect(runtime.state.playbackTemplate == nil)
        #expect(writes == [raw, ""])
    }

    @Test func aComposedRuntimeLoadsTheSavedTemplate() throws {
        let raw = "https://music.example/search?q={query}"
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let runtime = CaptureRuntime(
            clock: FakeClock(base),
            source: ReplayedNowPlaying(),
            store: store,
            allowlist: InMemoryAppAllowlist(),
            edits: store,
            blocks: store,
            playbackTemplate: SearchTemplate.parseOrNil(raw),
        )
        defer { withExtendedLifetime(database) {} }

        #expect(runtime.state.playbackTemplate?.rawValue == raw)
        #expect(runtime.state.playbackTemplate?.url(for: "Heart of Glass")?.absoluteString
            == "https://music.example/search?q=Heart%20of%20Glass")
    }
}
