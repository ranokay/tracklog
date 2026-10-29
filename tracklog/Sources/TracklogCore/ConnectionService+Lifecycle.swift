import Foundation

// MARK: - Re-auth and unlink

public extension ConnectionService {
    /// The abandonment reason written to every pending row of an unlinked or
    /// replaced connection. The listen itself stays in local history.
    static let unlinkReason = "The service was unlinked."
    static let replacementReason = "The account was replaced."
    static let lostCredentialReason = "The connection's saved credential was lost."

    /// Signs an existing connection in again. A same-identity sign-in replaces
    /// the credential, clears needs sign-in and keeps every pending delivery.
    /// A different identity asks first, abandons the old pending deliveries and
    /// takes the new identity on the same connection. `identity` is the one a
    /// browser flow already verified; `nil` validates the credential with the
    /// service first.
    @discardableResult
    func reauthenticate(
        id: Int64,
        credential rawCredential: String,
        identity verifiedIdentity: ServiceIdentity? = nil,
        confirmReplacement: @MainActor (Connection, ServiceIdentity, Int) -> Bool,
    ) async throws -> Connection {
        try await withGate {
            try await reauthenticateConnection(
                id: id,
                credential: rawCredential,
                identity: verifiedIdentity,
                confirmReplacement: confirmReplacement,
            )
        }
    }

    private func reauthenticateConnection(
        id: Int64,
        credential rawCredential: String,
        identity verifiedIdentity: ServiceIdentity?,
        confirmReplacement: @MainActor (Connection, ServiceIdentity, Int) -> Bool,
    ) async throws -> Connection {
        let credential = rawCredential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty else { throw ServiceFailure.rejected("Enter a user token.") }
        guard let index = connections.firstIndex(where: { $0.id == id }) else {
            throw ConnectionError.unknownConnection(id: id)
        }
        let existing = connections[index]
        let identity = try await resolvedIdentity(
            for: existing,
            credential: credential,
            verifiedIdentity: verifiedIdentity,
        )

        if identity.name.caseInsensitiveCompare(existing.identity) == .orderedSame {
            return try await resumeConnection(
                existing,
                id: id,
                at: index,
                credential: credential,
            )
        }
        return try await replaceConnection(
            existing,
            at: index,
            with: identity,
            credential: credential,
            confirmReplacement: confirmReplacement,
        )
    }

    /// The identity a browser flow already named, or the one the service
    /// reports for a freshly typed credential.
    private func resolvedIdentity(
        for connection: Connection,
        credential: String,
        verifiedIdentity: ServiceIdentity?,
    ) async throws -> ServiceIdentity {
        if let verifiedIdentity {
            return verifiedIdentity
        }
        guard let adapter = adapters[connection.kind] else {
            throw ConnectionError.unsupportedService(connection.kind)
        }
        do {
            return try await adapter.validate(credential, endpoint: connection.endpoint)
        } catch let failure as ServiceFailure {
            log(.linkFailed(kind: connection.kind, reason: connectionFailureReason(failure)))
            throw failure
        } catch {
            log(.linkFailed(kind: connection.kind, reason: "unreadable response"))
            throw ServiceFailure.retryable
        }
    }

    private func resumeConnection(
        _ existing: Connection,
        id: Int64,
        at index: Int,
        credential: String,
    ) async throws -> Connection {
        try Task.checkCancellation()
        try await saveReauthenticatedCredential(
            credential,
            forConnection: id,
            kind: existing.kind,
        )
        var updated = existing
        updated.authState = .signedIn
        updated.lastUsedAt = clock.now
        let stored = try await store.save(updated)
        connections[index] = stored
        log(.reauthenticated(kind: stored.kind, identity: stored.identity))
        return stored
    }

