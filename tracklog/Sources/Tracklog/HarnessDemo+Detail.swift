import AppKit
import Foundation
import TracklogCore

/// Harness-only detail scenarios. Production never reads this environment
/// value.
enum HarnessDetailFixture: String {
    case artist
    case album
    case track
    case artistNoConnection = "artist-no-connection"
    case albumListenBrainz = "album-listenbrainz"
    case artistApproximate = "artist-approximate"
    case artistAmbiguous = "artist-ambiguous"
    case override
    case corruptOverride = "corrupt-override"
    case longNames = "long-names"

    static var selected: HarnessDetailFixture? {
        let raw = ProcessInfo.processInfo.environment["TRACKLOG_HARNESS_DETAIL"] ?? ""
        return HarnessDetailFixture(rawValue: raw)
    }

    var linksLastFM: Bool {
        switch self {
        case .artist, .album, .track, .artistApproximate, .artistAmbiguous,
             .override, .corruptOverride, .longNames:
            true
        case .artistNoConnection, .albumListenBrainz:
            false
        }
    }

    var linksListenBrainz: Bool {
        self == .albumListenBrainz
    }
}

@MainActor
enum HarnessDetailDemo {
    static let listenBrainzAlbumMBID = "9c8f7a1e-2f4d-4a1e-8d4c-2b7c6e5a1f30"

    static func show(on droplet: TracklogDroplet) async {
        guard let fixture = HarnessDetailFixture.selected,
              let runtime = droplet.runtime
        else { return }

        if fixture == .longNames {
            await insertLongListen(on: droplet)
        }
        if fixture == .override || fixture == .corruptOverride {
            await insertOverride(on: droplet, corrupt: fixture == .corruptOverride)
        }

        let section = ProcessInfo.processInfo.environment["TRACKLOG_HARNESS_SECTION"]
        let paletteFixture = HarnessPaletteFixture.selected != nil
        if fixture == .override, section == "charts" || paletteFixture {
            // A shot of the chart or palette row carrying the override; the
            // detail itself is covered by the plain override fixture.
            await runtime.loadImageOverrides()
            return
        }

        guard let request = request(for: fixture) else { return }
        await runtime.loadImageOverrides()
        await runtime.openEntityDetail(request)
        if fixture == .override,
           ProcessInfo.processInfo.environment["TRACKLOG_HARNESS_SETTINGS_PAGE"] == "images" {
            // The gate's Images page shot shows the picker beginning of the
            // Change image… flow, not only the saved list.
            runtime.beginImageOverride(request)
        }
    }

    private static func request(for fixture: HarnessDetailFixture) -> EntityRequest? {
        switch fixture {
        case .artist, .artistNoConnection, .artistApproximate, .artistAmbiguous,
             .override, .corruptOverride:
            EntityRequest.artist(name: fixture == .corruptOverride ? "Talking Heads" : "Blondie")
        case .album:
            EntityRequest.album(album: "Parallel Lines", artist: "Blondie")
        case .track:
            EntityRequest.track(
                title: "Heart of Glass",
                artist: "Blondie",
                album: "Parallel Lines",
            )
        case .albumListenBrainz:
            EntityRequest(
                kind: .album,
                key: LocalAlbumIdentity.key(album: "Parallel Lines", artist: "Blondie") ?? "",
                title: "Parallel Lines",
                subtitle: "Blondie",
                providerID: listenBrainzAlbumMBID,
            )
        case .longNames:
            EntityRequest.artist(name: HarnessDemo.longTrack.artist)
        }
    }

    private static func insertLongListen(on droplet: TracklogDroplet) async {
        guard let store = droplet.harnessStore else { return }
        let title = HarnessDemo.longTrack.title
        let artist = HarnessDemo.longTrack.artist
        let album = HarnessDemo.longTrack.album
        let metadata = ListenMetadata(title: title, artist: artist, album: album)
        _ = try? await store.insert(
            Listen(
                raw: metadata,
                processed: metadata,
                bundleID: "com.apple.Music",
                duration: 225,
                playedDuration: 225,
                startedAt: Date().addingTimeInterval(-7_200),
                capturedAt: Date().addingTimeInterval(-6_975),
            ),
        )
    }

