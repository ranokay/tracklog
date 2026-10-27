import Foundation
import Testing
import TracklogCore
import TracklogMedia

@Suite("Media automation cadence")
@MainActor
struct MediaAutomationCadenceTests {
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

    @Test func automationSamplesStayInsideTheEngineSampleGap() async {
        var now = Date(timeIntervalSince1970: 1_000)
        let automation = FakeAutomation()
        let samples = (0 ..< 4).map { index in
            playingSample(
                elapsed: 40 + Double(index * 2),
                timestamp: Date(timeIntervalSince1970: 1_000 + Double(index * 2)),
            )
        }
        automation.sequences["com.apple.Music"] = samples.map { .playing($0) }
        let arbiter = makeArbiter(
            helper: FakeHelper(results: [.empty]),
            automation: automation,
            gate: FakePermissionGate(),
            running: ["com.apple.Music"],
            now: { now },
        )

        var emitted: [MediaSample] = []
        for index in 0 ..< 4 {
            if index > 0 {
                now += 2
            }
            guard case let .sample(sample?) = await arbiter.pollOnce().emission else {
                Issue.record("Automation sample \(index) was not emitted")
                return
            }
            emitted.append(sample)
        }

        let engine = ScrobbleEngine()
        for sample in emitted {
            _ = engine.ingest(sample)
        }

        #expect(automation.probed.count == 4)
        #expect(engine.status.played == 6, "four 2-second Automation samples fit the engine's five-second gap")
    }
}
