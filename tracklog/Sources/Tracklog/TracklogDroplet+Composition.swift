import AppKit
import DroppyKit
import TracklogCore
import TracklogMedia

extension TracklogDroplet {
    func makeHarnessRuntime(hud: HUDHostSession) -> CaptureRuntime {
        let store = HarnessDemoStore()
        let credentials = MemoryCredentialStore()
        return CaptureRuntime(
            state: state,
            clock: SystemClock(),
            source: HarnessDemoSource(),
            store: store,
            allowlist: store,
            edits: store,
            blocks: store,
            credentials: credentials,
            serviceAdapters: [
                HarnessDemoServiceAdapter(),
                HarnessDemoLastFMAdapter(),
            ],
            hud: hud,
            settings: CaptureSettings(scrobblingEnabled: true),
        )
    }

    func makeProductionRuntime(
        host: DropletHost,
        transport: URLSessionTransport,
        credentials: KeychainCredentialStore,
        libreFM: LibreFMAdapter,
        hud: HUDHostSession,
    ) -> CaptureRuntime {
        let settings = CaptureSettings(
            scrobblingEnabled: host.preferences.value(forKey: "scrobblingEnabled", default: false),
            nowPlayingEnabled: host.preferences.value(forKey: "nowPlayingEnabled", default: true),
            pausedUntil: host.preferences.value(forKey: "pausedUntil", as: Date.self),
            minimumDuration: host.preferences.value(
                forKey: "minimumDuration",
                default: CaptureSettings.defaultMinimumDuration,
            ),
        )
        let databaseURL = host.environment.containerDirectory.appendingPathComponent("tracklog.sqlite")
        let gate = HostAutomationPermissionGate(host: host)
        automationGate = gate
        let appCredentialProblem = AppCredentialProblem(
            rawValue: host.preferences.value(forKey: "lastFMAppCredentialProblem", default: ""),
        )
        let lastFMInvalidationPending = host.preferences.value(
            forKey: "lastFMInvalidationPending",
            default: false,
        )
        let appCredentials = StoredLastFMAppCredentials(credentialStore: credentials)
        lastFMAppCredentialsProvider = appCredentials
        return CaptureRuntime.open(
            state: state,
            databaseURL: databaseURL,
            clock: SystemClock(),
            source: MediaArbiter(helper: MediaHelperReader(), permissions: gate),
            settings: settings,
            credentials: credentials,
            serviceAdapters: [
                ListenBrainzAdapter(transport: transport),
                LastFMAdapter(transport: transport, appCredentials: appCredentials),
                libreFM,
            ],
            connectionLog: { event in
                switch event {
                case .linked, .reauthenticated:
                    host.log.info(event.description)
                case .linkFailed, .unlinked:
                    host.log.notice(event.description)
                }
            },
            deliveryLog: { event in
                switch event {
                case .delivered:
                    host.log.info(event.description)
                case .failed, .abandoned:
                    host.log.notice(event.description)
                }
            },
            hud: hud,
            persistSettings: { settings in
                host.preferences.setValue(settings.scrobblingEnabled, forKey: "scrobblingEnabled")
                host.preferences.setValue(settings.nowPlayingEnabled, forKey: "nowPlayingEnabled")
                host.preferences.setValue(settings.pausedUntil, forKey: "pausedUntil")
                host.preferences.setValue(settings.minimumDuration, forKey: "minimumDuration")
            },
            appCredentialProblem: appCredentialProblem,
            persistAppCredentialProblem: { problem in
                host.preferences.setValue(
                    problem?.rawValue ?? "",
                    forKey: "lastFMAppCredentialProblem",
                )
            },
            lastFMInvalidationPending: lastFMInvalidationPending,
            persistLastFMInvalidationPending: { pending in
                host.preferences.setValue(pending, forKey: "lastFMInvalidationPending")
            },
        )
    }

    /// One page model for the Last.fm browser link. It shares the runtime's
    /// transport, opens the authorization page through AppKit, and stores the
    /// session key through the runtime's connection service.
    func makeLastFMLink(
        transport: URLSessionTransport,
        appCredentials: StoredLastFMAppCredentials,
    ) -> LastFMLinkModel {
        LastFMLinkModel(
            client: LastFMAdapter(transport: transport, appCredentials: appCredentials),
            clock: SystemClock(),
            openAuthorization: { NSWorkspace.shared.open($0) },
            complete: { [weak self] session in
                guard let self, let runtime else {
                    throw ConnectionError.unavailable
                }
                let connection = try await runtime.linkVerified(
                    kind: .lastFM,
                    credential: session.key,
                    identity: ServiceIdentity(name: session.name),
                )
                runtime.clearLastFMAppCredentialProblem()
                return connection
            },
            onAppCredentialProblem: { [weak self] problem in
                self?.runtime?.noteLastFMAppCredentialProblem(problem)
            },
        )
    }

    /// One page model for the Libre.fm browser link, bound to the root the
    /// listener entered. GNU FM sends its own messages, so the model's service
    /// name is Libre.fm and a refused client key is named rather than
    /// reported as a Last.fm app-credential problem.
    func makeLibreFMLink(endpoint: ServiceEndpoint) -> LastFMLinkModel? {
        guard let libreFMAdapter else { return nil }
        return LastFMLinkModel(
            client: libreFMAdapter.linkClient(for: endpoint),
            clock: SystemClock(),
            serviceName: "Libre.fm",
            openAuthorization: { NSWorkspace.shared.open($0) },
            complete: { [weak self] session in
                guard let self, let runtime else {
                    throw ConnectionError.unavailable
                }
                return try await runtime.linkVerified(
                    kind: .libreFM,
                    credential: session.key,
                    identity: ServiceIdentity(name: session.name),
                    endpoint: endpoint,
                )
            },
        )
    }
}
