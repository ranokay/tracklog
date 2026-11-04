import DroppyKit
import Foundation
import TracklogCore

public extension TracklogDroplet {
    // MARK: - Loved section

    func showLoved() async {
        await runtime?.loved?.show()
    }

    func hideLoved() {
        runtime?.loved?.hide()
    }

    func refreshLoved() async {
        await runtime?.loved?.refresh()
    }

    func loadMoreLoved() async {
        await runtime?.loved?.loadMore()
    }

    func dismissLovedActionFailure() {
        runtime?.loved?.dismissActionFailure()
    }

    /// Unloves one row through the existing feedback chain. The read model
    /// removes the row only when the row's source connection confirms it; a
    /// partial success elsewhere leaves the row and shows the per-row notice.
    func unloveLovedRow(_ row: LovedRow) async {
        guard let runtime, let connection = state.currentConnection,
              connection.id == row.connectionID
        else { return }
        let confirmed = await runtime.unloveLovedRow(row)
        if !confirmed {
            runtime.loved?.rowActionFailed(row, service: connection.kind.displayName)
        }
    }

    func openLovedServices() {
        openServicesPage()
    }

    func openLovedAppCredentials() {
        _ = openSettingsPage(
            tracklogLastFMAppCredentialsPageID,
            title: "Last.fm app credentials",
        )
    }

    func presentLoved() {
        state.setTakeoverSection(.loved)
        guard let host else { return }
        host.notchSurface.presentExpandedSurface(
            ExpandedSurfacePresentationRequest(surfaceID: tracklogHistorySurfaceID),
        )
    }
}
