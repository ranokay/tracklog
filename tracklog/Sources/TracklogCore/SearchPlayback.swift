import Foundation

/// What one play or Last.fm action did. The caller decides where a failure is
/// shown; the palette keeps it inline, the takeover uses its refusal bar.
public enum PlaybackOutcome: Equatable, Sendable {
    case opened(URL)
    case openedSettings
    case noPage
    case noQuery
    case refused(URL)
    case refusedPage(URL)
    case settingsRefused

    /// A sentence the caller can show as-is, or nil when the action worked.
    public var failureMessage: String? {
        switch self {
        case .opened, .openedSettings:
            nil
        case .noPage:
            "No Last.fm page is available for this result."
        case .noQuery:
            "There is nothing to search for."
        case .refused:
            "Search and play could not be opened. Check the URL template in Search settings."
        case .refusedPage:
            "The Last.fm page could not be opened. Try again, or open it in your browser."
        case .settingsRefused:
            "Settings could not be opened here. Open Tracklog's Search settings to set a playback URL."
        }
    }
}

/// The play / Last.fm action layer. The opener is injected, so a refused host
/// call is a visible outcome rather than a log line.
@MainActor
public struct SearchPlayback {
    public let template: SearchTemplate?
    private let openURL: @MainActor (URL) -> Bool
    private let openSettings: @MainActor () -> Bool

    public init(
        template: SearchTemplate?,
        openURL: @escaping @MainActor (URL) -> Bool,
        openSettings: @escaping @MainActor () -> Bool,
    ) {
        self.template = template
        self.openURL = openURL
        self.openSettings = openSettings
    }

    /// A palette row's primary action: search and play when a template is
    /// set, otherwise the row's own Last.fm page.
    public func performPrimary(_ row: CatalogueRow) -> PlaybackOutcome {
        if template != nil {
            return play(query: row.playbackQuery)
        }
        return openLastFMPage(row)
    }

    /// The Play action on existing surfaces. With no template the Settings
    /// page is the remedy.
    public func play(query: String) -> PlaybackOutcome {
        guard let template else {
            return openSettings() ? .openedSettings : .settingsRefused
        }
        guard let url = template.url(for: query) else {
            return .noQuery
        }
        return open(url)
    }

    /// Command-Return. The Last.fm page is the service's, never the template's.
    public func openLastFMPage(_ row: CatalogueRow) -> PlaybackOutcome {
        guard let url = row.pageURL else { return .noPage }
        return openURL(url) ? .opened(url) : .refusedPage(url)
    }

    private func open(_ url: URL) -> PlaybackOutcome {
        openURL(url) ? .opened(url) : .refused(url)
    }
}
