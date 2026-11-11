import TracklogCore

extension TracklogDroplet {
    // MARK: - Feedback

    func toggleLove(for listen: Listen) {
        Task { await runtime?.toggleLove(for: listen) }
    }

    func toggleLoveForCurrentTrack() {
        Task { await runtime?.toggleLoveForCurrentTrack() }
    }

    func hate(_ listen: Listen) {
        Task { await runtime?.hate(listen) }
    }

    func quickBlock(_ listen: Listen) {
        Task {
            do {
                try await runtime?.quickBlock(listen)
            } catch {
                host?.log.error("Could not save the block: \(error)")
            }
        }
    }

    func quickBlockCurrentTrack() {
        Task {
            do {
                try await runtime?.quickBlockCurrentTrack()
            } catch {
                host?.log.error("Could not save the block: \(error)")
            }
        }
    }
}
