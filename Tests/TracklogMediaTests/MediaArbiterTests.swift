import Foundation
import Testing
import TracklogCore
import TracklogMedia

@Suite("Media arbiter")
@MainActor
struct MediaArbiterTests {
    @Test func aHelperSampleWinsAndPollsAtThePlayingCadence() async {
        let sample = playingSample()
        let helper = FakeHelper(results: [.sample(sample)])
        let automation = FakeAutomation()
        let gate = FakePermissionGate()
        let arbiter = makeArbiter(helper: helper, automation: automation, gate: gate, running: ["com.apple.Music"])

        let poll = await arbiter.pollOnce()

        #expect(poll.emission == .sample(sample))
        #expect(poll.interval == .seconds(2))
        #expect(arbiter.mediaStatus.source == .helper)
        #expect(arbiter.mediaStatus.helperHealth == .working)
        #expect(automation.probed.isEmpty, "a speaking helper must not be shadowed by Automation")
    }

    @Test func anEmptyHelperSampleClearsNowPlayingAndPollsAtTheIdleCadence() async {
        let sample = playingSample()
        let helper = FakeHelper(results: [.sample(sample), .empty])
        let arbiter = makeArbiter(helper: helper, running: [])

        let playing = await arbiter.pollOnce()
        let idle = await arbiter.pollOnce()

        #expect(playing.emission == .sample(sample))
        #expect(playing.interval == .seconds(2))
        #expect(idle.emission == .sample(nil))
        #expect(idle.interval == .seconds(5))
        #expect(arbiter.mediaStatus.helperHealth == .silent)
    }

    @Test func twoQuietMinutesSlowTheIdleCadenceUntilSomethingPlays() async {
        var now = Date(timeIntervalSince1970: 1_000)
        let helper = FakeHelper(results: [.sample(playingSample()), .empty, .empty, .empty, .sample(playingSample()), .empty])
        let arbiter = makeArbiter(helper: helper, now: { now })

        #expect(await arbiter.pollOnce().interval == .seconds(2))
        now += 2
        #expect(await arbiter.pollOnce().interval == .seconds(5), "playback just stopped")
        now += 119
        #expect(await arbiter.pollOnce().interval == .seconds(5))
        now += 1
        #expect(await arbiter.pollOnce().interval == .seconds(15), "quiet for two minutes")
        now += 15
        #expect(await arbiter.pollOnce().interval == .seconds(2))
        now += 2
        #expect(await arbiter.pollOnce().interval == .seconds(5), "a new quiet stretch starts over")
    }

    @Test func theQuietCadenceFindsATrackInsideTheEngineLeadIn() {
        let quiet = TimeInterval(MediaArbiter.quietInterval.components.seconds)
        let slowReadAllowance: TimeInterval = 5

        #expect(quiet + slowReadAllowance <= ScrobbleEngine.Configuration().leadIn)
    }

    @Test func theRunningLoopUsesTheAdaptiveCadence() async {
        let helper = FakeHelper(results: [.sample(playingSample()), .empty])
        var sleeps: [Duration] = []
        var arbiter: MediaArbiter?
        let (finished, continuation) = AsyncStream<Void>.makeStream()
        arbiter = makeArbiter(
            helper: helper,
            running: [],
            sleeper: { duration in
                sleeps.append(duration)
                if sleeps.count == 2 {
                    continuation.yield()
                    arbiter?.stop()
                }
            },
        )

        arbiter?.start(
            onSample: { _ in
                // The loop test asserts cadence through the sleeper, not samples.
            },
            onStatus: { _ in
                // Status is read from the arbiter after each poll.
            },
        )
        for await _ in finished {
            break
        }

        #expect(sleeps == [.seconds(2), .seconds(5)])
    }

    @Test func everyHelperFailureIsASeparateHealthState() async {
        let missing = makeArbiter(
            helper: FakeHelper(
                executablePath: "/nonexistent/DroppyMediaHelper",
                isExecutable: false,
                results: [.missingExecutable],
            ),
            running: [],
        )
        let missingPoll = await missing.pollOnce()
        #expect(missingPoll.status.helperHealth == .missingExecutable)
        #expect(missingPoll.status.lastFailure == "Media helper is missing.")
        #expect(missingPoll.status.helperPath == "/nonexistent/DroppyMediaHelper")
        #expect(missingPoll.status.source == .unavailable)

        let helper = FakeHelper(results: [.spawnFailed("permission denied"), .exitedNonZero(3), .empty])
        let arbiter = makeArbiter(helper: helper, running: [])

        let spawn = await arbiter.pollOnce()
        #expect(spawn.status.helperHealth == .spawnFailed("permission denied"))
        #expect(spawn.status.lastFailure?.contains("permission denied") == true)

        let exit = await arbiter.pollOnce()
        #expect(exit.status.helperHealth == .exitedNonZero(3))
        #expect(exit.status.lastFailure?.contains("3") == true)

        let silent = await arbiter.pollOnce()
        #expect(silent.status.helperHealth == .silent)
        #expect(silent.status.lastFailure?.contains("3") == true, "the last failure stays in diagnostics")
    }