    private static func insertOverride(on droplet: TracklogDroplet, corrupt: Bool) async {
        guard let store = droplet.harnessStore else { return }
        let key = LocalArtistIdentity.key(name: corrupt ? "Talking Heads" : "Blondie") ?? ""
        let hash: String
        var artwork: StoredArtwork?
        if corrupt {
            hash = "harness-missing-cover"
        } else if let made = HarnessDemoData.makeArtwork(
            HarnessDemoData.DemoColor(red: 0.86, green: 0.34, blue: 0.18),
        ) {
            hash = made.hash
            artwork = made
        } else {
            return
        }
        await store.seedImageOverride(
            ImageOverride(
                kind: .artist,
                key: key,
                title: corrupt ? "Talking Heads" : "Blondie",
                artworkHash: hash,
                updatedAt: Date(),
            ),
            artwork: artwork,
        )
    }
}

// MARK: - Scripted artist image

/// One deterministic iTunes answer. The real client and the exact-match rule
/// are unchanged; only the transport's answer is scripted.
struct HarnessArtistImageSearch: ArtistImageSearching {
    func albums(forArtist name: String, limit _: Int) async throws -> [ArtistImageAlbum] {
        let fixture = HarnessDetailFixture.selected
        guard fixture == .artistApproximate || fixture == .artistAmbiguous else {
            return []
        }
        let artwork = URL(string: "https://harness.invalid/artist.jpg")
        if fixture == .artistAmbiguous {
            return [
                ArtistImageAlbum(artistID: "1", artistName: name, artworkURL: artwork),
                ArtistImageAlbum(artistID: "2", artistName: name, artworkURL: artwork),
            ]
        }
        return [
            ArtistImageAlbum(
                artistID: "1",
                artistName: name.uppercased(),
                artworkURL: artwork,
            ),
        ]
    }
}

struct HarnessRemoteImageLoader: RemoteImageLoading {
    func imageData(at url: URL) async throws -> Data {
        let color: HarnessDemoData.DemoColor = url.lastPathComponent.contains("artist")
            ? HarnessDemoData.DemoColor(red: 0.34, green: 0.62, blue: 0.46)
            : HarnessDemoData.DemoColor(red: 0.52, green: 0.36, blue: 0.72)
        guard let artwork = HarnessDemoData.makeArtwork(color) else {
            throw ArtistImageError.unreadable
        }
        return artwork.data
    }
}

// MARK: - Last.fm detail facts

extension HarnessDemoLastFMAdapter: EntityServiceReading {
    func entityDetails(
        _ request: EntityRequest,
        connection: Connection,
    ) async throws -> EntityServiceFacts {
        let fixture = HarnessDetailFixture.selected
        if fixture == .artistAmbiguous {
            throw EntityServiceReadError.missing
        }
        let artworkURL = URL(string: "https://harness.invalid/album.jpg")
        switch request.kind {
        case .artist:
            return EntityServiceFacts(
                serviceName: "Last.fm",
                accountName: connection.displayName,
                facts: [
                    EntityFact(label: "Listeners on Last.fm", value: "1,284,902"),
                    EntityFact(label: "Plays on Last.fm", value: "22,481,003"),
                    EntityFact(label: "Your plays", value: "142"),
                ],
                link: URL(string: "https://www.last.fm/music/Blondie"),
            )
        case .album:
            return EntityServiceFacts(
                serviceName: "Last.fm",
                accountName: connection.displayName,
                facts: [
                    EntityFact(label: "Released", value: "23 September 1978"),
                    EntityFact(label: "Listeners on Last.fm", value: "842,110"),
                    EntityFact(label: "Plays on Last.fm", value: "9,204,551"),
                    EntityFact(label: "Your plays", value: "61"),
                ],
                link: URL(string: "https://www.last.fm/music/Blondie/Parallel+Lines"),
                artworkURL: artworkURL,
            )
        case .track:
            return EntityServiceFacts(
                serviceName: "Last.fm",
                accountName: connection.displayName,
                facts: [
                    EntityFact(label: "Duration", value: "3:54"),
                    EntityFact(label: "Listeners on Last.fm", value: "1,120,534"),
                    EntityFact(label: "Plays on Last.fm", value: "8,400,221"),
                    EntityFact(label: "Your plays", value: "88"),
                ],
                link: URL(string: "https://www.last.fm/music/Blondie/_/Heart+of+Glass"),
            )
        }
    }
}

