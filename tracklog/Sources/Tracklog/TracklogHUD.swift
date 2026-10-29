import AppKit
import DroppyKit
import SwiftUI
import TracklogCore

/// The production HUD host: builds Droppy's request from the host-neutral
/// presentation and forwards presentation and dismissal to the host service.
@MainActor
final class TracklogHUDHost: HUDHosting {
    private weak var droplet: TracklogDroplet?

    init(droplet: TracklogDroplet) {
        self.droplet = droplet
    }

    func present(_ presentation: HUDPresentation) -> Bool {
        droplet?.presentHUDPresentation(presentation) ?? false
    }

    func dismiss(id: String) {
        droplet?.dismissHUDPresentation(id: id)
    }
}

/// Posts the one accessibility announcement a presented HUD owes VoiceOver.
/// The notice belongs to the presentation event, not to a view builder: the
/// host may rebuild the content without speaking again.
@MainActor
enum TracklogAccessibilityAnnouncer {
    static func post(_ presentation: HUDPresentation) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: presentation.spoken,
                .priority: announcementPriority(presentation.priority).rawValue,
            ],
        )
    }

    private static func announcementPriority(
        _ priority: HUDPriority,
    ) -> NSAccessibilityPriorityLevel {
        switch priority {
        case .low: .low
        case .normal: .medium
        case .high: .high
        }
    }
}

/// A strip is the at-rest shape: glyph at the far left, word at the far right,
/// nothing in the middle where the camera housing sits.
struct TracklogHUDStrip: View {
    let presentation: HUDPresentation

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: presentation.glyph)
                .font(.system(size: DroppyLiveActivityMetrics.iconSize, weight: .semibold))
            Spacer(minLength: 0)
            Text(presentation.word)
                .font(.system(size: DroppyLiveActivityMetrics.labelFontSize, weight: .semibold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(presentation.spoken))
    }
}

/// A card carries the title, description and the action that dismisses it.
struct TracklogHUDCard: View {
    let presentation: HUDPresentation
    let onAction: (HUDAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xs) {
            HStack(alignment: .top, spacing: DroppySpacing.sm) {
                Image(systemName: presentation.glyph)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .frame(width: 20)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(presentation.title ?? "")
                        .font(.headline)
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                        .lineLimit(1)
                    if let detail = presentation.detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }

            if let action = presentation.action {
                HStack {
                    Spacer(minLength: 0)
                    Button(action.title) {
                        onAction(action)
                    }
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(presentation.spoken))
    }
}

extension TracklogDroplet: HUDPresenting {}

extension TracklogDroplet {
    /// Builds and presents the host request. The exact spoken string labels
    /// the request; the announcement itself is posted by `HUDHostSession` only
    /// after the host accepted this presentation.
    func presentHUDPresentation(_ presentation: HUDPresentation) -> Bool {
        guard let host else { return false }

        let request = if presentation.shape.isCard {
            DropletHUDRequest(
                id: presentation.id,
                duration: presentation.duration,
                priority: presentation.priority.droppy,
                accessibilityLabel: presentation.spoken,
                isExpanded: true,
                expandedContentHeight: 72,
            ) {
                TracklogHUDStrip(presentation: presentation)
            } expanded: { [weak self] in
                TracklogHUDCard(presentation: presentation) { action in
                    self?.performHUDAction(action, dismissing: presentation.id)
                }
            }
        } else {
            DropletHUDRequest(
                id: presentation.id,
                duration: presentation.duration,
                priority: presentation.priority.droppy,
                accessibilityLabel: presentation.spoken,
            ) {
                TracklogHUDStrip(presentation: presentation)
            }
        }
        return host.hud.present(request)
    }

    func dismissHUDPresentation(id: String) {
        host?.hud.dismiss(id: id)
    }

    private func performHUDAction(_ action: HUDAction, dismissing id: String) {
        host?.hud.dismiss(id: id)
        switch action.destination {
        case .services:
            openServicesPage()
        case .historyPending:
            presentHistory(expandingPending: true)
        }
    }
}

private extension HUDPriority {
    var droppy: DropletHUDPriority {
        switch self {
        case .low: .low
        case .normal: .normal
        case .high: .high
        }
    }
}
