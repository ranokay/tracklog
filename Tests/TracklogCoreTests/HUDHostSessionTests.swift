import Foundation
import Testing
@testable import TracklogCore

@Suite("HUD host session")
@MainActor
struct HUDHostSessionTests {
    @Test func anAcceptedPresentationAnnouncesExactlyOnce() {
        let host = RecordingHUDHost()
        let probe = HUDAnnouncementProbe()
        let session = probe.makeSession(host: host)
        let presentation = HUD.resolve(.rateLimited(services: ["Last.fm"]))

        session.show(presentation)

        #expect(host.presented == [presentation])
        #expect(probe.announcements == [presentation.spoken])
        #expect(probe.refusals.isEmpty)
        #expect(session.activeID == presentation.id)
    }

    @Test func aRefusalIsLoggedAndAnnouncesNothing() {
        let host = RecordingHUDHost(accepted: false)
        let probe = HUDAnnouncementProbe()
        let session = probe.makeSession(host: host)
        let presentation = HUD.resolve(.paused(.duration(60 * 60)))

        session.show(presentation)

        #expect(host.presented == [presentation])
        #expect(probe.announcements.isEmpty)
        #expect(probe.refusals == [presentation])
        #expect(session.activeID == nil)
        #expect(host.presentations.count == 1, "a refusal is never retried")
    }

    @Test func aDifferentPresentationReplacesOurOwnHUD() {
        let host = RecordingHUDHost()
        let probe = HUDAnnouncementProbe()
        let session = probe.makeSession(host: host)
        let first = HUD.resolve(.paused(.duration(60 * 60)))
        let second = HUD.resolve(.blocked(title: "Heart of Glass"))

        session.show(first)
        session.show(second)

        #expect(host.dismissals == [first.id])
        #expect(host.presented == [first, second])
        #expect(probe.announcements == [first.spoken, second.spoken])
        #expect(session.activeID == second.id)
    }

    @Test func theSameIdentifierReplacesInPlaceWithoutDismissing() {
        let host = RecordingHUDHost()
        let probe = HUDAnnouncementProbe()
        let session = probe.makeSession(host: host)
        let first = HUD.resolve(.rateLimited(services: ["Last.fm"]))
        let repeated = HUD.resolve(.rateLimited(services: ["Last.fm", "ListenBrainz"]))

        session.show(first)
        session.show(repeated)

        #expect(host.dismissals.isEmpty)
        #expect(host.presented == [first, repeated])
        #expect(probe.announcements == [first.spoken, repeated.spoken])
        #expect(session.activeID == repeated.id)
    }

    @Test func anotherOwnersRefusalIsFinalAfterOurOwnHUDIsDismissed() {
        let host = RecordingHUDHost()
        let probe = HUDAnnouncementProbe()
        let session = probe.makeSession(host: host)
        let first = HUD.resolve(.paused(.duration(60 * 60)))
        let second = HUD.resolve(.blocked(title: "Heart of Glass"))

        session.show(first)
        host.accepted = false
        session.show(second)

        #expect(host.dismissals == [first.id], "our own HUD is replaced, not queued")
        #expect(host.presented == [first, second])
        #expect(probe.announcements == [first.spoken])
        #expect(probe.refusals == [second])
        #expect(session.activeID == nil)

        session.deactivate()
        #expect(host.dismissals == [first.id], "a refused replacement leaves nothing to dismiss")
    }

    @Test func deactivateDismissesTheActiveHUDOnce() {
        let host = RecordingHUDHost()
        let probe = HUDAnnouncementProbe()
        let session = probe.makeSession(host: host)
        let presentation = HUD.resolve(.resumed)

        session.show(presentation)
        session.deactivate()
        session.deactivate()

        #expect(host.dismissals == [presentation.id])
        #expect(session.activeID == nil)
    }

    @Test func aRefusalWhenNothingIsActiveNeitherAnnouncesNorDismisses() {
        let host = RecordingHUDHost(accepted: false)
        let probe = HUDAnnouncementProbe()
        let session = probe.makeSession(host: host)

        session.show(HUD.resolve(.exported))

        #expect(host.dismissals.isEmpty)
        #expect(probe.announcements.isEmpty)
        #expect(probe.refusals.count == 1)
    }
}

/// A fake host and the observable announcement/refusal ports the production
/// adapter uses.
@MainActor
final class RecordingHUDHost: HUDHosting {
    var accepted: Bool
    private(set) var presented: [HUDPresentation] = []
    private(set) var dismissals: [String] = []

    var presentations: [HUDPresentation] {
        presented
    }

    init(accepted: Bool = true) {
        self.accepted = accepted
    }

    func present(_ presentation: HUDPresentation) -> Bool {
        presented.append(presentation)
        return accepted
    }

    func dismiss(id: String) {
        dismissals.append(id)
    }
}

/// The announcement and refusal ports, recorded so a test can assert exactly
/// what the production AppKit adapter would receive.
@MainActor
final class HUDAnnouncementProbe {
    private(set) var announcements: [String] = []
    private(set) var refusals: [HUDPresentation] = []

    func makeSession(host: any HUDHosting) -> HUDHostSession {
        HUDHostSession(
            host: host,
            announce: { [self] presentation in
                announcements.append(presentation.spoken)
            },
            logRefusal: { [self] presentation in
                refusals.append(presentation)
            },
        )
    }
}
