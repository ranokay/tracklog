import Foundation
import Testing
import TracklogCore
import TracklogMedia

@Suite("Media automation fallback")
@MainActor
struct MediaAutomationFallbackTests {
    @Test func automationFillsASilenceForARunningPlayingCandidate() async {
        let sample = playingSample()
        let automation = FakeAutomation(results: ["com.apple.Music": .playing(sample)])
        let helper = FakeHelper(results: [.empty])
        let arbiter = makeArbiter(
            helper: helper,
            automation: automation,
            gate: FakePermissionGate(),
            running: ["com.apple.Music"],
        )

        let poll = await arbiter.pollOnce()

        #expect(poll.emission == .sample(sample))
        #expect(poll.interval == .seconds(2))
        #expect(poll.status.source == .musicAutomation)
        #expect(poll.status.helperHealth == .silentWhilePlaying("Music"))
        #expect(poll.status.automation == .available)
        #expect(poll.status.lastFailure == "Media helper returned no track while Music was playing.")
        #expect(automation.probed == ["com.apple.Music"])
    }

    @Test func aPausedAutomationSourceKeepsTheSessionInsteadOfClearingIt() async {
        var now = Date(timeIntervalSince1970: 1_000)
        let playing = playingSample()
        let resumed = playingSample(elapsed: 44, timestamp: Date(timeIntervalSince1970: 1_010))
        let automation = FakeAutomation()
        automation.sequences["com.apple.Music"] = [.playing(playing), .paused, .playing(resumed)]
        let arbiter = makeArbiter(
            helper: FakeHelper(results: [.empty]),
            automation: automation,
            gate: FakePermissionGate(),
            running: ["com.apple.Music"],
            now: { now },
        )

        let first = await arbiter.pollOnce()
        now += 5
        let paused = await arbiter.pollOnce()
        now += 5
        let resumedPoll = await arbiter.pollOnce()

        #expect(first.emission == .sample(playing))
        #expect(first.status.helperHealth == .silentWhilePlaying("Music"))

        guard case let .sample(pausedSample?) = paused.emission else {
            Issue.record("a pause must keep the observation, not emit nil")
            return
        }
        #expect(pausedSample.isPlaying == false)
        #expect(pausedSample.track == playing.track)
        #expect(paused.status.helperHealth == .silent)

        #expect(resumedPoll.emission == .sample(resumed))
        #expect(resumedPoll.status.source == .musicAutomation)
        #expect(resumedPoll.status.helperHealth == .silentWhilePlaying("Music"))
    }

    @Test func aProbeDenialIsWrittenToTheGate() async {
        let gate = FakePermissionGate(status: .available)
        let automation = FakeAutomation(results: ["com.apple.Music": .denied])
        let arbiter = makeArbiter(
            helper: FakeHelper(results: [.empty]),
            automation: automation,
            gate: gate,
            running: ["com.apple.Music"],
        )

        let denied = await arbiter.pollOnce()
        #expect(denied.status.automation == .denied)
        #expect(gate.status == .denied, "a probe's TCC denial is persisted through the gate")
        #expect(gate.requestCalls == 0)

        let nextLaunch = makeArbiter(
            helper: FakeHelper(results: [.empty]),
            automation: FakeAutomation(),
            gate: gate,
            running: ["com.apple.Music"],
        )
        _ = await nextLaunch.pollOnce()
        #expect(gate.requestCalls == 0, "the next launch does not ask again")
    }

    @Test func aWorkingHelperNeverAsksForAutomation() async {
        let helper = FakeHelper(results: [.sample(playingSample())])
        let automation = FakeAutomation(results: ["com.apple.Music": .playing(playingSample())])
        let gate = FakePermissionGate()
        let arbiter = makeArbiter(
            helper: helper,
            automation: automation,
            gate: gate,
            running: ["com.apple.Music"],
        )

        _ = await arbiter.pollOnce()

        #expect(gate.authorizationCalls == 0)
        #expect(gate.requestCalls == 0)
        #expect(automation.probed.isEmpty)
    }

    @Test func automationIsNotProbedWhenNoCandidateIsRunning() async {
        let automation = FakeAutomation(results: ["com.apple.Music": .playing(playingSample())])
        let gate = FakePermissionGate(status: .notRequested)
        let arbiter = makeArbiter(
            helper: FakeHelper(results: [.empty]),
            automation: automation,
            gate: gate,
            running: [],
        )

        let poll = await arbiter.pollOnce()

        #expect(poll.emission == .none)
        #expect(poll.status.source == .helper)
        #expect(automation.probed.isEmpty)
        #expect(gate.requestCalls == 0, "nothing is playing, so Automation is not needed yet")
    }

