import Foundation
import TracklogCore

/// Deterministic catalogue states the harness can open. The client is never
/// used outside `host.environment.isHarness`.
enum HarnessPaletteFixture: String, CaseIterable {
    case normal
    case loading
    case empty
    case failed
    case credentialsMissing = "credentials-missing"
    case credentialsRejected = "credentials-rejected"
    case longNames = "long-names"
    case cjk
    case lovedUnavailable = "loved-unavailable"
    case lovedLimit = "loved-limit"
    case failedLaunch = "failed-launch"
    case refusal

    static var selected: HarnessPaletteFixture? {
        let raw = ProcessInfo.processInfo.environment["TRACKLOG_HARNESS_PALETTE"] ?? ""
        return HarnessPaletteFixture(rawValue: raw)
    }

    var opensPanel: Bool {
        self != .refusal
    }

    var linksLastFM: Bool {
        self != .lovedUnavailable
    }

    var query: String {
        switch self {
        case .cjk: "宇多田"
        case .lovedLimit: "heart"
        default: "blo"
        }
    }

    var usesPlaybackTemplate: Bool {
        self == .normal || self == .longNames || self == .cjk || self == .failedLaunch
    }

    /// Every fixture but the missing-credentials one pretends a pair is saved,
    /// so the palette exercises the catalogue instead of the remedy banner.
    var configuresAppCredentials: Bool {
        self != .credentialsMissing
    }
}

enum HarnessPaletteDemo {
    @MainActor
    static func show(_ fixture: HarnessPaletteFixture, on droplet: TracklogDroplet) async {
        if fixture == .refusal {
            droplet.state.setSearchRefusal(
                "Search and play could not be opened. Check the URL template in Search settings.",
            )
            return
        }
        if fixture == .credentialsRejected {
            droplet.runtime?.noteLastFMAppCredentialProblem(.invalidKey)
        }
        droplet.openSearchPalette()
        droplet.searchPaletteController.model.query = fixture.query
        droplet.paletteQueryChanged(fixture.query)
        guard fixture == .failedLaunch else { return }

        try? await Task.sleep(for: .seconds(1.2))
        droplet.searchPaletteController.model.onActivate?()
    }
}

/// The harness catalogue. Every state is deterministic and needs no network.
struct HarnessDemoCatalogue: CatalogueSearching {
    let fixture: HarnessPaletteFixture

    func search(
        _ group: CatalogueGroupKind,
        query _: String,
        limit: Int,
    ) async throws -> CataloguePage {
        switch fixture {
        case .loading:
            try await Task.sleep(for: .seconds(600))
            return CataloguePage(rows: [], hasMore: false)
        case .empty:
            return CataloguePage(rows: [], hasMore: false)
        case .credentialsMissing:
            throw ServiceFailure.appCredentialAuth(.missing)
        case .credentialsRejected:
            throw ServiceFailure.appCredentialAuth(.invalidKey)
        case .failed where group == .artists:
            throw ServiceFailure.retryable
        case .longNames:
            return CataloguePage(rows: longRows(group), hasMore: false)
        case .cjk:
            return CataloguePage(rows: cjkRows(group), hasMore: false)
        default:
            return CataloguePage(rows: rows(group, limit: limit), hasMore: false)
        }
    }

    func lovedTracks(account _: String, page: Int, limit _: Int) async throws -> CataloguePage {
        switch fixture {
        case .loading:
            try await Task.sleep(for: .seconds(600))
            return CataloguePage(rows: [], hasMore: false)
        case .empty:
            return CataloguePage(rows: [], hasMore: false)
        case .credentialsMissing:
            throw ServiceFailure.appCredentialAuth(.missing)
        case .credentialsRejected:
            throw ServiceFailure.appCredentialAuth(.invalidKey)
        case .failed:
            return CataloguePage(rows: [], hasMore: false)
        case .longNames:
            return CataloguePage(rows: longRows(.loved), hasMore: false)
        case .cjk:
            return CataloguePage(rows: cjkRows(.loved), hasMore: false)
        case .lovedLimit:
            let rows = [
                lovedRow("Heart of Glass \(page)"),
                lovedRow("Heart of Mine \(page)"),
                lovedRow("Other Track \(page)"),
            ]
            return CataloguePage(rows: rows, hasMore: page < 9)
        default:
            return CataloguePage(rows: lovedRows(), hasMore: false)
        }
    }

    // MARK: - Rows

