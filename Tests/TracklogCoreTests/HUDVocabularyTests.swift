import Foundation
import Testing
@testable import TracklogCore

@Suite("HUD vocabulary")
struct HUDVocabularyTests {
    @Test func failureCardsUseTheExactCopyAndActions() {
        let one = HUD.resolve(.needsSignIn(services: ["Last.fm"]))
        #expect(one.id == "hud.failure.signin")
        #expect(one.duration == 8)
        #expect(one.priority == .normal)
        #expect(one.shape == .card)
        #expect(one.title == "Last.fm needs sign-in")
        #expect(one.detail == "Scrobbles are waiting")
        #expect(one.spoken == "Last.fm needs sign-in. Scrobbles are waiting.")
        #expect(one.action == .signIn)

        let many = HUD.resolve(.needsSignIn(services: ["Last.fm", "ListenBrainz"]))
        #expect(many.title == "2 services need sign-in")
        #expect(many.detail == "Scrobbles are waiting")
        #expect(many.spoken == "Last.fm and ListenBrainz need sign-in. Scrobbles are waiting.")
        #expect(many.action == .signIn)

        let stuckOne = HUD.resolve(.stuckQueue(count: 12, services: ["Last.fm"]))
        #expect(stuckOne.id == "hud.failure.stuck")
        #expect(stuckOne.duration == 8)
        #expect(stuckOne.priority == .normal)
        #expect(stuckOne.shape == .card)
        #expect(stuckOne.title == "12 scrobbles waiting")
        #expect(stuckOne.detail == "Last.fm is not accepting them")
        #expect(stuckOne.spoken == "12 scrobbles are waiting for Last.fm, which is not accepting them.")
        #expect(stuckOne.action == .review)

        let stuckMany = HUD.resolve(.stuckQueue(count: 12, services: ["Last.fm", "ListenBrainz"]))
        #expect(stuckMany.title == "12 scrobbles waiting")
        #expect(stuckMany.detail == "Across 2 services")
        #expect(stuckMany.spoken == "12 scrobbles are waiting across 2 services.")
        #expect(stuckMany.action == .review)
    }

    @Test func stuckCountsUseSingularGrammar() {
        let one = HUD.resolve(.stuckQueue(count: 1, services: ["Last.fm"]))
        #expect(one.title == "1 scrobble waiting")
        #expect(one.detail == "Last.fm is not accepting it")
        #expect(one.spoken == "1 scrobble is waiting for Last.fm, which is not accepting it.")
    }

    @Test func failureStripsUseTheExactGlyphsWordsAndSpeech() {
        let rateOne = HUD.resolve(.rateLimited(services: ["Last.fm"]))
        #expect(rateOne.id == "hud.failure.ratelimit")
        #expect(rateOne.duration == 4)
        #expect(rateOne.priority == .normal)
        #expect(rateOne.shape == .strip)
        #expect(rateOne.glyph == "clock.arrow.circlepath")
        #expect(rateOne.word == "Retrying")
        #expect(rateOne.spoken == "Last.fm is rate limited. Retrying automatically.")
        #expect(rateOne.action == nil)

        let rateMany = HUD.resolve(.rateLimited(services: ["Last.fm", "ListenBrainz"]))
        #expect(rateMany.spoken == "2 services are rate limited. Retrying automatically.")

        let media = HUD.resolve(.mediaFeedUnavailable)
        #expect(media.id == "hud.failure.media")
        #expect(media.duration == 4)
        #expect(media.priority == .normal)
        #expect(media.shape == .strip)
        #expect(media.glyph == "waveform.slash")
        #expect(media.word == "No feed")
        #expect(media.spoken == "Media feed unavailable. Playback will not be scrobbled.")
    }

    @Test func confirmationsUseTheExactCopyAndMechanics() {
        let loved = HUD.resolve(.loved(services: ["Last.fm"]))
        #expect(loved.id == "hud.confirm.love")
        #expect(loved.duration == 2)
        #expect(loved.priority == .high)
        #expect(loved.shape == .strip)
        #expect(loved.glyph == "heart.fill")
        #expect(loved.word == "Loved")
        #expect(loved.spoken == "Loved on Last.fm.")

        let lovedMany = HUD.resolve(.loved(services: ["Last.fm", "Libre.fm", "ListenBrainz"]))
        #expect(lovedMany.spoken == "Loved on 3 services.")

        let unloved = HUD.resolve(.unloved(services: ["Last.fm", "Libre.fm", "ListenBrainz"]))
        #expect(unloved.id == "hud.confirm.unlove")
        #expect(unloved.glyph == "heart")
        #expect(unloved.word == "Unloved")
        #expect(unloved.spoken == "Unloved on 3 services.")

        let hated = HUD.resolve(.hated(service: "ListenBrainz"))
        #expect(hated.id == "hud.confirm.hate")
        #expect(hated.glyph == "heart.slash.fill")
        #expect(hated.word == "Hated")
        #expect(hated.spoken == "Hated on ListenBrainz.")

        let blocked = HUD.resolve(.blocked(title: "Heart of Glass"))
        #expect(blocked.id == "hud.confirm.block")
        #expect(blocked.glyph == "hand.raised.fill")
        #expect(blocked.word == "Blocked")
        #expect(blocked.spoken == "Blocked Heart of Glass. It will not scrobble again.")

        let paused = HUD.resolve(.paused(.duration(60 * 60)))
        #expect(paused.id == "hud.confirm.pause")
        #expect(paused.duration == 2)
        #expect(paused.priority == .high)
        #expect(paused.glyph == "pause.fill")
        #expect(paused.word == "Paused")
        #expect(paused.spoken == "Scrobbling paused for 1 hour.")

        let pausedHalfHour = HUD.resolve(.paused(.duration(30 * 60)))
        #expect(pausedHalfHour.spoken == "Scrobbling paused for 30 minutes.")

        let resumed = HUD.resolve(.resumed)
        #expect(resumed.id == "hud.confirm.resume")
        #expect(resumed.glyph == "play.fill")
        #expect(resumed.word == "Resumed")
        #expect(resumed.spoken == "Scrobbling resumed.")

        let exported = HUD.resolve(.exported)
        #expect(exported.id == "hud.confirm.export")
        #expect(exported.glyph == "square.and.arrow.up")
        #expect(exported.word == "Exported")
        #expect(exported.spoken == "Settings exported.")
    }

