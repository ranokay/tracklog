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

/// An offline Last.fm stand-in for the harness. The app-credentials page works
/// without the Keychain or the network; a half that starts with `invalid` is
/// rejected so the inline error has a demo path.
struct HarnessDemoLastFMAdapter: ServiceAdapter, LastFMAppCredentialValidating {
    let kind = ServiceKind.lastFM
    let capabilities = ServiceCapabilities(signsRequests: true)

    func validate(_: String) async throws -> ServiceIdentity {
        ServiceIdentity(name: "listener")
    }

    func validateAppCredentials(_ credentials: LastFMAppCredentials) async throws {
        guard credentials.isConfigured else {
            throw ServiceFailure.appCredentialAuth(.missing)
        }
        if credentials.apiKey.hasPrefix("invalid") || credentials.sharedSecret.hasPrefix("invalid") {
            throw ServiceFailure.appCredentialAuth(.invalidKey)
        }
    }
}
