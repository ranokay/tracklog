import DroppyKit
import SwiftUI
import TracklogCore

// MARK: - Jump and refusal bars

/// The pinned notice above a jumped window. The top date is the loaded
/// window's newest row, not the requested instant, so walking newer updates
/// the copy without losing the request.
struct HistoryJumpBar: View {
    let notice: HistoryJumpNotice
    let topDate: Date?
    let hasNewer: Bool
    let onLoadNewer: () -> Void
    let onNewest: () -> Void

    @Environment(\.colorSchemeContrast) private var colorContrast

    var body: some View {
        HStack(spacing: DroppySpacing.md) {
            Image(systemName: "calendar.badge.clock")
                .font(.callout.weight(.semibold))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DroppySpacing.sm)
            if hasNewer {
                Button("Show newer listens", action: onLoadNewer)
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
            }
            Button("Newest", action: onNewest)
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
        }
        .padding(.horizontal, DroppySpacing.lg)
        .padding(.vertical, DroppySpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DroppyRadius.ms, style: .continuous)
                .fill(AdaptiveColors.overlayAuto(0.08)),
        )
        .overlay {
            if SurfaceContrast.isIncreased(colorContrast) {
                RoundedRectangle(cornerRadius: DroppyRadius.ms, style: .continuous)
                    .stroke(AdaptiveColors.contrastTintAuto.opacity(0.32), lineWidth: 1)
            }
        }
        .padding(.horizontal, DroppySpacing.xl)
        .padding(.bottom, DroppySpacing.xs)
    }

    private var text: String {
        switch notice.kind {
        case .positioned:
            let date = (topDate ?? notice.requestedAt)
                .formatted(date: .abbreviated, time: .shortened)
            return "Showing from \(date)"
        case .emptyDay:
            let day = notice.requestedAt.formatted(date: .long, time: .omitted)
            return "No listens on \(day). Showing the next listen."
        case .afterNewest:
            let date = notice.requestedAt.formatted(date: .abbreviated, time: .shortened)
            return "No listens after \(date). Showing the newest listens."
        }
    }
}

/// The host refused to open the History settings page. Say so here rather
/// than leaving the button looking broken; Settings itself is still reachable.
struct HistorySettingsUnavailableBar: View {
    @ObservedObject var state: TracklogAppState

    var body: some View {
        HStack(spacing: DroppySpacing.md) {
            Image(systemName: "gear.badge.xmark")
                .font(.callout.weight(.semibold))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text("Settings could not be opened here. Open Tracklog's History settings to choose a date.")
                .font(.callout)
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DroppySpacing.sm)
            Button("Dismiss") {
                state.setHistorySettingsUnavailable(false)
            }
            .buttonStyle(DroppyQuietButtonStyle(size: .small))
        }
        .padding(.horizontal, DroppySpacing.lg)
        .padding(.vertical, DroppySpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DroppyRadius.ms, style: .continuous)
                .fill(AdaptiveColors.overlayAuto(0.08)),
        )
        .padding(.horizontal, DroppySpacing.xl)
        .padding(.bottom, DroppySpacing.xs)
    }
}
