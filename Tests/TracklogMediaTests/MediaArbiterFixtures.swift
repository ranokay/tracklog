import Foundation
import TracklogCore
import TracklogMedia

@MainActor
func makeArbiter(
    helper: FakeHelper,
    automation: FakeAutomation = FakeAutomation(),
    gate: FakePermissionGate = FakePermissionGate(),
    running: Set<String> = [],
    now: @escaping @MainActor () -> Date = { Date(timeIntervalSince1970: 1_000) },
    sleeper: @escaping @MainActor (Duration) async -> Void = { _ in
        // Tests drive polls directly and never wait on the default sleeper.
    },
) -> MediaArbiter {
    MediaArbiter(
        helper: helper,
        permissions: gate,
        automation: automation,
        candidates: MediaAutomationCandidate.defaults,
        playerIsRunning: { running.contains($0) },
        now: now,
        sleeper: sleeper,
    )
}

func playingSample(
    title: String = "Song",
    bundleID: String = "com.apple.Music",
    elapsed: TimeInterval = 42,
    timestamp: Date = Date(timeIntervalSince1970: 1_000),
) -> MediaSample {
    MediaSample(
        track: Track(
            title: title,
            artist: "Artist",
            album: "Album",
            albumArtist: "Album Artist",
            duration: 200,
            bundleID: bundleID,
        ),
        elapsed: elapsed,
        playbackRate: 1,
        isPlaying: true,
        timestamp: timestamp,
    )
}

@MainActor
final class FakeHelper: MediaHelperReading {
    let executablePath: String
    let isExecutable: Bool
    private var results: [MediaHelperRead]
    private(set) var readCount = 0

    init(
        executablePath: String = "/Applications/Droppy.app/Contents/Helpers/DroppyMediaHelper",
        isExecutable: Bool = true,
        results: [MediaHelperRead] = [.empty],
    ) {
        self.executablePath = executablePath
        self.isExecutable = isExecutable
        self.results = results
    }

    func read() async -> MediaHelperRead {
        defer { readCount += 1 }
        guard !results.isEmpty else { return .empty }
        return results[min(readCount, results.count - 1)]
    }
}

@MainActor
final class FakeAutomation: MediaAutomationProbing {
    var results: [String: MediaAutomationProbe]
    var sequences: [String: [MediaAutomationProbe]] = [:]
    private(set) var probed: [String] = []
    private var indices: [String: Int] = [:]

    init(results: [String: MediaAutomationProbe] = [:]) {
        self.results = results
    }

    func probe(_ candidate: MediaAutomationCandidate) async -> MediaAutomationProbe {
        probed.append(candidate.bundleID)
        if let sequence = sequences[candidate.bundleID], !sequence.isEmpty {
            let index = min(indices[candidate.bundleID, default: 0], sequence.count - 1)
            indices[candidate.bundleID] = index + 1
            return sequence[index]
        }
        return results[candidate.bundleID] ?? .paused
    }
}

@MainActor
final class FakePermissionGate: MediaAutomationPermissionGate {
    var status: MediaStatus.AutomationState
    var requestResult: MediaStatus.AutomationState
    private(set) var authorizationCalls = 0
    private(set) var requestCalls = 0

    init(
        status: MediaStatus.AutomationState = .available,
        requestResult: MediaStatus.AutomationState = .available,
    ) {
        self.status = status
        self.requestResult = requestResult
    }

    func authorization() -> MediaStatus.AutomationState {
        authorizationCalls += 1
        return status
    }

    func requestAuthorization() async -> MediaStatus.AutomationState {
        requestCalls += 1
        status = requestResult
        return requestResult
    }

    func rememberDenial() {
        status = .denied
    }

    func forgetDenial() {
        if status == .denied {
            status = .notRequested
        }
    }
}
