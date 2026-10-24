import DroppyKit
import SwiftUI

// Prototype-only scaffolding for the surface directions. Nothing here is
// meant to merge: the branch exists to compare three densities, then the
// winner is rebuilt properly.

enum ProtoVariant: String, CaseIterable {
    case ledger
    case sleeve
    case gutter

    var title: String {
        switch self {
        case .ledger: return "Ledger"
        case .sleeve: return "Sleeve"
        case .gutter: return "Gutter"
        }
    }
}

enum ProtoState: String {
    case playing
    case paused
    case off
    case idle
}

enum ProtoConfig {
    static var variant: ProtoVariant {
        guard let value = value(after: "--variant"),
              let variant = ProtoVariant(rawValue: value)
        else { return .ledger }
        return variant
    }

    static var state: ProtoState {
        guard let value = value(after: "--state"),
              let state = ProtoState(rawValue: value)
        else { return .playing }
        return state
    }

    private static func value(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let next = arguments.index(after: index)
        guard next < arguments.endIndex else { return nil }
        return arguments[next]
    }
}

// MARK: - Mock data

enum ProtoDelivery {
    case delivered
    case waiting
    case failed
}

struct ProtoTrack {
    let title: String
    let artist: String
    let album: String
    let elapsed: String
    let remaining: String
    let progress: Double
    let hue: Double
}

struct ProtoListen: Identifiable {
    let id: Int
    let title: String
    let artist: String
    let album: String
    let time: String
    let delivery: ProtoDelivery
    let hue: Double
}

struct ProtoDay: Identifiable {
    let id: String
    let title: String
    let listens: [ProtoListen]
}

enum ProtoData {
    static let nowPlaying = ProtoTrack(
        title: "Weird Fishes / Arpeggi",
        artist: "Radiohead",
        album: "In Rainbows",
        elapsed: "3:42",
        remaining: "0:22",
        progress: 0.70,
        hue: 0.60
    )

    static let pendingCount = 3

    static let days: [ProtoDay] = [
        ProtoDay(id: "today", title: "Today", listens: [
            ProtoListen(id: 1, title: "15 Step", artist: "Radiohead", album: "In Rainbows", time: "14:32", delivery: .delivered, hue: 0.60),
            ProtoListen(id: 2, title: "Bodysnatchers", artist: "Radiohead", album: "In Rainbows", time: "14:28", delivery: .delivered, hue: 0.60),
            ProtoListen(id: 3, title: "Nude", artist: "Radiohead", album: "In Rainbows", time: "14:23", delivery: .waiting, hue: 0.60),
            ProtoListen(id: 4, title: "All I Need", artist: "Radiohead", album: "In Rainbows", time: "14:18", delivery: .delivered, hue: 0.60),
            ProtoListen(id: 5, title: "Faust Arp", artist: "Radiohead", album: "In Rainbows", time: "14:14", delivery: .delivered, hue: 0.60),
            ProtoListen(id: 6, title: "Reckoner", artist: "Radiohead", album: "In Rainbows", time: "14:08", delivery: .failed, hue: 0.60),
            ProtoListen(id: 7, title: "House of Cards", artist: "Radiohead", album: "In Rainbows", time: "14:03", delivery: .delivered, hue: 0.60),
            ProtoListen(id: 8, title: "Jigsaw Falling into Place", artist: "Radiohead", album: "In Rainbows", time: "13:57", delivery: .waiting, hue: 0.60),
        ]),
        ProtoDay(id: "yesterday", title: "Yesterday", listens: [
            ProtoListen(id: 9, title: "Teardrop", artist: "Massive Attack", album: "Mezzanine", time: "22:41", delivery: .delivered, hue: 0.72),
            ProtoListen(id: 10, title: "Angel", artist: "Massive Attack", album: "Mezzanine", time: "22:35", delivery: .delivered, hue: 0.72),
            ProtoListen(id: 11, title: "Windowlicker", artist: "Aphex Twin", album: "Windowlicker", time: "22:28", delivery: .waiting, hue: 0.83),
            ProtoListen(id: 12, title: "A New Error", artist: "Moderat", album: "Moderat", time: "22:21", delivery: .delivered, hue: 0.45),
            ProtoListen(id: 13, title: "The Rat", artist: "The Walkmen", album: "Bows + Arrows", time: "22:16", delivery: .delivered, hue: 0.08),
            ProtoListen(id: 14, title: "Nightcall", artist: "Kavinsky", album: "OutRun", time: "22:10", delivery: .delivered, hue: 0.90),
        ]),
        ProtoDay(id: "thursday", title: "Thursday", listens: [
            ProtoListen(id: 15, title: "Stolen Dog", artist: "Burial", album: "Street Halo", time: "18:04", delivery: .delivered, hue: 0.55),
            ProtoListen(id: 16, title: "Archangel", artist: "Burial", album: "Untrue", time: "17:58", delivery: .delivered, hue: 0.55),
            ProtoListen(id: 17, title: "Motion Picture Soundtrack", artist: "Radiohead", album: "Kid A", time: "17:52", delivery: .failed, hue: 0.66),
            ProtoListen(id: 18, title: "Everything in Its Right Place", artist: "Radiohead", album: "Kid A", time: "17:47", delivery: .delivered, hue: 0.66),
            ProtoListen(id: 19, title: "Idioteque", artist: "Radiohead", album: "Kid A", time: "17:42", delivery: .delivered, hue: 0.66),
        ]),
    ]

