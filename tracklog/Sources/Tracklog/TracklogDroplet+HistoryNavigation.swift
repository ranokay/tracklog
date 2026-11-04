import Foundation
import TracklogCore

// MARK: - History navigation

extension TracklogDroplet {
    // MARK: - History

    /// What the History view runs when it appears. A pending one-shot jump
    /// takes priority; otherwise History opens at the newest feed.
    func openHistory() async {
        guard let runtime else { return }
        if state.pendingHistoryJump != nil {
            await runtime.applyPendingHistoryJump()
        } else if state.trackHistory == nil, state.historyJumpNotice == nil,
                  !state.historyJumpInFlight {
            // A track view or a jumped window opened just before the surface
            // mounted (the harness fixtures do this) must not be replaced by
            // the feed load. The in-flight flag also stops a second surface
            // copy from resetting a jump its sibling is still reading.
            await runtime.reloadHistory()
        }
    }

    func reloadHistory() async {
        await runtime?.reloadHistory()
    }

    func loadMoreHistory() async {
        await runtime?.loadMoreHistory()
    }

    func loadNewerHistory() async {
        await runtime?.loadNewerHistory()
    }

    /// Settings finishes by opening the position it was given. The takeover is
    /// the same surface as always; only its first row changes.
    func showHistory(at date: Date) {
        state.setHistorySettingsUnavailable(false)
        state.requestHistoryJump(date)
        presentHistory()
    }

    func openHistorySettingsPage() {
        guard let host else { return }
        // Ask first, dismiss second: a host that refuses the page must leave
        // History up so the inline refusal bar can explain itself.
        if host.workspace.openSettingsPage(tracklogHistoryPageID, title: "History") {
            state.setHistorySettingsUnavailable(false)
            dismissTakeoverForSettings()
        } else {
            host.log.notice("Opening the History settings page was refused")
            state.setHistorySettingsUnavailable(true)
        }
    }

    /// A page that finishes by itself goes back one step, then the takeover
    /// presents. A host that cannot go back still presents.
    func finishHistorySettingsPage() {
        host?.workspace.goBackInSettings()
    }

    func openTrackHistory(_ listen: Listen) {
        Task { await runtime?.openTrackHistory(listen) }
    }

    func reloadTrackHistory() async {
        await runtime?.reloadTrackHistory()
    }

    func loadMoreTrackHistory() async {
        await runtime?.loadMoreTrackHistory()
    }

    func closeTrackHistory() {
        runtime?.closeTrackHistory()
    }

    /// Leaving the History section or the takeover returns the next open to
    /// the newest feed, never the track page or an old jump position.
    func hideHistory() {
        runtime?.resetHistoryNavigation()
    }

    func artworkData(for listen: Listen) -> Data? {
        guard let hash = listen.artworkHash else { return nil }
        return state.artworkByHash[hash]
    }

    func copyMetadata(for listen: Listen) {
        guard let host else { return }
        if !host.workspace.copyToPasteboard(listen.processed.copyText) {
            host.log.notice("Copy metadata was refused")
        }
    }
}
