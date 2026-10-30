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
        Task { try? await runtime?.quickBlock(listen) }
    }

    func quickBlockCurrentTrack() {
        Task { try? await runtime?.quickBlockCurrentTrack() }
    }
}
