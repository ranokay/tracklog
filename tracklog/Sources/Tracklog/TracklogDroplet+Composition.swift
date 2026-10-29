import AppKit
import DroppyKit
import TracklogCore
import TracklogMedia

extension TracklogDroplet {
    func makeHarnessRuntime() -> CaptureRuntime {
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
            settings: CaptureSettings(scrobblingEnabled: true),
        )
    }

    func makeProductionRuntime(
        host: DropletHost,
        transport: URLSessionTransport,
        credentials: KeychainCredentialStore,
        appCredentials: StoredLastFMAppCredentials,
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
            ],
            connectionLog: { event in
                switch event {
                case .linked:
                    host.log.info(event.description)
                case .linkFailed:
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
        )
    }

    /// One page model for the browser link. It shares the runtime's transport,
    /// opens the authorization page through AppKit, and stores the session key
    /// through the runtime's connection service.
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
}