    @Test func automationProbesOncePerCandidateAtTheIdleCadence() async {
        var now = Date(timeIntervalSince1970: 1_000)
        let automation = FakeAutomation()
        let arbiter = makeArbiter(
            helper: FakeHelper(results: [.empty]),
            automation: automation,
            gate: FakePermissionGate(),
            running: ["com.apple.Music", "com.spotify.client"],
            now: { now },
        )

        let first = await arbiter.pollOnce()
        #expect(first.interval == .seconds(5))
        #expect(automation.probed == ["com.apple.Music", "com.spotify.client"])

        now += 2
        _ = await arbiter.pollOnce()
        #expect(automation.probed.count == 2, "the helper polls fast, the probes wait for the idle cadence")

        now += 3
        _ = await arbiter.pollOnce()
        #expect(automation.probed == [
            "com.apple.Music",
            "com.spotify.client",
            "com.apple.Music",
            "com.spotify.client",
        ])
    }

    @Test func automationAsksLazilyAtTheFirstFallback() async {
        let gate = FakePermissionGate(status: .notRequested, requestResult: .available)
        let arbiter = makeArbiter(
            helper: FakeHelper(results: [.empty]),
            gate: gate,
            running: ["com.apple.Music"],
        )

        #expect(gate.authorizationCalls == 0, "constructing the arbiter does not touch TCC")
        #expect(gate.requestCalls == 0)

        _ = await arbiter.pollOnce()

        #expect(gate.requestCalls == 1)
        #expect(arbiter.mediaStatus.automation == .available)
    }

    @Test func aForgottenDenialCanBeRequestedAgain() async {
        var now = Date(timeIntervalSince1970: 1_000)
        let gate = FakePermissionGate(status: .notRequested, requestResult: .denied)
        let arbiter = makeArbiter(
            helper: FakeHelper(results: [.empty]),
            gate: gate,
            running: ["com.apple.Music"],
            now: { now },
        )

        _ = await arbiter.pollOnce()
        #expect(gate.requestCalls == 1)

        gate.forgetDenial()
        gate.requestResult = .available
        now += 5
        _ = await arbiter.pollOnce()

        #expect(gate.requestCalls == 2)
        #expect(arbiter.mediaStatus.automation == .available)
    }

    @Test func aDenialIsRememberedAndHelperOnlyOperationContinues() async {
        let sample = playingSample()
        let gate = FakePermissionGate(status: .notRequested, requestResult: .denied)
        let helper = FakeHelper(results: [.empty, .sample(sample)])
        let arbiter = makeArbiter(
            helper: helper,
            automation: FakeAutomation(),
            gate: gate,
            running: ["com.apple.Music"],
        )

        let denied = await arbiter.pollOnce()
        #expect(denied.status.automation == .denied)
        #expect(denied.status.source == .helper)
        #expect(gate.requestCalls == 1)

        let helperOnly = await arbiter.pollOnce()
        #expect(helperOnly.emission == .sample(sample))
        #expect(helperOnly.status.source == .helper)
        #expect(helperOnly.status.automation == .denied)
        #expect(gate.requestCalls == 1, "a denied helper-only session never asks again")

        let nextLaunch = makeArbiter(
            helper: FakeHelper(results: [.empty]),
            automation: FakeAutomation(),
            gate: gate,
            running: ["com.apple.Music"],
        )
        _ = await nextLaunch.pollOnce()
        #expect(nextLaunch.mediaStatus.automation == .denied)
        #expect(gate.requestCalls == 1, "the remembered denial survives a new arbiter")
    }

    @Test func theHelperTakesOverFromAutomationWithoutAGap() async {
        let automationSample = playingSample(elapsed: 44, timestamp: Date(timeIntervalSince1970: 1_000))
        let helperSample = playingSample(elapsed: 46, timestamp: Date(timeIntervalSince1970: 1_002))
        let automation = FakeAutomation(results: ["com.apple.Music": .playing(automationSample)])
        let arbiter = makeArbiter(
            helper: FakeHelper(results: [.empty, .sample(helperSample)]),
            automation: automation,
            gate: FakePermissionGate(),
            running: ["com.apple.Music"],
        )

        let fallback = await arbiter.pollOnce()
        let recovery = await arbiter.pollOnce()

        #expect(fallback.emission == .sample(automationSample))
        #expect(recovery.emission == .sample(helperSample))
        #expect(recovery.status.source == .helper)

        // The samples the arbiter emits at the switch continue one engine
        // session, so no play is lost or duplicated.
        let engine = ScrobbleEngine()
        _ = engine.ingest(automationSample)
        let before = engine.status
        _ = engine.ingest(helperSample)
        #expect(engine.status.track == helperSample.track)
        #expect(engine.status.played == 2)
        #expect(before.played == 0)
    }

    @Test func automationUsesTheFirstPlayingCandidate() async {
        let music = playingSample()
        let spotify = playingSample(bundleID: "com.spotify.client")
        let automation = FakeAutomation(results: [
            "com.apple.Music": .playing(music),
            "com.spotify.client": .playing(spotify),
        ])
        let arbiter = makeArbiter(
            helper: FakeHelper(results: [.empty]),
            automation: automation,
            gate: FakePermissionGate(),
            running: ["com.apple.Music", "com.spotify.client"],
        )

        let poll = await arbiter.pollOnce()

        #expect(poll.emission == .sample(music))
        #expect(poll.status.source == .musicAutomation)
        #expect(automation.probed == ["com.apple.Music"], "one source speaks at a time")
    }

    @Test func automationNamesSpotifyWhenMusicIsPaused() async {
        let spotify = playingSample(bundleID: "com.spotify.client")
        let automation = FakeAutomation(results: ["com.spotify.client": .playing(spotify)])
        let arbiter = makeArbiter(
            helper: FakeHelper(results: [.empty]),
            automation: automation,
            gate: FakePermissionGate(),
            running: ["com.apple.Music", "com.spotify.client"],
        )

        let poll = await arbiter.pollOnce()

        #expect(poll.emission == .sample(spotify))
        #expect(poll.status.source == .spotifyAutomation)
        #expect(automation.probed == ["com.apple.Music", "com.spotify.client"])
    }
}
