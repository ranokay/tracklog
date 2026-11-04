import Foundation
import TracklogCore

// MARK: - History editing and deletion

extension TracklogDroplet {
    /// Opens the typed Settings page for one history row. A refused host page
    /// leaves History up and explains the refusal rather than losing the row.
    func requestListenEdit(_ listen: Listen) {
        guard runtime != nil else { return }
        state.requestListenEdit(listen)
        if !openSettingsPage(tracklogHistoryEditPageID, title: "Edit listen", dismissOnRefusal: false) {
            state.clearListenEdit()
            state.setHistorySettingsUnavailable(true)
            host?.log.notice("Opening the History edit page was refused")
        }
    }

    /// Saves one row edit. The page keeps its form on any throw, so a failure
    /// never looks like a saved change.
    @discardableResult
    func saveListenEdit(
        _ listen: Listen,
        metadata: ListenMetadata,
        rememberAsRule: Bool,
    ) async throws -> Listen {
        guard let runtime else { throw DatabaseError.unavailable("Tracklog is not active") }
        let updated = try await runtime.editListen(
            listen,
            to: metadata,
            rememberAsRule: rememberAsRule,
        )
        TracklogAccessibilityAnnouncer.announce(
            "Listen updated in local history. Services were not changed.",
        )
        return updated
    }

    /// Settings finished with a saved edit. Returning to History shows the new
    /// row; a host that cannot go back still presents the takeover.
    func finishListenEdit() {
        state.clearListenEdit()
        host?.workspace.goBackInSettings()
        presentHistory()
    }

    func requestDeleteListen(_ listen: Listen) {
        state.requestDeleteListen(listen)
        let notice = ListenMutationNoticeBuilder.delete(
            listen: listen,
            deliveries: state.deliveries(for: listen),
            connections: state.connections,
        )
        TracklogAccessibilityAnnouncer.announce(notice.spoken)
    }

    func cancelDeleteListen() {
        state.cancelDeleteListen()
    }

    /// The explicit Delete action in the confirmation bar. Success is published
    /// only after the store commits; a failure keeps the row and the bar up
    /// with its message.
    func confirmDeleteListen() async {
        guard let listen = state.pendingListenDelete, let runtime else { return }
        state.setDeletingListen(true)
        state.setDeleteListenFailure(nil)
        do {
            try await runtime.deleteListen(listen)
            state.cancelDeleteListen()
            TracklogAccessibilityAnnouncer.announce(
                "Deleted “\(listen.processed.title)” from this Mac's history. "
                    + "Services were not changed.",
            )
        } catch let error as ListenMutationError {
            state.setDeleteListenFailure(error.message)
            state.setDeletingListen(false)
        } catch {
            state.setDeleteListenFailure("This listen could not be deleted.")
            state.setDeletingListen(false)
        }
    }
}
