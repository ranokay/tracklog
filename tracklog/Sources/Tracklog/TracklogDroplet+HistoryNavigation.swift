import AppKit
import DroppyKit
import Foundation
import SwiftUI
import TracklogCore
import UniformTypeIdentifiers

// MARK: - History navigation

extension TracklogDroplet {
    // MARK: - History

    /// What the History view runs when it appears. A pending one-shot jump
    /// takes priority; otherwise History opens at the newest feed.
    func openHistory() async {
        guard let runtime else { return }
        if state.pendingHistoryJump != nil {
            await runtime.applyPendingHistoryJump()
        } else if state.historyJumpNotice == nil,
                  !state.historyJumpInFlight {
            // A jumped window opened just before the surface mounted must not
            // be replaced by the feed load. A detail may be opening at the
            // same moment; reloadHistory loads the newest rows underneath it
            // without closing it.
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
        if openSettingsPage(tracklogHistoryPageID, title: "History", dismissOnRefusal: false) {
            state.setHistorySettingsUnavailable(false)
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

    /// Leaving the History section or the takeover returns the next open to
    /// the newest feed, never an old jump position. An open detail is reset by
    /// the takeover handler, not here: the detail view replaces this section
    /// while it is up.
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

    // MARK: - Entity details

    func openEntityDetail(_ request: EntityRequest) {
        Task { await runtime?.openEntityDetail(request) }
    }

    /// An in-page link, such as a top-track row.
    func pushEntityDetail(_ request: EntityRequest) {
        Task { await runtime?.pushEntityDetail(request) }
    }

    func backEntityDetail() {
        Task { await runtime?.backEntityDetail() }
    }

    func closeEntityDetail() {
        runtime?.closeEntityDetail()
    }

    func reloadEntityDetail() async {
        await runtime?.reloadEntityDetail()
    }

    func loadMoreEntityListens() async {
        await runtime?.loadMoreEntityListens()
    }

    func retryEntityService() async {
        await runtime?.retryEntityService()
    }

    /// Opening a detail from a list that is already inside the takeover keeps
    /// the section. A detail opened when no takeover is up (the palette) opens
    /// History first, then presents the page there.
    func presentEntityDetail(_ request: EntityRequest) {
        let alreadyPresented = host?.notchSurface.expandedState.current?.surfaceID
            == tracklogHistorySurfaceID
        if !alreadyPresented {
            presentHistory()
        }
        openEntityDetail(request)
    }

    func openEntityDetailFromHistory(_ listen: Listen, kind: EntityKind) {
        let request = switch kind {
        case .artist: EntityRequest.artist(from: listen)
        case .album: EntityRequest.album(from: listen)
        case .track: EntityRequest.track(listen)
        }
        guard let request else { return }
        if state.entityDetail != nil {
            // A track page's rows reach this too. The detail is already open,
            // so the artist/album is an in-page push and Back returns to the
            // track. A History feed row has no detail and opens a fresh page.
            pushEntityDetail(request)
        } else {
            openEntityDetail(request)
        }
    }

    func openEntityDetailFromChart(_ item: ChartItem) {
        guard let request = EntityRequest.chartItem(
            item,
            type: state.chartState.selection.type,
        ) else { return }
        openEntityDetail(request)
    }

    func openEntityDetailFromLoved(_ row: LovedRow, kind: EntityKind) {
        let request: EntityRequest? = switch kind {
        case .artist: EntityRequest.artist(name: row.artist)
        case .album: EntityRequest.album(album: row.album, artist: row.artist)
        case .track: EntityRequest.lovedRow(row)
        }
        guard let request else { return }
        presentEntityDetail(request)
    }

    func selectTakeoverSection(_ section: TakeoverSection) {
        guard section != state.takeoverSection else { return }
        closeEntityDetail()
        state.setTakeoverSection(section)
    }

    // MARK: - Images

    func beginImageOverride(for detail: EntityDetail) {
        guard let draft = ImageOverrideDraft(request: detail.request) else { return }
        runtime?.beginImageOverride(detail.request)
        let opened = openSettingsPage(tracklogImagesPageID, title: "Images", dismissOnRefusal: false)
        if !opened {
            runtime?.clearImageOverrideDraft()
            state.setImageOverrideError("Settings could not be opened here. Open Tracklog's Images settings from Droppy Settings.")
        } else {
            state.setImageOverrideDraft(draft)
        }
    }

    func removeDetailImage(_ detail: EntityDetail) {
        guard detail.canRemoveImage, detail.request.kind.supportsImageOverride else { return }
        Task {
            do {
                try await runtime?.removeImageOverride(
                    kind: detail.request.kind,
                    key: detail.request.key,
                )
            } catch {
                state.setImageOverrideError("The image could not be removed. \(error)")
            }
        }
    }

    func removeImageOverride(_ override: ImageOverride) {
        Task {
            do {
                try await runtime?.removeImageOverride(kind: override.kind, key: override.key)
            } catch {
                state.setImageOverrideError("The image could not be removed. \(error)")
            }
        }
    }

    /// The Images page left the screen. The draft is transient: if the picker
    /// was cancelled or the host popped the page, the next visit starts clean.
    func finishImagesSettingsPage() {
        runtime?.clearImageOverrideDraft()
    }

    func dismissImageOverrideError() {
        state.setImageOverrideError(nil)
    }

    func openLastFMAppCredentialsPageFromDetail() {
        if !openSettingsPage(
            tracklogLastFMAppCredentialsPageID,
            title: "Last.fm app credentials",
            dismissOnRefusal: false,
        ) {
            state.setImageOverrideError("Settings could not be opened here. Open the Last.fm app credentials page from Droppy Settings.")
        }
    }

    /// The Images page's file picker. The data is read before it reaches the
    /// store; a selection over the input limit never enters memory, and a
    /// failed decode leaves any existing override untouched.
    ///
    /// The entity is captured before the panel runs. `runModal` blocks the app,
    /// but the off-main file read does not: the page can leave (clearing the
    /// draft) or the user can start Replace on another row while the bytes are
    /// read. The save is addressed to the captured entity, and only a draft
    /// that still names it is consumed. The task is owned by the droplet, and
    /// the activation generation plus the runtime identity stop a read that
    /// survives deactivation from saving through a replacement runtime.
    func chooseImageOverrideFile(for draft: ImageOverrideDraft) {
        guard imageOverridePanel == nil, host != nil else { return }
        guard let runtime else {
            state.setImageOverrideError("The image could not be saved. Tracklog is not active.")
            return
        }
        let chosen = draft
        let generation = imageOverrideGeneration
        imageOverrideTask?.cancel()
        imageOverrideTask = nil
        imageOverrideOperationID = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Choose an artist or album image"
        imageOverridePanel = panel
        let response = panel.runModal()
        if imageOverridePanel === panel {
            imageOverridePanel = nil
        }
        guard response == .OK, let url = panel.url else { return }

        let operationID = UUID()
        imageOverrideOperationID = operationID
        imageOverrideTask = Task { [weak self] in
            defer {
                if let self, self.imageOverrideOperationID == operationID {
                    self.imageOverrideTask = nil
                    self.imageOverrideOperationID = nil
                }
            }
            guard let self else { return }
            // Reading up to 20 MiB must not run on the main actor with capture.
            let result = await Task.detached(priority: .userInitiated) {
                ImageOverrideFileReader.read(url)
            }.value
            guard imageOverrideOperationID == operationID,
                  imageOverrideGeneration == generation,
                  self.runtime === runtime,
                  !Task.isCancelled
            else { return }
            await applyImageOverrideRead(result, to: chosen, runtime: runtime)
        }
    }

    /// The read has already passed the ownership checks. A failed save keeps
    /// the error in state so it is shown on this page or the next Images visit.
    private func applyImageOverrideRead(
        _ result: Result<Data, ImageOverrideFileReadError>,
        to chosen: ImageOverrideDraft,
        runtime: CaptureRuntime,
    ) async {
        switch result {
        case let .success(data):
            do {
                try await runtime.saveImageOverride(
                    kind: chosen.kind,
                    key: chosen.key,
                    title: chosen.title,
                    subtitle: chosen.subtitle,
                    data: data,
                )
                state.setImageOverrideError(nil)
            } catch {
                state.setImageOverrideError(
                    (error as? LocalizedError)?.errorDescription
                        ?? "That image could not be read. Choose another image.",
                )
                host?.log.notice("Choosing an image failed")
            }
        case .failure(.tooLarge):
            state.setImageOverrideError(ImageOverrideError.tooLarge.errorDescription)
        case .failure(.unreadable):
            state.setImageOverrideError(ImageOverrideError.unreadable.errorDescription)
        }
    }

    func openListenBrainzLink(_ url: URL) {
        if host?.workspace.open(url) != true {
            host?.log.notice("Opening a ListenBrainz page was refused")
        }
    }

    func openServiceLink(_ url: URL) {
        if host?.workspace.open(url) != true {
            host?.log.notice("Opening a service page was refused")
        }
    }

    func setArtistImageLookupsEnabled(_ enabled: Bool) {
        runtime?.setArtistImageLookupsEnabled(enabled)
    }

    var artistImageLookupsBinding: Binding<Bool> {
        Binding(
            get: { self.state.artistImageLookupsEnabled },
            set: { self.setArtistImageLookupsEnabled($0) },
        )
    }
}
