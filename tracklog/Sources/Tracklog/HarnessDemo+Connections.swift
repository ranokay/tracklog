import Foundation
import TracklogCore

extension HarnessDemoStore {
    func connections() async throws -> [Connection] {
        linkedConnections
    }

    func connection(id: Int64) async throws -> Connection? {
        linkedConnections.first { $0.id == id }
    }

    func save(_ connection: Connection) async throws -> Connection {
        if let id = connection.id {
            guard let index = linkedConnections.firstIndex(where: { $0.id == id }) else {
                throw ConnectionError.unknownConnection(id: id)
            }
            linkedConnections[index] = connection
            return connection
        }
        if linkedConnections.contains(where: {
            $0.kind == connection.kind && $0.endpoint == connection.endpoint
        }) {
            throw ConnectionError.duplicateEndpoint(
                kind: connection.kind,
                endpoint: connection.endpoint,
            )
        }
        let stored = connection.stored(withID: nextConnectionID)
        nextConnectionID += 1
        linkedConnections.append(stored)
        return stored
    }

    func deleteConnection(id: Int64) async throws {
        linkedConnections.removeAll { $0.id == id }
        if currentConnection == id {
            currentConnection = nil
        }
    }

    func currentConnectionID() async throws -> Int64? {
        currentConnection
    }

    func setCurrentConnectionID(_ id: Int64?) async throws {
        if let id, !linkedConnections.contains(where: { $0.id == id }) {
            throw ConnectionError.unknownConnection(id: id)
        }
        currentConnection = id
    }
}