// MARK: - Store detail half

extension HarnessDemoStore: EntityDetailStore {
    func entityLocalDetail(
        kind: EntityKind,
        key: String,
        topTrackLimit: Int,
    ) async throws -> EntityLocalDetail {
        var count = 0
        var first: Date?
        var last: Date?
        var captured: String?
        var aggregator = LocalChartAggregator(type: .tracks)
        for listen in listens.sorted(by: {
            if $0.startedAt != $1.startedAt {
                return $0.startedAt < $1.startedAt
            }
            return ($0.id ?? 0) < ($1.id ?? 0)
        }) {
            guard matches(kind: kind, key: key, metadata: listen.processed) else { continue }
            count += 1
            if first == nil {
                first = listen.startedAt
            }
            last = listen.startedAt
            if captured == nil {
                captured = listen.artworkHash
            }
            if kind != .track, topTrackLimit > 0 {
                aggregator.add(
                    title: listen.processed.title,
                    artist: listen.processed.artist,
                    album: listen.processed.album,
                    albumArtist: listen.processed.albumArtist,
                    artworkHash: listen.artworkHash,
                )
            }
        }
        return EntityLocalDetail(
            count: count,
            firstListenedAt: first,
            lastListenedAt: last,
            topTracks: kind == .track || topTrackLimit <= 0
                ? []
                : aggregator.finish(limit: topTrackLimit).items,
            capturedArtworkHash: captured,
        )
    }

    private func matches(kind: EntityKind, key: String, metadata: ListenMetadata) -> Bool {
        switch kind {
        case .artist:
            return LocalArtistIdentity.key(name: metadata.artist) == key
        case .album:
            let subtitle = metadata.albumArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? metadata.artist
                : metadata.albumArtist
            return LocalAlbumIdentity.key(album: metadata.album, artist: subtitle) == key
        case .track:
            return LocalTrackIdentity.key(title: metadata.title, artist: metadata.artist) == key
        }
    }

    func imageOverrides() async throws -> [ImageOverride] {
        imageOverrideRows.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    func imageOverride(kind: EntityKind, key: String) async throws -> ImageOverride? {
        imageOverrideRows["\(kind.rawValue)\u{1F}\(key)"]
    }

    func saveImageOverride(_ override: ImageOverride, artwork: StoredArtwork) async throws {
        artworks[artwork.hash] = artwork
        imageOverrideRows["\(override.kind.rawValue)\u{1F}\(override.key)"] = override
    }

    func removeImageOverride(kind: EntityKind, key: String) async throws {
        imageOverrideRows.removeValue(forKey: "\(kind.rawValue)\u{1F}\(key)")
    }

    /// Harness-only: seed an override before the detail page opens.
    func seedImageOverride(_ override: ImageOverride, artwork: StoredArtwork?) {
        if let artwork {
            artworks[artwork.hash] = artwork
        }
        imageOverrideRows["\(override.kind.rawValue)\u{1F}\(override.key)"] = override
    }

    func artistImageCache(forArtist key: String) async throws -> ArtistImageCacheEntry? {
        artistImageCacheRows[key]
    }

    func saveArtistImageCache(
        _ entry: ArtistImageCacheEntry,
        artwork: StoredArtwork?,
    ) async throws {
        if let artwork {
            artworks[artwork.hash] = artwork
        }
        artistImageCacheRows[entry.artistKey] = entry
    }

    func pruneExpiredArtistImageCache(now: Date) async throws {
        artistImageCacheRows = artistImageCacheRows.filter { $0.value.isFresh(now: now) }
    }
}
