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