    @Test func pauseUntilSpeaksTheClockTime() throws {
        var components = DateComponents()
        components.year = 2026
        components.month = 10
        components.day = 29
        components.hour = 14
        components.minute = 0
        let date = try #require(Calendar.current.date(from: components))

        let paused = HUD.resolve(.paused(.until(date)))
        #expect(paused.spoken == "Scrobbling paused until 14:00.")
    }

    @Test func recoveriesUseTheExactCopyAndMechanics() {
        let signedIn = HUD.resolve(.signedIn(service: "Last.fm", delivered: 4))
        #expect(signedIn.id == "hud.recovery.signin")
        #expect(signedIn.duration == 2)
        #expect(signedIn.priority == .low)
        #expect(signedIn.shape == .strip)
        #expect(signedIn.glyph == "checkmark.circle.fill")
        #expect(signedIn.word == "Signed in")
        #expect(signedIn.spoken == "Last.fm reconnected. 4 scrobbles sent.")

        let one = HUD.resolve(.signedIn(service: "Last.fm", delivered: 1))
        #expect(one.spoken == "Last.fm reconnected. 1 scrobble sent.")

        let caughtUp = HUD.resolve(.caughtUp(service: "Last.fm", delivered: 12))
        #expect(caughtUp.id == "hud.recovery.queue")
        #expect(caughtUp.duration == 2)
        #expect(caughtUp.priority == .low)
        #expect(caughtUp.shape == .strip)
        #expect(caughtUp.glyph == "checkmark.circle.fill")
        #expect(caughtUp.word == "Sent")
        #expect(caughtUp.spoken == "Last.fm is accepting scrobbles again. 12 sent.")
    }

    @Test func aggregationSpeaksNamedServicesForTwoAndThree() {
        let two = HUD.resolve(.needsSignIn(services: ["Last.fm", "ListenBrainz"]))
        #expect(two.spoken == "Last.fm and ListenBrainz need sign-in. Scrobbles are waiting.")

        let three = HUD.resolve(
            .needsSignIn(services: ["Last.fm", "Libre.fm", "ListenBrainz"]),
        )
        #expect(three.title == "3 services need sign-in")
        #expect(three.spoken == "Last.fm, Libre.fm and ListenBrainz need sign-in. Scrobbles are waiting.")
    }

    @Test func repeatsShareTheSameStableIdentifier() {
        #expect(
            HUD.resolve(.rateLimited(services: ["Last.fm"])).id
                == HUD.resolve(.rateLimited(services: ["Last.fm", "ListenBrainz"])).id,
        )
        #expect(
            HUD.resolve(.loved(services: ["Last.fm"])).id
                == HUD.resolve(.loved(services: ["Last.fm", "Libre.fm"])).id,
        )
        #expect(HUD.resolve(.resumed).id == "hud.confirm.resume")
    }

    @Test func customEndpointsUseTheirTruncatedHostName() throws {
        let endpoint = try #require(ServiceEndpoint(normalizing: "https://www.music.example.com"))
        let connection = Connection(
            kind: .libreFM,
            endpoint: endpoint,
            identity: "listener",
            createdAt: Date(timeIntervalSince1970: 1_000_000),
        )
        #expect(connection.hudServiceName == "music.example.com")

        let long = try #require(
            ServiceEndpoint(normalizing: "https://a-very-long-listening-server-name.example.com"),
        )
        let longConnection = Connection(
            kind: .libreFM,
            endpoint: long,
            identity: "listener",
            createdAt: Date(timeIntervalSince1970: 1_000_000),
        )
        #expect(longConnection.hudServiceName.count == 24)
        #expect(longConnection.hudServiceName.hasSuffix("…"))
        #expect(Connection(
            kind: .lastFM,
            endpoint: .lastFM,
            identity: "listener",
            createdAt: Date(timeIntervalSince1970: 1_000_000),
        ).hudServiceName == "Last.fm")
    }
}
