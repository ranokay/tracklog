import Foundation
import Testing
@testable import TracklogCore

@Suite("Media status capture")
@MainActor
struct MediaStatusCaptureTests: CaptureTestHelpers {
    @Test func mediaStatusFlowsIntoTheStateAndFeedAvailability() async throws {
        let database = try TemporaryDatabase()
        let source = ReplayedNowPlaying()
        let runtime = runtime(database: database, clock: FakeClock(base), source: source)
        await runtime.start()

        #expect(runtime.state.mediaStatus == .legacyAvailable)
        #expect(runtime.state.feedAvailable)

        let missing = MediaStatus(
            source: .unavailable,
            helperHealth: .missingExecutable,
            automation: .denied,
            helperPath: "/Applications/Droppy.app/Contents/Helpers/DroppyMediaHelper",
            lastFailure: "Media helper is missing",
        )
        source.emitStatus(missing)

        #expect(runtime.state.mediaStatus == missing)
        #expect(runtime.state.feedAvailable == false)
    }
}