    private func rows(_ group: CatalogueGroupKind, limit: Int) -> [CatalogueRow] {
        var names: [(String, String)] = []
        switch group {
        case .artists:
            names = [
                ("Blondie", ""),
                ("Bloc Party", ""),
                ("The Bloody Beetroots", ""),
                ("Blonde Redhead", ""),
                ("Blondie cover band", ""),
                ("Bloc", ""),
                ("Blood Orange", ""),
                ("Bloom", ""),
                ("Blossoms", ""),
                ("Blondshell", ""),
            ]
        case .albums:
            names = [
                ("Parallel Lines", "Blondie"),
                ("Silent Alarm", "Bloc Party"),
                ("Hide", "The Bloody Beetroots"),
                ("Misery Is a Butterfly", "Blonde Redhead"),
                ("Eat to the Beat", "Blondie"),
                ("Weekend in the City", "Bloc Party"),
                ("Cupid Deluxe", "Blood Orange"),
                ("In Love with a Ghost", "Bloom"),
                ("Blossoms", "Blossoms"),
                ("Blondshell", "Blondshell"),
            ]
        case .tracks:
            names = [
                ("Heart of Glass", "Blondie"),
                ("One Way or Another", "Blondie"),
                ("Call Me", "Blondie"),
                ("Banquet", "Bloc Party"),
                ("This Modern Love", "Bloc Party"),
                ("Warhol", "The Bloody Beetroots"),
                ("23", "Blonde Redhead"),
                ("You're Not Good Enough", "Blood Orange"),
                ("Ghost", "Bloom"),
                ("Charlemagne", "Blossoms"),
            ]
        case .loved:
            names = lovedRows().map { ($0.title, $0.subtitle) }
        }
        return Array(names.prefix(limit).map { value in
            row(group, title: value.0, subtitle: value.1, index: 0)
        })
    }

    private func lovedRows() -> [CatalogueRow] {
        [
            lovedRow("Heart of Glass"),
            lovedRow("Dreaming"),
            lovedRow("The Tide Is High"),
            lovedRow("Sunday Girl"),
            lovedRow("Atomic"),
            lovedRow("Call Me"),
            lovedRow("One Way or Another"),
            lovedRow("Hanging on the Telephone"),
        ]
    }

    private func lovedRow(_ title: String) -> CatalogueRow {
        row(.loved, title: title, subtitle: "Blondie", index: 0)
    }

    private func row(_ group: CatalogueGroupKind, title: String, subtitle: String, index _: Int) -> CatalogueRow {
        CatalogueRow(
            group: group,
            title: title,
            subtitle: subtitle,
            playbackQuery: query(group, title: title, subtitle: subtitle),
            pageURL: URL(string: "https://www.last.fm/music/\(slug(subtitle.isEmpty ? title : subtitle))"),
        )
    }

    private func query(_ group: CatalogueGroupKind, title: String, subtitle: String) -> String {
        switch group {
        case .artists: title
        case .albums, .tracks, .loved: CatalogueQuery.combined(subtitle, title)
        }
    }

    private func slug(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "music"
    }

    private func longRows(_ group: CatalogueGroupKind) -> [CatalogueRow] {
        let title = switch group {
        case .artists:
            "The Extremely Long-Named Artist Collective Featuring a Very Long Credit "
                + "and an Even Longer Guest Appearance (Remastered Anniversary Edition)"
        case .albums:
            "Songs of the Deep and the Distant (Deluxe Edition with Bonus Recordings, "
                + "Live Sessions and a 40-Page Booklet)"
        case .tracks, .loved:
            "The Rise and Fall of the City of Mahagonny (Live at the Metropolitan Opera, "
                + "Remastered 25th Anniversary Edition)"
        }
        let subtitle = group == .artists
            ? ""
            : "The Extremely Long-Named Artist Collective Featuring a Very Long Credit and an Even Longer Guest Appearance"
        return (0 ..< 8).map { index in
            row(group, title: "\(title) \(index + 1)", subtitle: subtitle, index: index)
        }
    }

    private func cjkRows(_ group: CatalogueGroupKind) -> [CatalogueRow] {
        var values: [(String, String)] = []
        switch group {
        case .artists:
            values = [("宇多田ヒカル", ""), ("坂本龍一", ""), ("椎名林檎", ""), ("米津玄師", "")]
        case .albums:
            values = [("Fantôme", "宇多田ヒカル"), ("async", "坂本龍一"), ("勝訴ストリップ", "椎名林檎")]
        case .tracks:
            values = [
                ("Flavor of Life", "宇多田ヒカル"),
                ("Beautiful World", "宇多田ヒカル"),
                ("Merry Christmas Mr. Lawrence", "坂本龍一"),
            ]
        case .loved:
            values = [("Flavor of Life", "宇多田ヒカル"), ("First Love", "宇多田ヒカル")]
        }
        return values.map { value in
            row(group, title: value.0, subtitle: value.1, index: 0)
        }
    }
}
