import AppKit
import DroppyKit
import SwiftUI
import TracklogCore

// MARK: - Opening and closing

extension TracklogDroplet {
    /// One surface at a time: the takeover is dismissed before the panel is
    /// presented. A second summon while the panel is open or about to open
    /// closes it.
    ///
    /// The session is prepared here and the panel is ordered front on the next
    /// run-loop turn, so the click's gesture returns before the host's panel
    /// activation runs.
    func openSearchPalette() {
        guard host != nil else { return }
        if searchPaletteController.isPrepared {
            searchPaletteController.close()
            return
        }
        dismissTakeoverForSettings()
        state.setSearchRefusal(nil)
        searchPaletteController.prepare()
        searchPaletteController.presentAfterGesture()
    }

    func paletteQueryChanged(_ text: String) {
        runtime?.catalogueSearch?.updateQuery(text)
    }

    func retryCatalogueSearch() {
        runtime?.catalogueSearch?.retry()
    }

    /// Return on a palette row. The panel closes before the takeover presents,
    /// so only one droplet surface is ever up.
    func openPaletteRowDetails(_ row: CatalogueRow) {
        guard let request = EntityRequest.catalogueRow(row) else { return }
        searchPaletteController.close()
        presentEntityDetail(request)
    }
}

// MARK: - Playing

extension TracklogDroplet {
    var searchPlaybackAction: SearchPlayback {
        SearchPlayback(
            template: state.playbackTemplate,
            openURL: { [weak self] url in
                guard let self else { return false }
                if host?.environment.isHarness == true,
                   ProcessInfo.processInfo.environment["TRACKLOG_HARNESS_OPEN_REFUSED"] == "1" {
                    return false
                }
                return host?.workspace.open(url) ?? false
            },
            openSettings: { [weak self] in
                self?.openSearchSettingsPageFromSurface() ?? false
            },
        )
    }

    /// The panel closes and hands the foreground back before the URL opens, so
    /// the browser lands in front. A refused open or a missing page reopens
    /// the same search session with the inline notice.
    func playPaletteRow(_ row: CatalogueRow) {
        searchPaletteController.close(endingSearch: false)
        finishPaletteAction(searchPlaybackAction.performPrimary(row))
    }

    func openLastFMPageFromPalette(_ row: CatalogueRow) {
        searchPaletteController.close(endingSearch: false)
        finishPaletteAction(searchPlaybackAction.openLastFMPage(row))
    }

    private func finishPaletteAction(_ outcome: PlaybackOutcome) {
        switch outcome {
        case .opened, .openedSettings:
            runtime?.catalogueSearch?.endSession()
        case .noPage, .noQuery, .refused, .refusedPage, .settingsRefused:
            guard let message = outcome.failureMessage else { return }
            searchPaletteController.open(reusingSession: true, notice: message)
        }
    }

    /// The Play action on the existing surfaces. With no template the Search
    /// settings page is the remedy; a refused launch or handoff is shown in
    /// the takeover's refusal bar.
    func searchAndPlay(title: String, artist: String) {
        reportPlayback(searchPlaybackAction.play(
            query: CatalogueQuery.track(artist: artist, title: title),
        ))
    }

    func searchAndPlay(query: String) {
        reportPlayback(searchPlaybackAction.play(query: query))
    }

    private func reportPlayback(_ outcome: PlaybackOutcome) {
        switch outcome {
        case .opened, .openedSettings:
            state.setSearchRefusal(nil)
        case .noPage, .noQuery, .refused, .refusedPage, .settingsRefused:
            state.setSearchRefusal(outcome.failureMessage)
        }
    }
}

// MARK: - Settings handoffs

extension TracklogDroplet {
    /// The surface handoff. On success the host closes the takeover; on a
    /// refusal the takeover stays and shows the refusal bar.
    func openSearchSettingsPageFromSurface() -> Bool {
        guard host != nil else { return false }
        return openSettingsPage(
            tracklogSearchPageID,
            title: "Search and play",
            dismissOnRefusal: false,
        )
    }

    /// The palette closes before Settings opens. A refused handoff reopens the
    /// same search session with an inline notice instead of leaving nothing.
    func openSearchSettingsFromPalette() {
        handOffSettings(
            pageID: tracklogSearchPageID,
            title: "Search and play",
            refusal: "Settings could not be opened here. Open Tracklog's Search settings from Droppy Settings.",
        )
    }

    func openLastFMAppCredentialsFromPalette() {
        handOffSettings(
            pageID: tracklogLastFMAppCredentialsPageID,
            title: "Last.fm app credentials",
            refusal: "Settings could not be opened here. Open the Last.fm app credentials page from Droppy Settings.",
        )
    }

    private func handOffSettings(pageID: String, title: String, refusal: String) {
        let wasOpen = searchPaletteController.isOpen
        searchPaletteController.close(endingSearch: false)
        let opened = openSettingsPage(pageID, title: title, dismissOnRefusal: false)
        if opened {
            runtime?.catalogueSearch?.endSession()
        } else if wasOpen {
            searchPaletteController.open(reusingSession: true, notice: refusal)
        }
    }
}

// MARK: - Template settings

extension TracklogDroplet {
    func savePlaybackTemplate(_ raw: String) throws {
        guard let runtime else { throw ConnectionError.unavailable }
        try runtime.savePlaybackTemplate(raw)
    }

    func removePlaybackTemplate() {
        runtime?.removePlaybackTemplate()
    }
}
