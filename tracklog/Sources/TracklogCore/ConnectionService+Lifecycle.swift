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
    /// service first. The caller must suspend this connection's drain before
    /// calling, so the new credential never meets the old queue; the runtime
    /// does.
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
        let pending = try await pendingDeliveryCount(forConnection: id)
        guard confirmReplacement(existing, identity, pending) else {
            throw ConnectionError.reauthenticationCancelled
        }
        try Task.checkCancellation()

        let previousCredential = try? await credentials.credential(forConnection: id)
        do {
            try await credentials.saveCredential(credential, forConnection: id)
        } catch {
            log(.linkFailed(kind: existing.kind, reason: "credential storage failed"))
            throw ConnectionError.credentialStorage
        }

        // The runtime suspended this connection's drain, so the new credential
        // cannot meet the old queue. The identity change and the abandonment
        // commit together: a failure leaves the old row and its queue intact.
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
            let stored: Connection
            if let atomicStore = store as? any ConnectionReplaceStore {
                stored = try await atomicStore.replaceConnection(
                    replaced,
                    reason: Self.replacementReason,
                ).connection
            } else {
                // Stores without the atomic operation are tests and the
                // harness.
                _ = try await abandonPending(forConnection: id, reason: Self.replacementReason)
                stored = try await store.save(replaced)
            }
            connections[index] = stored
            log(.reauthenticated(kind: stored.kind, identity: stored.identity))
            return stored
        } catch {
            // A thrown write leaves the stored row unchanged, so put the old
            // credential back and let the old identity keep working.
            if let previousCredential {
                try? await credentials.saveCredential(previousCredential, forConnection: id)
            } else {
                try? await credentials.deleteCredential(forConnection: id)
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

            // Read the credential so a failed store operation can put it back:
            // the connection is still linked, and the outbox should not treat
            // it as signed out. Deleting first keeps a failed unlink from
            // finding its queue abandoned while the connection still works.
            let previousCredential = try? await credentials.credential(forConnection: id)
            try await credentials.deleteCredential(forConnection: id)
            let abandoned: Int
            do {
                if let atomicStore = store as? any ConnectionUnlinkStore {
                    // One transaction: a failure leaves the queue pending.
                    abandoned = try await atomicStore.unlinkConnection(
                        id: id,
                        reason: Self.unlinkReason,
                    )
                } else {
                    // Stores without the atomic operation are tests and the
                    // harness. Abandon before deleting so no drain resurrects
                    // a row that was meant to stay behind.
                    abandoned = try await abandonPending(forConnection: id, reason: Self.unlinkReason)
                    try await store.deleteConnection(id: id)
                }
            } catch {
                if let previousCredential {
                    try? await credentials.saveCredential(previousCredential, forConnection: id)
                }
                throw error
            }
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

    private func pendingDeliveryCount(forConnection id: Int64) async throws -> Int {
        guard let deliveries else { return 0 }
        return try await deliveries.pendingDeliveryCount(forConnection: id)
    }
}
