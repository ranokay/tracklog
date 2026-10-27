import Foundation

// MARK: - App allowlist

extension CaptureRuntime {
    /// The first sighting of a player is recorded as denied, so the Apps page
    /// can offer a one-tap allow. An empty identifier is not a player.
    func isAppAllowed(_ bundleID: String) async -> Bool {
        let normalized = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        if let app = state.seenApps.first(where: { $0.bundleID == normalized }) {
            return app.isAllowed
        }
        guard let seen = try? await allowlist.recordSeen(normalized) else {
            return false
        }
        state.seenApps.append(seen)
        return seen.isAllowed
    }

    /// Changes the decision the gate reads, so it takes effect on the next
    /// sample. The write lands first: a failed write must not leave a player
    /// allowed for the samples that arrive in between.
    public func setAppAllowed(_ bundleID: String, allowed: Bool) async {
        let normalized = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              let index = state.seenApps.firstIndex(where: { $0.bundleID == normalized })
        else { return }

        do {
            try await allowlist.setAllowed(normalized, allowed: allowed)
        } catch {
            return
        }
        state.seenApps[index].isAllowed = allowed
    }

    func loadSeenApps() async {
        guard let apps = try? await allowlist.apps() else { return }
        state.seenApps = apps
    }
}
