import Foundation

/// The one local track identity shared by the Tracks chart and track history.
/// It is the normalized processed title and artist, joined the same way as
/// every other identity in the engine. It is deliberately not the stored raw
/// `track_identity` (which includes album and album artist and keeps raw
/// spellings) and not the feedback identity (which includes album and album
/// artist).
public enum LocalTrackIdentity {
    /// One track: normalized title and artist. A blank artist still has a
    /// title-only key, so a stored row with no artist can open its own history.
    public static func key(title: String, artist: String) -> String? {
        guard !Identity.normalized(title).isEmpty else { return nil }
        return Identity.joined([title, artist])
    }

    /// The Tracks chart's stricter form: the chart omits rows missing either
    /// field, so its key is nil for them. Every chart key is exactly
    /// ``key(title:artist:)`` for a complete row.
    public static func chartKey(title: String, artist: String) -> String? {
        guard !Identity.normalized(artist).isEmpty else { return nil }
        return key(title: title, artist: artist)
    }
}

/// The one local grouping rule. SQLite streams rows into it; the harness
/// feeds its in-memory listens through the same accumulator so the demo cannot
/// disagree with production.
public struct LocalChartAggregator {
    public let type: ChartType
    private var groups: [String: LocalGroup] = [:]
    private var total = 0
    private var rowIndex = 0

    public init(type: ChartType) {
        self.type = type
    }

    public mutating func add(
        title: String,
        artist: String,
        album: String,
        albumArtist: String,
        artworkHash: String?,
    ) {
        total += 1
        defer { rowIndex += 1 }
        guard let grouped = Self.groupedFields(
            type: type,
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
        ) else { return }

        var group = groups[grouped.key] ?? LocalGroup()
        group.count += 1
        group.title.add(grouped.title, firstIndex: rowIndex)
        if !grouped.subtitle.isEmpty {
            group.subtitle.add(grouped.subtitle, firstIndex: rowIndex)
        }
        if group.artworkHash == nil {
            group.artworkHash = artworkHash
        }
        groups[grouped.key] = group
    }

    public func finish(limit: Int) -> LocalChartAggregate {
        let sorted = groups.sorted { lhs, rhs in
            if lhs.value.count != rhs.value.count {
                return lhs.value.count > rhs.value.count
            }
            return lhs.key < rhs.key
        }
        let included = sorted.reduce(0) { $0 + $1.value.count }
        let items = sorted.prefix(max(0, limit)).enumerated().map { offset, entry in
            ChartItem(
                rank: offset + 1,
                title: entry.value.title.representative,
                subtitle: entry.value.subtitle.representative,
                count: entry.value.count,
                identityKey: entry.key,
                artworkHash: entry.value.artworkHash,
            )
        }
        return LocalChartAggregate(
            items: items,
            total: total,
            omittedCount: max(0, total - included),
        )
    }

    private static func groupedFields(
        type: ChartType,
        title: String,
        artist: String,
        album: String,
        albumArtist: String,
    ) -> GroupedFields? {
        let artistKey = Identity.normalized(artist)
        let albumKey = Identity.normalized(album)
        switch type {
        case .artists:
            guard !artistKey.isEmpty else { return nil }
            return GroupedFields(
                key: artistKey,
                title: artist.trimmingCharacters(in: .whitespacesAndNewlines),
                subtitle: "",
            )
        case .albums:
            guard !albumKey.isEmpty else { return nil }
            let subtitleKey = albumArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? artist.trimmingCharacters(in: .whitespacesAndNewlines)
                : albumArtist.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !subtitleKey.isEmpty else { return nil }
            return GroupedFields(
                key: Identity.joined([album, subtitleKey]),
                title: album.trimmingCharacters(in: .whitespacesAndNewlines),
                subtitle: subtitleKey,
            )
        case .tracks:
            guard let key = LocalTrackIdentity.chartKey(title: title, artist: artist) else { return nil }
            return GroupedFields(
                key: key,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                subtitle: artist.trimmingCharacters(in: .whitespacesAndNewlines),
            )
        }
    }
}

private struct GroupedFields {
    let key: String
    let title: String
    let subtitle: String
}

private struct LocalGroup {
    var count = 0
    var title = LocalSpellingTally()
    var subtitle = LocalSpellingTally()
    var artworkHash: String?
}

/// Most frequent exact spelling, then the earliest first appearance.
private struct LocalSpellingTally {
    private var counts: [String: Int] = [:]
    private var firstIndex: [String: Int] = [:]

    mutating func add(_ spelling: String, firstIndex index: Int) {
        counts[spelling, default: 0] += 1
        if firstIndex[spelling] == nil {
            firstIndex[spelling] = index
        }
    }

    var representative: String {
        counts.max { lhs, rhs in
            if lhs.value != rhs.value {
                return lhs.value < rhs.value
            }
            return (firstIndex[lhs.key] ?? .max) > (firstIndex[rhs.key] ?? .max)
        }?.key ?? ""
    }
}
