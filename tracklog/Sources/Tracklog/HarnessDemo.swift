import CoreGraphics
import Foundation
import ImageIO
import TracklogCore
import UniformTypeIdentifiers

/// Deterministic content for the harness's surface shots. Droppy never sees
/// this: `host.environment.isHarness` is the only gate.
enum HarnessDemo {
    @MainActor
    static func showNowPlaying(on runtime: CaptureRuntime) async {
        let track = Track(
            title: "Heart of Glass",
            artist: "Blondie",
            album: "Parallel Lines",
            duration: 225,
            bundleID: "com.apple.Music",
        )
        await runtime.ingest(
            MediaSample(
                track: track,
                elapsed: 72,
                playbackRate: 1,
                isPlaying: true,
            ),
        )
        // The shot should show the demo cover, not the neutral sleeve. Artwork
        // is deliberately off the capture path, so wait for its task instead
        // of polling the published value.
        await runtime.waitForArtwork()
    }
}

@MainActor
final class HarnessDemoSource: NowPlayingSource {
    func start(
        onSample _: @escaping @MainActor (MediaSample?) -> Void,
        onStatus: @escaping @MainActor (MediaStatus) -> Void,
    ) {
        onStatus(mediaStatus)
    }

    func stop() {}
}

actor HarnessDemoStore: ListenStore, AppAllowlistStore, SimpleEditStore, BlockStore, ArtworkStore {
    private let listens: [Listen]
    private var artworks: [String: StoredArtwork]
    private var artworkHashes: [String: String]
    private var seenApps: [SeenApp]
    private var simpleEdits: [SimpleEditRule]
    private var blockRules: [BlockRule]

    init() {
        let content = HarnessDemoData.makeContent()
        listens = content.listens
        artworks = content.artworks
        artworkHashes = content.hashes
        seenApps = SeededPlayers.bundleIDs.map { SeenApp(bundleID: $0, isAllowed: true) }
            + [SeenApp(bundleID: "com.apple.podcasts", isAllowed: false)]
        simpleEdits = Self.makeSimpleEdits()
        blockRules = Self.makeBlocks()
    }

    func insert(_: Listen) async throws -> Listen? {
        nil
    }

    func page(limit: Int, before cursor: ListenCursor?) async throws -> [Listen] {
        guard let cursor else { return Array(listens.prefix(limit)) }
        guard let index = listens.firstIndex(where: { $0.id == cursor.id }) else { return [] }
        return Array(listens[(index + 1)...].prefix(limit))
    }

    func count() async throws -> Int {
        listens.count
    }

    func artwork(for hash: String) async throws -> Data? {
        artworks[hash]?.data
    }

    func artworkHash(forTrack identity: String) async throws -> String? {
        artworkHashes[identity]
    }

    func attachArtwork(_ artwork: StoredArtwork, toTrack identity: String) async throws {
        artworks[artwork.hash] = artwork
        artworkHashes[identity] = artwork.hash
    }

    func apps() async throws -> [SeenApp] {
        seenApps
    }

    func isAllowed(_ bundleID: String) async throws -> Bool {
        seenApps.first { $0.bundleID == bundleID }?.isAllowed ?? false
    }

    @discardableResult
    func recordSeen(_ bundleID: String) async throws -> SeenApp? {
        let normalized = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if let existing = seenApps.first(where: { $0.bundleID == normalized }) {
            return existing
        }
        let app = SeenApp(bundleID: normalized, isAllowed: false)
        seenApps.append(app)
        return app
    }

    func setAllowed(_ bundleID: String, allowed: Bool) async throws {
        guard let index = seenApps.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        seenApps[index].isAllowed = allowed
    }

    func edits() async throws -> [SimpleEditRule] {
        SimpleEditRule.sortedForApplication(simpleEdits)
    }

    @discardableResult
    func save(_ rule: SimpleEditRule) async throws -> SimpleEditRule {
        if let error = rule.validationError {
            throw error
        }
        let id = rule.id ?? (simpleEdits.map { $0.id ?? 0 }.max() ?? 0) + 1

        // Editing a tuple removes the old row; the tuple itself is the rule's
        // identity, as it is in the real store.
        if let old = simpleEdits.firstIndex(where: { $0.id == id }),
           !Self.sameMatch(simpleEdits[old].match, rule.match) {
            simpleEdits.remove(at: old)
        }

        if let index = simpleEdits.firstIndex(where: { Self.sameMatch($0.match, rule.match) }) {
            let existingID = simpleEdits[index].id ?? id
            let stored = rule.stored(withID: existingID, savedAt: rule.savedAt)
            simpleEdits[index] = stored
            return stored
        }

        let stored = rule.stored(withID: id, savedAt: rule.savedAt)
        simpleEdits.append(stored)
        return stored
    }

    func deleteEdit(id: Int64) async throws {
        simpleEdits.removeAll { $0.id == id }
    }

    private static func sameMatch(_ lhs: SimpleEditRule.Match, _ rhs: SimpleEditRule.Match) -> Bool {
        func normalized(_ value: String?) -> String? {
            value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return normalized(lhs.track) == normalized(rhs.track)
            && normalized(lhs.artist) == normalized(rhs.artist)
            && normalized(lhs.album) == normalized(rhs.album)
            && normalized(lhs.albumArtist) == normalized(rhs.albumArtist)
    }

    func blocks() async throws -> [BlockRule] {
        BlockRule.sortedForEvaluation(blockRules)
    }

    @discardableResult
    func save(_ block: BlockRule) async throws -> BlockRule {
        if let error = block.validationError {
            throw error
        }
        let id = block.id ?? (blockRules.map { $0.id ?? 0 }.max() ?? 0) + 1

        // Editing a tuple removes the old row; the tuple itself is the block's
        // identity, as it is in the real store.
        if let old = blockRules.firstIndex(where: { $0.id == id }),
           !Self.sameBlock(blockRules[old], block) {
            blockRules.remove(at: old)
        }

        if let index = blockRules.firstIndex(where: { Self.sameBlock($0, block) }) {
            let existingID = blockRules[index].id ?? id
            let stored = block.stored(withID: existingID, savedAt: block.savedAt)
            blockRules[index] = stored
            return stored
        }

        let stored = block.stored(withID: id, savedAt: block.savedAt)
        blockRules.append(stored)
        return stored
    }

    func deleteBlock(id: Int64) async throws {
        blockRules.removeAll { $0.id == id }
    }

    private static func sameBlock(_ lhs: BlockRule, _ rhs: BlockRule) -> Bool {
        normalized(lhs.track) == normalized(rhs.track)
            && normalized(lhs.artist) == normalized(rhs.artist)
            && normalized(lhs.album) == normalized(rhs.album)
            && normalized(lhs.albumArtist) == normalized(rhs.albumArtist)
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func makeBlocks() -> [BlockRule] {
        [
            BlockRule(
                id: 1,
                artist: "The Daily",
                savedAt: Date(timeIntervalSince1970: 1_000_000),
            ),
            BlockRule(
                id: 2,
                track: "Baby Shark",
                savedAt: Date(timeIntervalSince1970: 999_500),
            ),
            BlockRule(
                id: 3,
                album: "Sleep Sounds",
                savedAt: Date(timeIntervalSince1970: 999_000),
            ),
        ]
    }

    private static func makeSimpleEdits() -> [SimpleEditRule] {
        [
            SimpleEditRule(
                id: 1,
                match: .init(track: "Heart of Glass", artist: "Blondie"),
                replacement: .init(album: "Parallel Lines"),
                savedAt: Date(timeIntervalSince1970: 1_000_000),
            ),
            SimpleEditRule(
                id: 2,
                match: .init(album: "Rumours"),
                replacement: .init(album: ""),
                savedAt: Date(timeIntervalSince1970: 999_000),
            ),
            SimpleEditRule(
                id: 3,
                match: .init(artist: "Talking Heads"),
                replacement: .init(album: "Remain in Light (Deluxe)"),
                savedAt: Date(timeIntervalSince1970: 998_000),
            ),
        ]
    }
}

/// The harness's deterministic listens and covers. Kept out of the store actor
/// so the demo data reads as one piece and the actor stays a store.
private enum HarnessDemoData {
    struct DemoColor {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
    }

    struct DemoContent {
        let listens: [Listen]
        let artworks: [String: StoredArtwork]
        let hashes: [String: String]
    }

    static func makeContent() -> DemoContent {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        func at(_ day: Date, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }

        let rows = [
            DemoRow(id: 6, title: "Heart of Glass", artist: "Blondie", album: "Parallel Lines", startedAt: at(today, 18, 42)),
            DemoRow(id: 5, title: "Once in a Lifetime", artist: "Talking Heads", album: "Remain in Light", startedAt: at(today, 15, 10)),
            DemoRow(id: 4, title: "Dreams", artist: "Fleetwood Mac", album: "Rumours", startedAt: at(today, 12, 4)),
            DemoRow(id: 3, title: "Teardrop", artist: "Massive Attack", album: "Mezzanine", startedAt: at(today, 9, 26)),
            DemoRow(id: 2, title: "Blue Monday", artist: "New Order", album: "", startedAt: at(yesterday, 21, 18)),
            DemoRow(id: 1, title: "Tainted Love", artist: "Soft Cell", album: "", startedAt: at(yesterday, 19, 2)),
        ]
        let palette = [
            DemoColor(red: 0.78, green: 0.24, blue: 0.22),
            DemoColor(red: 0.20, green: 0.42, blue: 0.72),
            DemoColor(red: 0.82, green: 0.56, blue: 0.16),
            DemoColor(red: 0.22, green: 0.55, blue: 0.38),
            DemoColor(red: 0.46, green: 0.30, blue: 0.64),
            DemoColor(red: 0.20, green: 0.56, blue: 0.62),
        ]

        var artworks: [String: StoredArtwork] = [:]
        var hashes: [String: String] = [:]
        var listens: [Listen] = []
        for (index, row) in rows.enumerated() {
            let metadata = ListenMetadata(title: row.title, artist: row.artist, album: row.album)
            // One row deliberately has no cover so the shots cover both the
            // artwork path and the deterministic neutral sleeve.
            let artwork = row.title == "Blue Monday" ? nil : makeArtwork(palette[index % palette.count])
            if let artwork {
                artworks[artwork.hash] = artwork
                hashes[metadata.identity] = artwork.hash
            }
            listens.append(
                Listen(
                    id: row.id,
                    raw: metadata,
                    processed: metadata,
                    bundleID: "com.apple.Music",
                    duration: 225,
                    playedDuration: 225,
                    startedAt: row.startedAt,
                    capturedAt: row.startedAt.addingTimeInterval(225),
                    artworkHash: artwork?.hash,
                ),
            )
        }
        return DemoContent(listens: listens, artworks: artworks, hashes: hashes)
    }

    /// Solid sleeve art for the harness only. The real droplet shows whatever
    /// bytes the helper embeds; this gives the shots a distinguishable cover
    /// per demo row without shipping any image asset.
    static func makeArtwork(_ color: DemoColor) -> StoredArtwork? {
        let side = 400
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ) else {
            return nil
        }
        context.setFillColor(CGColor(red: color.red, green: color.green, blue: color.blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.18))
        context.fillEllipse(in: CGRect(x: -60, y: -60, width: 320, height: 320))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.16))
        context.fillEllipse(in: CGRect(x: 230, y: 220, width: 240, height: 240))

        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil,
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return ArtworkNormalizer.normalize(data as Data)
    }

    struct DemoRow {
        let id: Int64
        let title: String
        let artist: String
        let album: String
        let startedAt: Date
    }
}