    @Test func theLiveSourceUsesTheNamesSettingsShows() {
        #expect(MediaSourceKind.helper.displayName == "Droppy helper")
        #expect(MediaSourceKind.musicAutomation.displayName == "Music via Automation")
        #expect(MediaSourceKind.spotifyAutomation.displayName == "Spotify via Automation")
        #expect(MediaSourceKind.unavailable.displayName == "Unavailable")
        #expect(MediaAutomationCandidate.defaults.map(\.bundleID) == ["com.apple.Music", "com.spotify.client"])
    }

    @Test func diagnosticsCarryTheHelperPathVersionsAndFailure() {
        let status = MediaStatus(
            source: .musicAutomation,
            helperHealth: .exitedNonZero(2),
            automation: .available,
            helperPath: "/Applications/Droppy.app/Contents/Helpers/DroppyMediaHelper.app/Contents/MacOS/DroppyMediaHelper",
            lastFailure: "Media helper exited with status 2",
        )

        let text = MediaDiagnostics.text(
            status: status,
            macOSVersion: "Version 15.6 (Build 24G90)",
            droppyVersion: "15.3.0",
        )

        #expect(text.contains("macOS: Version 15.6"))
        #expect(text.contains("Droppy version: 15.3.0"))
        #expect(text.contains("Media source: Music via Automation"))
        #expect(text.contains("Helper path: /Applications/Droppy.app/"))
        #expect(text.contains("Last failure: Media helper exited with status 2"))
    }

    @Test func feedAvailabilityNeedsOneUsableSource() {
        let fallbackPossible = MediaStatus(
            source: .unavailable,
            helperHealth: .missingExecutable,
            automation: .notRequested,
            helperPath: "/helper",
        )
        let bothGone = MediaStatus(
            source: .unavailable,
            helperHealth: .missingExecutable,
            automation: .denied,
            helperPath: "/helper",
        )
        let helperOnly = MediaStatus(
            source: .helper,
            helperHealth: .working,
            automation: .denied,
            helperPath: "/helper",
        )

        #expect(fallbackPossible.isAvailable)
        #expect(bothGone.isAvailable == false)
        #expect(helperOnly.isAvailable)
    }
}

@Suite("Media arbiter artwork")
@MainActor
struct MediaArbiterArtworkTests {
    @Test func artworkIsReadOnlyForTheTrackThatIsPlaying() async {
        let sample = playingSample()
        let bytes = Data([9, 8, 7])
        let helper = FakeHelper(results: [.sample(sample)])
        helper.artworkRead = .snapshot(MediaHelperSnapshot(sample: sample, artwork: bytes))
        let arbiter = makeArbiter(helper: helper)

        _ = await arbiter.pollOnce()

        #expect(await arbiter.artwork(for: sample.track) == bytes)
        #expect(helper.artworkReadCount == 1)
        #expect(await arbiter.artwork(for: playingSample(title: "Another Song").track) == nil)
    }

    @Test func aHelperSnapshotForAnotherTrackIsNotUsed() async {
        let sample = playingSample()
        let helper = FakeHelper(results: [.sample(sample)])
        helper.artworkRead = .snapshot(MediaHelperSnapshot(
            sample: playingSample(title: "Another Song"),
            artwork: Data([1]),
        ))
        let arbiter = makeArbiter(helper: helper)

        _ = await arbiter.pollOnce()

        #expect(await arbiter.artwork(for: sample.track) == nil)
    }

    @Test func anAutomationTrackNeverAsksTheHelperForArtwork() async {
        let sample = playingSample(bundleID: "com.apple.Music")
        let helper = FakeHelper(results: [.empty])
        helper.artworkRead = .snapshot(MediaHelperSnapshot(sample: sample, artwork: Data([1])))
        let automation = FakeAutomation(results: ["com.apple.Music": .playing(sample)])
        let arbiter = makeArbiter(helper: helper, automation: automation, running: ["com.apple.Music"])

        _ = await arbiter.pollOnce()
        let artwork = await arbiter.artwork(for: sample.track)

        #expect(arbiter.mediaStatus.source == .musicAutomation)
        #expect(artwork == nil)
        #expect(helper.artworkReadCount == 0)
    }

    @Test func aMissingHelperHasNoArtwork() async {
        let sample = playingSample()
        let helper = FakeHelper(
            executablePath: FileManager.default.temporaryDirectory
                .appendingPathComponent("missing-media-helper")
                .path,
            isExecutable: false,
            results: [.missingExecutable],
        )
        let arbiter = makeArbiter(helper: helper)

        #expect(await arbiter.artwork(for: sample.track) == nil)
        #expect(helper.artworkReadCount == 0)
    }
}
