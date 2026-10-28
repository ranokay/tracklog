import CoreGraphics
import Foundation
import ImageIO
import TracklogCore
import UniformTypeIdentifiers

/// The harness's deterministic listens and covers. Kept out of the store actor
/// so the demo data reads as one piece and the actor stays a store.
enum HarnessDemoData {
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

    /// Mixed delivery states for the History shot: delivered, rate limited,
    /// waiting, abandoned and no target at all.
    static func makeDeliveries() -> [Delivery] {
        let now = Date()
        func row(
            id: Int64,
            listenID: Int64,
            state: DeliveryState,
            attempts: Int = 0,
            lastAttemptAt: Date? = nil,
            nextAttemptAt: Date? = nil,
            lastError: String? = nil,
            abandonedReason: String? = nil,
            deliveredAt: Date? = nil,
        ) -> Delivery {
            Delivery(
                id: id,
                listenID: listenID,
                connectionID: 1,
                state: state,
                attempts: attempts,
                lastAttemptAt: lastAttemptAt,
                nextAttemptAt: nextAttemptAt,
                lastError: lastError,
                abandonedReason: abandonedReason,
                deliveredAt: deliveredAt,
                serviceReference: nil,
            )
        }
        return [
            row(id: 5, listenID: 6, state: .delivered, attempts: 1, lastAttemptAt: now - 600, deliveredAt: now - 600),
            row(
                id: 4,
                listenID: 5,
                state: .retrying,
                attempts: 3,
                lastAttemptAt: now - 120,
                nextAttemptAt: now + 240,
                lastError: "The service is rate limiting requests.",
            ),
            row(id: 3, listenID: 4, state: .waiting, nextAttemptAt: now),
            row(
                id: 2,
                listenID: 3,
                state: .abandoned,
                attempts: 1,
                lastAttemptAt: now - 3600,
                lastError: "The service rejected this listen.",
                abandonedReason: "The service rejected this listen.",
            ),
            row(id: 1, listenID: 2, state: .delivered, attempts: 1, lastAttemptAt: now - 86400, deliveredAt: now - 86400),
        ]
    }
}
