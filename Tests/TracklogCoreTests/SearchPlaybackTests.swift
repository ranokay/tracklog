import Foundation
import Testing
@testable import TracklogCore

@Suite("Search playback")
@MainActor
struct SearchPlaybackTests {
    @MainActor
    private final class Spy {
        var opened: [URL] = []
        var settingsCalls = 0
        var openResult = true
        var settingsResult = true

        func open(_ url: URL) -> Bool {
            opened.append(url)
            return openResult
        }

        func settings() -> Bool {
            settingsCalls += 1
            return settingsResult
        }
    }

    private func row(
        group: CatalogueGroupKind = .tracks,
        title: String = "Heart of Glass",
        subtitle: String = "Blondie",
        query: String = "Blondie Heart of Glass",
        page: URL? = URL(string: "https://www.last.fm/music/Blondie/_/Heart+of+Glass"),
    ) -> CatalogueRow {
        CatalogueRow(
            group: group,
            title: title,
            subtitle: subtitle,
            playbackQuery: query,
            pageURL: page,
        )
    }

    private func playback(template: SearchTemplate?, spy: Spy) -> SearchPlayback {
        SearchPlayback(
            template: template,
            openURL: { spy.open($0) },
            openSettings: { spy.settings() },
        )
    }

    @Test func aSetTemplatePlaysTheEncodedRowQuery() throws {
        let template = try SearchTemplate.parse("https://music.example/search?q={query}").get()
        let spy = Spy()
        let action = playback(template: template, spy: spy)

        let outcome = action.performPrimary(row())

        let url = try #require(spy.opened.first)
        #expect(url.absoluteString == "https://music.example/search?q=Blondie%20Heart%20of%20Glass")
        #expect(outcome == .opened(url))
    }

    @Test func withoutATemplateThePaletteRowOpensItsLastFMPage() throws {
        let spy = Spy()
        let action = playback(template: nil, spy: spy)

        let outcome = action.performPrimary(row())

        #expect(try spy.opened == [#require(URL(string: "https://www.last.fm/music/Blondie/_/Heart+of+Glass"))])
        #expect(try outcome == .opened(#require(spy.opened.first)))
    }

    @Test func withoutATemplateTheStandalonePlayActionOpensSearchSettings() {
        let spy = Spy()
        let action = playback(template: nil, spy: spy)

        let outcome = action.play(query: "Blondie Heart of Glass")

        #expect(outcome == .openedSettings)
        #expect(spy.settingsCalls == 1)
        #expect(spy.opened.isEmpty)
    }

    @Test func aRefusedSettingsHandoffIsReported() {
        let spy = Spy()
        spy.settingsResult = false
        let action = playback(template: nil, spy: spy)

        let outcome = action.play(query: "Blondie Heart of Glass")

        #expect(outcome == .settingsRefused)
        #expect(outcome.failureMessage?.contains("Settings") == true)
    }

    @Test func aRefusedLaunchIsReportedAndNotSwallowed() throws {
        let template = try SearchTemplate.parse("https://music.example/search?q={query}").get()
        let spy = Spy()
        spy.openResult = false
        let action = playback(template: template, spy: spy)

        let outcome = action.play(query: "Blondie Heart of Glass")

        guard case let .refused(url) = outcome else {
            Issue.record("expected a refused launch, got \(outcome)")
            return
        }
        #expect(url.absoluteString == "https://music.example/search?q=Blondie%20Heart%20of%20Glass")
        #expect(outcome.failureMessage?.contains("could not be opened") == true)
    }

    @Test func aRowWithoutAValidPageOffersNoLastFMAction() {
        let action = playback(template: nil, spy: Spy())
        let noPage = row(page: nil)

        #expect(action.performPrimary(noPage) == .noPage)
        #expect(action.openLastFMPage(noPage) == .noPage)
        #expect(PlaybackOutcome.noPage.failureMessage?.contains("No Last.fm page") == true)
    }

    @Test func anEmptyQueryDoesNotOpenAnything() throws {
        let template = try SearchTemplate.parse("https://music.example/search?q={query}").get()
        let spy = Spy()
        let action = playback(template: template, spy: spy)

        #expect(action.play(query: "  ") == .noQuery)
        #expect(spy.opened.isEmpty)
    }

    @Test func queryBuildersUseTheAgreedArtistAlbumAndTrackShapes() {
        #expect(CatalogueQuery.artist(" Blondie ") == "Blondie")
        #expect(CatalogueQuery.album(artist: "Blondie", album: "Parallel Lines") == "Blondie Parallel Lines")
        #expect(CatalogueQuery.track(artist: "Blondie", title: "Heart of Glass") == "Blondie Heart of Glass")
        #expect(CatalogueQuery.track(artist: "", title: "Heart of Glass") == "Heart of Glass")
        #expect(CatalogueQuery.track(artist: "Blondie", title: "  ") == "Blondie")
        #expect(CatalogueQuery.track(artist: "", title: "") == "")
    }
}
