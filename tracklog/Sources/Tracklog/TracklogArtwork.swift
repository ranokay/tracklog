import AppKit
import DroppyKit
import SwiftUI
import TracklogCore

/// One album cover, or the deterministic neutral sleeve when no cover is
/// known. Artwork is decorative; the row and widget text already carries the
/// track, so VoiceOver skips the image.
struct ArtworkSleeve: View {
    let size: CGFloat
    let artwork: Data?
    let identity: String
    var isCircular = false

    /// Decoded once per cover rather than on every two-second state change.
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                NeutralSleeveView(identity: identity, size: size, isCircular: isCircular)
            }
        }
        .frame(width: size, height: size)
        .clipShape(clipShape)
        .accessibilityHidden(true)
        .onAppear { decode() }
        .onChange(of: artwork) { _, _ in decode() }
    }

    private var clipShape: AnyShape {
        isCircular
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: DroppyRadius.ms, style: .continuous))
    }

    private func decode() {
        image = artwork.flatMap(NSImage.init(data:))
    }
}

private struct NeutralSleeveView: View {
    let identity: String
    let size: CGFloat
    var isCircular = false

    var body: some View {
        let style = NeutralSleeve.style(for: identity)
        Group {
            if isCircular {
                Circle().fill(AdaptiveColors.notchSurfaceCardFill)
            } else {
                RoundedRectangle(cornerRadius: DroppyRadius.ms, style: .continuous)
                    .fill(AdaptiveColors.notchSurfaceCardFill)
            }
        }
        .overlay {
            Group {
                if isCircular {
                    Circle().fill(AdaptiveColors.notchSurfacePrimaryText.opacity(style.fillOpacity))
                } else {
                    RoundedRectangle(cornerRadius: DroppyRadius.ms, style: .continuous)
                        .fill(AdaptiveColors.notchSurfacePrimaryText.opacity(style.fillOpacity))
                }
            }
        }
        .overlay {
            Image(systemName: style.glyph)
                .font(.system(size: size * 0.32, weight: .medium))
                .foregroundStyle(
                    AdaptiveColors.notchSurfaceTertiaryText.opacity(style.glyphOpacity),
                )
        }
    }
}
