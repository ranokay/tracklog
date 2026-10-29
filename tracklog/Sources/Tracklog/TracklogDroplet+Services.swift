import AppKit
import DroppyKit
import TracklogCore

extension TracklogDroplet {
    // MARK: - Services

    @discardableResult
    func linkListenBrainz(token: String) async throws -> Connection {
        guard let runtime else { throw ConnectionError.unavailable }
        return try await runtime.link(kind: .listenBrainz, credential: token)
    }

    func reloadServices() async {
        await runtime?.reloadConnections()
    }

    /// Checks and saves the user-supplied Last.fm application pair. The pair
    /// never enters the view. A changed pair signs every Last.fm connection
    /// out; the page explains that before the button is pressed.
    func saveLastFMAppCredentialOverride(apiKey: String, sharedSecret: String) async throws {
        guard let runtime else { throw ConnectionError.unavailable }
        try await runtime.saveLastFMAppCredentialOverride(
            apiKey: apiKey,
            sharedSecret: sharedSecret,
        )
    }

    func removeLastFMAppCredentialOverride() async throws {
        guard let runtime else { throw ConnectionError.unavailable }
        try await runtime.removeLastFMAppCredentialOverride()
    }

    func setConnectionEnabled(id: Int64, enabled: Bool) async throws {
        guard let runtime else { throw ConnectionError.unavailable }
        try await runtime.setConnectionEnabled(id: id, enabled: enabled)
    }

    func setCurrentConnection(_ id: Int64) async throws {
        guard let runtime else { throw ConnectionError.unavailable }
        try await runtime.setCurrentConnection(id)
    }

    func openConnectionPage(for connection: Connection) {
        guard let host, let id = connection.id else { return }
        let title = "\(connection.kind.displayName) connection"
        guard host.workspace.openSettingsPage(tracklogConnectionPageID(id), title: title) else {
            host.log.notice("Opening the connection page was refused")
            return
        }
    }

    // MARK: - Re-auth and unlink

    /// Whether the connection page can start a browser sign-in for this
    /// service. ListenBrainz signs in with a token instead; the harness has no
    /// transport, so it never offers a dead browser flow.
    func canStartBrowserSignIn(_ connection: Connection) -> Bool {
        switch connection.kind {
        case .lastFM:
            serviceTransport != nil && lastFMAppCredentialsProvider != nil
        case .libreFM:
            libreFMAdapter != nil
        case .listenBrainz:
            false
        }
    }

    /// The browser model bound to one connection page, if a re-auth is open.
    func reauthLink(for connectionID: Int64) -> LastFMLinkModel? {
        guard reauthLink?.connectionID == connectionID else { return nil }
        return reauthLink?.model
    }

    /// Starts the same browser flow a first link uses, bound to the existing
    /// connection. The page renders the flow in place.
    func startReauth(for connection: Connection) {
        guard let id = connection.id, let model = makeReauthLink(for: connection) else {
            host?.log.notice("Signing in again is unavailable")
            return
        }
        cancelReauth()
        reauthLink = TracklogReauthLink(connectionID: id, model: model)
        state.setReauthConnection(id)
    }

    /// Clears the re-auth flow. A completed connection is already published by
    /// the runtime, so dropping the page model never changes it.
    func cancelReauth() {
        reauthLink?.model.cancel()
        reauthLink = nil
        state.setReauthConnection(nil)
    }

    /// ListenBrainz signs in with a token rather than a browser. The credential
    /// is validated by the adapter inside the runtime.
    func reauthenticateListenBrainz(connectionID: Int64, token: String) async throws {
        guard let runtime else { throw ConnectionError.unavailable }
        _ = try await runtime.reauthenticate(
            id: connectionID,
            credential: token,
            confirmReplacement: confirmReplacement,
        )
    }

    /// Removes a connection. Pending deliveries are abandoned; the page's
    /// dialog has already stated their count.
    func unlinkConnection(id: Int64) async throws {
        guard let runtime else { throw ConnectionError.unavailable }
        _ = try await runtime.unlinkConnection(id: id)
    }

    func pendingDeliveryCount(forConnection id: Int64) async -> Int {
        await runtime?.pendingDeliveryCount(forConnection: id) ?? 0
    }

    private func makeReauthLink(for connection: Connection) -> LastFMLinkModel? {
        guard let id = connection.id, let runtime else { return nil }
        switch connection.kind {
        case .lastFM:
            guard let serviceTransport, let lastFMAppCredentialsProvider else { return nil }
            return LastFMLinkModel(
                client: LastFMAdapter(
                    transport: serviceTransport,
                    appCredentials: lastFMAppCredentialsProvider,
                ),
                clock: SystemClock(),
                openAuthorization: { NSWorkspace.shared.open($0) },
                complete: { session in
                    let updated = try await runtime.reauthenticate(
                        id: id,
                        credential: session.key,
                        identity: ServiceIdentity(name: session.name),
                        confirmReplacement: self.confirmReplacement,
                    )
                    runtime.clearLastFMAppCredentialProblem()
                    return updated
                },
                onAppCredentialProblem: { [weak self] problem in
                    self?.runtime?.noteLastFMAppCredentialProblem(problem)
                },
            )
        case .libreFM:
            guard let libreFMAdapter else { return nil }
            return LastFMLinkModel(
                client: libreFMAdapter.linkClient(for: connection.endpoint),
                clock: SystemClock(),
                serviceName: "Libre.fm",
                openAuthorization: { NSWorkspace.shared.open($0) },
                complete: { session in
                    try await runtime.reauthenticate(
                        id: id,
                        credential: session.key,
                        identity: ServiceIdentity(name: session.name),
                        confirmReplacement: self.confirmReplacement,
                    )
                },
            )
        case .listenBrainz:
            return nil
        }
    }

    /// The host's own confirmation before a different identity takes over a
    /// connection. The pending rows are named so the count is not a surprise.
    private func confirmReplacement(
        existing: Connection,
        identity: ServiceIdentity,
        pending: Int,
    ) -> Bool {
        DropletConfirmationDialog.present(
            title: "Sign in as \(identity.name)?",
            message: "\(existing.kind.displayName) is connected as \(existing.identity). "
                + "\(TracklogConnectionCopy.pendingScrobbles(pending)) will be abandoned. "
                + "The new account is used instead, and local history is kept.",
            confirmTitle: "Replace",
            symbol: "person.crop.circle.badge.xmark",
        )
    }

    /// Starts a Libre.fm link against the root the listener typed and opens its
    /// page. A model already in flight is cancelled: its token belongs to the
    /// previous root.
    func openLibreFMLink(endpoint: ServiceEndpoint) {
        guard let host else { return }
        guard let link = makeLibreFMLink(endpoint: endpoint) else {
            host.log.notice("Libre.fm sign-in is unavailable")
            return
        }
        libreFMLink?.model.cancel()
        libreFMLink = TracklogLibreFMLink(endpoint: endpoint, model: link)
        guard host.workspace.openSettingsPage(tracklogLibreFMLinkPageID, title: "Libre.fm") else {
            libreFMLink = nil
            host.log.notice("Opening the Libre.fm sign-in page was refused")
            return
        }
    }

    func openServicesPage() {
        guard let host else { return }
        guard host.workspace.openSettingsPage(tracklogServicesPageID, title: "Services") else {
            host.log.notice("Opening the Services page was refused")
            return
        }
    }

    func goBackInSettings() {
        guard let host else { return }
        if !host.workspace.goBackInSettings() {
            host.log.notice("Going back in Settings was refused")
        }
    }
}