    private func replaceConnection(
        _ existing: Connection,
        at index: Int,
        with identity: ServiceIdentity,
        credential: String,
        confirmReplacement: @MainActor (Connection, ServiceIdentity, Int) -> Bool,
    ) async throws -> Connection {
        guard let id = existing.id else { throw ConnectionError.unknownConnection(id: -1) }
        let pending = await pendingDeliveryCount(forConnection: id)
        guard confirmReplacement(existing, identity, pending) else {
            throw ConnectionError.reauthenticationCancelled
        }
        try Task.checkCancellation()

        // The user just confirmed abandoning these rows, and they must be gone
        // before the new account's credential lands: no listen from the old
        // identity may ever be sent to the new one. A later write failure
        // leaves the old connection linked with an empty queue rather than
        // risking that.
        _ = try await abandonPending(forConnection: id, reason: Self.replacementReason)

        let previousCredential = try? await credentials.credential(forConnection: id)
        do {
            try await credentials.saveCredential(credential, forConnection: id)
        } catch {
            log(.linkFailed(kind: existing.kind, reason: "credential storage failed"))
            throw ConnectionError.credentialStorage
        }

        let replaced = Connection(
            id: id,
            kind: existing.kind,
            endpoint: existing.endpoint,
            identity: identity.name,
            displayName: identity.displayName,
            isEnabled: existing.isEnabled,
            authState: .signedIn,
            createdAt: existing.createdAt,
            lastUsedAt: clock.now,
        )
        do {
            let stored = try await store.save(replaced)
            connections[index] = stored
            log(.reauthenticated(kind: stored.kind, identity: stored.identity))
            return stored
        } catch {
            // The new credential names an account the store does not hold.
            // Put the old one back so the old identity keeps working.
            if let previousCredential {
                try? await credentials.saveCredential(previousCredential, forConnection: id)
            }
            throw error
        }
    }

    private func saveReauthenticatedCredential(
        _ credential: String,
        forConnection id: Int64,
        kind: ServiceKind,
    ) async throws {
        do {
            try await credentials.saveCredential(credential, forConnection: id)
        } catch {
            log(.linkFailed(kind: kind, reason: "credential storage failed"))
            throw ConnectionError.credentialStorage
        }
    }

    /// Removes one connection for good. Pending deliveries are abandoned with
    /// a stored reason, the listen rows stay, the Keychain credential is
    /// deleted, and an unlinked current connection falls back to the most
    /// recently used remaining one.
    @discardableResult
    func unlink(id: Int64) async throws -> UnlinkedConnection {
        try await withGate {
            guard let index = connections.firstIndex(where: { $0.id == id }) else {
                throw ConnectionError.unknownConnection(id: id)
            }
            let connection = connections[index]

            // Deleting the credential first makes a failed unlink leave the
            // connection signed in but credentialless: the outbox holds its
            // rows instead of finding them abandoned while the connection is
            // still working.
            try await credentials.deleteCredential(forConnection: id)
            let abandoned = try await abandonPending(forConnection: id, reason: Self.unlinkReason)
            try await store.deleteConnection(id: id)
            connections.remove(at: index)

            if currentID == id {
                let fallback = connections.max { $0.lastUsedAt < $1.lastUsedAt }?.id
                do {
                    try await store.setCurrentConnectionID(fallback)
                    currentID = fallback
                } catch {
                    // The deleted connection's cursor is already cleared by the
                    // store; a failed fallback write just leaves no current.
                    currentID = nil
                }
            }

            log(.unlinked(kind: connection.kind, identity: connection.identity))
            return UnlinkedConnection(connection: connection, abandonedDeliveries: abandoned)
        }
    }

    private func abandonPending(forConnection id: Int64, reason: String) async throws -> Int {
        guard let deliveries else { return 0 }
        return try await deliveries.abandonPending(forConnection: id, reason: reason)
    }

    private func pendingDeliveryCount(forConnection id: Int64) async -> Int {
        guard let deliveries else { return 0 }
        return await (try? deliveries.pendingDeliveryCount(forConnection: id)) ?? 0
    }
}
