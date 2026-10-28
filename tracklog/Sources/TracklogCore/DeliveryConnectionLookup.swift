import Foundation

/// Reads the connection list, its adapters and its credentials for the outbox.
/// Kept apart from the drain loop so every eligibility rule lives in one place.
@MainActor
struct DeliveryConnectionLookup {
    let connections: ConnectionService
    let adapters: [ServiceKind: any DeliveryAdapter]
    private let credentials: any CredentialStore

    init(
        connections: ConnectionService,
        credentials: any CredentialStore,
        adapters: [any DeliveryAdapter],
    ) {
        self.connections = connections
        self.credentials = credentials
        var byKind: [ServiceKind: any DeliveryAdapter] = [:]
        for adapter in adapters {
            byKind[adapter.kind] = adapter
        }
        self.adapters = byKind
    }

    func connection(id: Int64) -> Connection? {
        guard let connection = connections.connections.first(where: { $0.id == id }),
              isEligible(connection)
        else { return nil }
        return connection
    }

    func isEligible(_ connection: Connection) -> Bool {
        connection.isEnabled && connection.authState == .signedIn && adapters[connection.kind] != nil
    }

    func eligibleConnectionIDs() -> [Int64] {
        connections.connections
            .filter(isEligible)
            .compactMap(\.id)
    }

    func credential(for id: Int64) async -> CredentialLookup {
        let stored: String?
        do {
            stored = try await credentials.credential(forConnection: id)
        } catch {
            return .unavailable
        }
        guard let stored, !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .missing
        }
        return .value(stored)
    }
}

enum CredentialLookup {
    case value(String)
    case missing
    case unavailable
}
