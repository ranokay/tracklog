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
        } else if state.entityDetail == nil, state.historyJumpNotice == nil,
                  !state.historyJumpInFlight {
            // A detail or a jumped window opened just before the surface
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
        openEntityDetail(request)
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

    func finishImagesSettingsPage() {
        runtime?.clearImageOverrideDraft()
        host?.workspace.goBackInSettings()
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
    func chooseImageOverrideFile() {
        guard imageOverridePanel == nil, let host else { return }
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

        Task { [weak self] in
            guard let self else { return }
            do {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size > 0, size <= ImageOverridePolicy.maximumSourceBytes else {
                    throw ImageOverrideError.tooLarge
                }
                let accessing = url.startAccessingSecurityScopedResource()
                defer {
                    if accessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                let data = try Data(contentsOf: url)
                guard data.count <= ImageOverridePolicy.maximumSourceBytes else {
                    throw ImageOverrideError.tooLarge
                }
                try await runtime?.saveSelectedImageOverride(data)
                state.setImageOverrideError(nil)
            } catch {
                state.setImageOverrideError(
                    (error as? LocalizedError)?.errorDescription
                        ?? "That image could not be read. Choose another image.",
                )
                host.log.notice("Choosing an image failed")
            }
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
