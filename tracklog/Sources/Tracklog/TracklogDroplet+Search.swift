import AppKit
import DroppyKit
import SwiftUI
import TracklogCore

// MARK: - Opening and closing

extension TracklogDroplet {
    /// One surface at a time: the takeover is dismissed before the panel is
    /// presented. A second summon while the panel is open closes it.
    func openSearchPalette() {
        guard host != nil else { return }
        if searchPaletteController.isOpen {
            searchPaletteController.close()
            return
        }
        dismissTakeoverForSettings()
        state.setSearchRefusal(nil)
        searchPaletteController.open()
    }

    func paletteQueryChanged(_ text: String) {
        runtime?.catalogueSearch?.updateQuery(text)
    }

    func retryCatalogueSearch() {
        runtime?.catalogueSearch?.retry()
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

    func playPaletteRow(_ row: CatalogueRow) -> PlaybackOutcome {
        searchPlaybackAction.performPrimary(row)
    }

    func openLastFMPageFromPalette(_ row: CatalogueRow) -> PlaybackOutcome {
        searchPlaybackAction.openLastFMPage(row)
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