    static let listenCount = days.reduce(0) { $0 + $1.listens.count }

    static let playing = ProtoState.playing
}

// MARK: - Shared pieces

struct ProtoArtwork: View {
    let hue: Double
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: max(4, size * 0.12), style: .continuous)
            .fill(Color(hue: hue, saturation: 0.30, brightness: 0.34))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.28, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
            }
            .accessibilityHidden(true)
    }
}

struct ProtoDeliveryMark: View {
    let state: ProtoDelivery

    var body: some View {
        Group {
            switch state {
            case .delivered:
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            case .waiting:
                Image(systemName: "clock")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.orange.opacity(0.9))
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.red.opacity(0.9))
            }
        }
        .frame(width: 12, height: 12)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch state {
        case .delivered: return "Delivered"
        case .waiting: return "Waiting to deliver"
        case .failed: return "Delivery failed"
        }
    }
}

struct ProtoProgress: View {
    let value: Double
    var height: CGFloat = 2

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(AdaptiveColors.notchSurfaceCardFill)
                Capsule(style: .continuous)
                    .fill(AdaptiveColors.notchSurfacePrimaryText.opacity(0.55))
                    .frame(width: max(0, proxy.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct ProtoQueueBadge: View {
    var count: Int = ProtoData.pendingCount
    var compact = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "clock")
                .font(.system(size: 8, weight: .semibold))
            Text(compact ? "\(count)" : "\(count) waiting")
                .font(.system(size: 9, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(Color.orange.opacity(0.95))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule(style: .continuous).fill(AdaptiveColors.notchSurfaceCardFill))
        .accessibilityLabel("\(count) listens waiting")
    }
}

struct ProtoLoveButton: View {
    let size: CGFloat
    @State private var loved = false

    var body: some View {
        Button {
            loved.toggle()
        } label: {
            Image(systemName: loved ? "heart.fill" : "heart")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(loved ? AdaptiveColors.notchSurfacePrimaryText : AdaptiveColors.notchSurfaceSecondaryText)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(DroppyCircleButtonStyle(size: size))
        .help(loved ? "Unlove" : "Love")
        .accessibilityLabel(loved ? "Unlove" : "Love")
    }
}

struct ProtoOverflowMenu: View {
    let size: CGFloat

    var body: some View {
        Menu {
            Button("Edit track…") {}
            Button("Block track") {}
            Divider()
            Button("Tracklog settings…") {}
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                .frame(width: size, height: size)
                .background(Circle().fill(AdaptiveColors.notchSurfaceCardFill))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More")
    }
}

struct ProtoOffBar: View {
    var body: some View {
        HStack(spacing: DroppySpacing.sm) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            VStack(alignment: .leading, spacing: 1) {
                Text("Scrobbling is off")
                    .font(.system(size: 12, weight: .semibold))
                Text("Your listening isn't being saved.")
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            }
            Spacer(minLength: DroppySpacing.sm)
            Button("Turn on") {}
                .buttonStyle(DroppyAccentButtonStyle(size: .small))
        }
        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        .padding(.horizontal, DroppySpacing.smd)
        .padding(.vertical, DroppySpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DroppyRadius.medium, style: .continuous)
                .fill(AdaptiveColors.notchSurfaceCardFill)
        )
    }
}
