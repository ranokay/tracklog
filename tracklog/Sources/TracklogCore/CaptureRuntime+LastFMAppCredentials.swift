import Foundation

// MARK: - Last.fm app credentials

extension CaptureRuntime {
    /// Reports presence, never the pair. A Keychain read failure leaves the
    /// last known presence alone; the signed call path reports the failure
    /// rather than falling back to the compiled pair.
    func loadLastFMAppCredentials() async {
        state.lastFMCompiledCredentialsPresent = compiledLastFMAppCredentials.isConfigured
        guard let credentialStore else {
            state.lastFMOverridePresent = false
            return
        }
        do {
            state.lastFMOverridePresent =
                try await credentialStore.lastFMAppCredentialOverride() != nil
        } catch {
            // Keep the previous presence; no pair is read into state either way.
        }
    }

    /// The provider every signed call and the link page read. It reads the
    /// credential store per request, so a saved override needs no rebuild.
    var lastFMAppCredentialProvider: StoredLastFMAppCredentials? {
        guard let credentialStore else { return nil }
        return StoredLastFMAppCredentials(
            credentialStore: credentialStore,
            compiled: compiledLastFMAppCredentials,
        )
    }
}

public extension CaptureRuntime {
    /// Records why Last.fm rejected the app credentials in use. The reason
    /// survives a relaunch so Services can still explain a held queue.
    func noteLastFMAppCredentialProblem(_ problem: AppCredentialProblem) {
        state.lastFMAppCredentialProblem = problem
        persistAppCredentialProblem?(problem)
    }

    /// Clears the app-credential warning after a successful link, delivery or
    /// credential change.
    func clearLastFMAppCredentialProblem() {
        state.lastFMAppCredentialProblem = nil
        persistAppCredentialProblem?(nil)
    }

    /// Checks a candidate pair with Last.fm, then saves it in the Keychain.
    /// A changed pair invalidates every Last.fm session key: every Last.fm
    /// connection becomes needs sign-in and its pending deliveries stay
    /// queued until it reconnects.
    func saveLastFMAppCredentialOverride(apiKey: String, sharedSecret: String) async throws {
        guard let override = LastFMAppCredentialOverride(
            validating: apiKey,
            sharedSecret: sharedSecret,
        ) else {
            throw LastFMAppCredentialError.incomplete
        }
        guard let lastFMAppCredentialsValidator else {
            throw ConnectionError.unsupportedService(.lastFM)
        }
        // Validate before writing anything: a rejected pair must leave the
        // connection list and the old credentials untouched.
        try await lastFMAppCredentialsValidator.validateAppCredentials(override.credentials)
        try await replaceLastFMAppCredentialOverride(override)
    }

    /// Clears the Keychain override and returns to the compiled pair. Removing
    /// a pair also changes the credentials when the two differ, so every
    /// Last.fm session is invalidated the same way.
    func removeLastFMAppCredentialOverride() async throws {
        guard let provider = lastFMAppCredentialProvider else {
            throw ConnectionError.unavailable
        }
        let current: LastFMAppCredentialOverride?
        do {
            current = try await provider.override()
        } catch {
            throw LastFMAppCredentialError.storage
        }
        guard current != nil else { return }
        try await replaceLastFMAppCredentialOverride(nil)
    }
}

extension CaptureRuntime {
    /// Reapplies a credential change whose sign-out did not finish before the
    /// last shutdown. Runs before the outbox activates, so a row still stored
    /// as signed in cannot deliver under the new pair.
    func replayPendingLastFMInvalidation() async {
        guard lastFMInvalidationPending else { return }
        do {
            try await signOutLastFMSessions()
            lastFMInvalidationPending = false
            persistLastFMInvalidationPending?(false)
        } catch {
            // Keep the durable marker; the next launch retries before the
            // outbox activates.
        }
    }
}

private extension CaptureRuntime {
    /// Writes or clears the slot, then signs every Last.fm connection out when
    /// the effective pair changed. A failed sign-out leaves the invalidation
    /// pending, so a retry of the same save still repairs the connections.
    func replaceLastFMAppCredentialOverride(
        _ override: LastFMAppCredentialOverride?,
    ) async throws {
        guard let provider = lastFMAppCredentialProvider, let credentialStore else {
            throw ConnectionError.unavailable
        }
        let previous: LastFMAppCredentials
        do {
            previous = try await provider.appCredentials()
        } catch {
            throw LastFMAppCredentialError.storage
        }
        let next = override?.credentials ?? compiledLastFMAppCredentials
        let changed = next != previous
        // Record the obligation before the new pair can be observed. A crash
        // or a failed read after this write then still replays on launch.
        if changed || lastFMInvalidationPending {
            lastFMInvalidationPending = true
            persistLastFMInvalidationPending?(true)
        }
        do {
            try await credentialStore.saveLastFMAppCredentialOverride(override)
        } catch {
            // The write may have landed; keep the obligation rather than trust
            // the old session state.
            throw LastFMAppCredentialError.storage
        }
        // A validated save, or a removal, retires any rejection recorded for
        // the pair that was in use. Saving the same pair again clears a stale
        // warning even though the effective pair did not change.
        clearLastFMAppCredentialProblem()
        await loadLastFMAppCredentials()

        guard changed || lastFMInvalidationPending else { return }
        do {
            try await signOutLastFMSessions()
            lastFMInvalidationPending = false
            persistLastFMInvalidationPending?(false)
        } catch {
            throw LastFMAppCredentialError.invalidation
        }
    }

    func signOutLastFMSessions() async throws {
        guard let connectionService else { return }
        do {
            try await connectionService.markNeedsSignIn(kind: .lastFM)
            applyConnectionSnapshot()
            await reloadDeliveryState()
        } catch {
            // Publish the rows that did change before reporting the failure.
            applyConnectionSnapshot()
            throw error
        }
    }
}
