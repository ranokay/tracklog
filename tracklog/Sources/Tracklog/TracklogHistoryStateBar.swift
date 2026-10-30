import DroppyKit
import SwiftUI
import TracklogCore

// MARK: - Paused and off bar

/// The strip becomes a state bar whenever capture cannot show a track. The
/// text is one element and the action is its own button.
struct HistoryStateBar: View {
    let text: String
    let actionTitle: String
    let action: () -> Void
    @Environment(\.colorSchemeContrast) private var colorContrast

    var body: some View {
        HStack(spacing: DroppySpacing.md) {
            Text(text)
                .font(.body.weight(.medium))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .lineLimit(2)
                .accessibilityLabel(Text(text))
            Spacer(minLength: DroppySpacing.md)
            Button(actionTitle, action: action)
                .buttonStyle(DroppyAccentButtonStyle(size: .small))
        }
        .padding(.horizontal, DroppySpacing.xl)
        .frame(height: 76)
        .overlay(alignment: .top) {
            if SurfaceContrast.isIncreased(colorContrast) {
                SurfaceSeparator()
            }
        }
    }
}
