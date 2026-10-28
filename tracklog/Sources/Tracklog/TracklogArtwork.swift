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
                NeutralSleeveView(identity: identity, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: DroppyRadius.ms, style: .continuous))
        .accessibilityHidden(true)
        .onAppear { decode() }
        .onChange(of: artwork) { _, _ in decode() }
    }

    private func decode() {
        image = artwork.flatMap(NSImage.init(data:))
    }
}

private struct NeutralSleeveView: View {
    let identity: String
    let size: CGFloat

    var body: some View {
        let style = NeutralSleeve.style(for: identity)
        RoundedRectangle(cornerRadius: DroppyRadius.ms, style: .continuous)
            .fill(AdaptiveColors.notchSurfaceCardFill)
            .overlay {
                RoundedRectangle(cornerRadius: DroppyRadius.ms, style: .continuous)
                    .fill(AdaptiveColors.notchSurfacePrimaryText.opacity(style.fillOpacity))
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
