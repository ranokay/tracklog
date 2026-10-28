import TracklogCore

/// An offline ListenBrainz stand-in for the harness: any non-empty token links
/// the demo listener. The real adapter is exercised by the engine tests.
struct HarnessDemoServiceAdapter: ServiceAdapter {
    let kind = ServiceKind.listenBrainz
    let capabilities = ServiceCapabilities(
        supportsNowPlaying: true,
        maximumBatchSize: 1,
        supportsLove: true,
        supportsHate: true,
    )

    func validate(_: String) async throws -> ServiceIdentity {
        ServiceIdentity(name: "listener")
    }
}
