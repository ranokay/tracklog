// swiftlint:disable file_length type_body_length
import DroppyKit
import SwiftUI
import TracklogCore

/// The accepted Context rail: source, period and supported totals stay in a
/// persistent left rail; the ranked list takes the remaining width.
struct TracklogChartsView: View {
    let droplet: TracklogDroplet
    @ObservedObject var state: TracklogAppState

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            rail
                .frame(width: 218)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await droplet.showCharts() }
        .onDisappear { droplet.hideCharts() }
    }

    // MARK: - Rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            Text("Charts")
                .font(.system(.title, design: .rounded, weight: .semibold))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .accessibilityAddTraits(.isHeader)

            sourcePicker
            periodPicker
            sourceNote

            Spacer(minLength: DroppySpacing.sm)

            totals
        }
        .padding(.leading, DroppySpacing.xl)
        .padding(.trailing, DroppySpacing.md)
        .padding(.top, 2)
        .padding(.bottom, DroppySpacing.sm)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xs) {
            ChartChoiceButton(
                title: "Service",
                isSelected: !isLocalDisplayed,
                fillsWidth: true,
                isEnabled: !serviceUnsupported,
                action: { Task { await droplet.selectChartSource(.service) } },
            )
            .help(serviceUnsupported ? "\(unsupportedServiceName) has no charts API. Charts use this Mac's history." : "")
            ChartChoiceButton(
                title: "On this Mac",
                isSelected: isLocalDisplayed,
                fillsWidth: true,
                action: { Task { await droplet.selectChartSource(.local) } },
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Chart source"))
    }

    private var periodPicker: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xs) {
            ForEach(visiblePeriods, id: \.rawValue) { period in
                ChartChoiceButton(
                    title: period.displayName,
                    isSelected: state.chartState.selection.period == period,
                    fillsWidth: true,
                    action: {
                        if period == .custom {
                            droplet.openChartsSettingsPage()
                        } else {
                            Task { await droplet.selectChartPeriod(period) }
                        }
                    },
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Period"))
    }

    private var sourceNote: some View {
        Text(sourceNoteText)
            .font(.caption)
            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(Text(sourceNoteText))
    }

    @ViewBuilder
    private var totals: some View {
        switch state.chartState.totals {
        case .none:
            EmptyView()
        case .loading:
            Text("Loading total…")
                .font(.caption)
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
        case let .local(count):
            totalValue(count, caption: "local listens")
        case let .account(total):
            totalValue(
                total.value,
                caption: "\(total.serviceName) · account total",
                savedAt: total.savedAt,
            )
        case let .unavailable(reason):
            unavailableTotal(reason)
        }
    }

    private func totalValue(_ count: Int, caption: String, savedAt: Date? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(count.formatted())
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption)
                .font(.caption)
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let savedAt {
                Text("Saved \(relativeAge(savedAt))")
                    .font(.caption2)
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(totalAccessibilityLabel(count: count, caption: caption, savedAt: savedAt)))
    }

    private func totalAccessibilityLabel(count: Int, caption: String, savedAt: Date?) -> String {
        ChartCopy.totalLabel(
            count: count,
            caption: caption,
            savedAt: savedAt,
            age: savedAt.map(relativeAge) ?? "",
        )
    }

    private func unavailableTotal(_ reason: ChartTotalsUnavailable) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            switch reason {
            case .rangeTotals:
                Text("Range totals unavailable")
            case let .accountTotal(failure):
                Text("Account total unavailable")
                Text(totalFailureDetail(failure))
                    .font(.caption2)
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            }
        }
        .font(.caption)
        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private func totalFailureDetail(_ failure: ChartFailure) -> String {
        switch failure {
        case .offline: "Could not reach the service."
        case .needsSignIn: "Sign in again to refresh it."
        case .appCredentials: "Last.fm app credentials are needed."
        case .rateLimited: "The service is rate limiting requests."
        case .notReady: "The service is still calculating statistics."
        case .service, .localRead, .invalidRange: "Try again later."
        }
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            contentHeader
            if let notice {
                ChartNoticeView(notice: notice, droplet: droplet)
                    .padding(.horizontal, DroppySpacing.xl)
                    .padding(.bottom, DroppySpacing.xs)
            }
            bodyContent
        }
        .padding(.leading, DroppySpacing.sm)
        .padding(.trailing, DroppySpacing.xl)
        .padding(.bottom, DroppySpacing.sm)
    }

    private var contentHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: DroppySpacing.sm) {
                HStack(spacing: DroppySpacing.xs) {
                    ForEach(ChartType.allCases) { type in
                        ChartChoiceButton(
                            title: type.displayName,
                            isSelected: state.chartState.selection.type == type,
                            action: { Task { await droplet.selectChartType(type) } },
                        )
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text("Chart type"))
                Spacer(minLength: DroppySpacing.md)
                Text(savedAgeText)
                    .font(.caption)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .monospacedDigit()
                    .lineLimit(1)
                refreshButton
            }
            .padding(.top, 2)

            Text(listTitle)
                .font(.headline)
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .lineLimit(1)
                .padding(.top, DroppySpacing.xs)
                .accessibilityAddTraits(.isHeader)

            if let detail = state.chartState.periodDetail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            }
            if let returned = state.chartState.snapshot?.returnedRange {
                Text(returnedRangeText(returned))
                    .font(.caption)
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let omission = omissionText {
                Text(omission)
                    .font(.caption)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, DroppySpacing.xs)
    }

    private var refreshButton: some View {
        Button {
            Task { await droplet.refreshCharts() }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(DroppyCircleButtonStyle(size: 24))
        .disabled(state.chartState.isRefreshing)
        .help("Refresh charts")
        .accessibilityLabel(Text("Refresh charts"))
        .accessibilityValue(Text(savedAgeText))
        .accessibilityHint(Text("Reloads the chart source, type and period shown."))
    }

    @ViewBuilder
    private var bodyContent: some View {
        switch state.chartState.phase {
        case .ready:
            rankedList
        case .empty:
            emptyState
        case let .noMetadata(omitted):
            noMetadataState(omitted: omitted)
        case .idle, .loading:
            loadingState
        case .noConnection:
            noConnectionState
        case .notReady:
            notReadyState
        case let .failed(failure):
            failedState(failure)
        }
    }

    private var rankedList: some View {
        let items = state.chartState.snapshot?.items ?? []
        let unit = state.chartState.snapshot?.countUnit ?? .listens
        return ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    ChartRankRow(
                        item: item,
                        type: state.chartState.selection.type,
                        unit: unit,
                        artwork: item.artworkHash.flatMap { state.artworkByHash[$0] },
                        sourceLabel: sourceLabel,
                        periodLabel: periodLabel,
                    )
                }
                Text(ChartCopy.shownCount(items.count, type: state.chartState.selection.type))
                    .font(.caption2)
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DroppySpacing.sm)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingState: some View {
        ChartEmptyPanel(
            title: "Loading top \(state.chartState.selection.type.displayName.lowercased())…",
            message: "Reading \(sourceLabel). Your listening keeps recording.",
            symbol: "waveform",
        ) {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(Text("Loading charts"))
        }
    }

    private var emptyState: some View {
        ChartEmptyPanel(
            title: "No listens in this range",
            message: emptyMessage,
            symbol: "music.note.list",
        ) {
            Button("Show all time") {
                Task { await droplet.selectChartPeriod(.allTime) }
            }
            .buttonStyle(DroppyQuietButtonStyle(size: .small))
            if !isLocalDisplayed, state.currentConnection != nil {
                Button("Use local history") {
                    Task { await droplet.selectChartSource(.local) }
                }
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
            }
        }
    }

    private func noMetadataState(omitted: Int) -> some View {
        ChartEmptyPanel(
            title: missingMetadataTitle,
            message: "\(omitted.formatted()) \(omitted == 1 ? "listen is" : "listens are") "
                + "still included in the range total, but this list needs \(missingMetadataField).",
            symbol: "questionmark.folder",
        ) {
            Button("Show all time") {
                Task { await droplet.selectChartPeriod(.allTime) }
            }
            .buttonStyle(DroppyQuietButtonStyle(size: .small))
        }
    }

    private var noConnectionState: some View {
        ChartEmptyPanel(
            title: "No connection selected",
            message: "Connect a service to see its charts, or browse listens recorded on this Mac.",
            symbol: "link.badge.plus",
        ) {
            Button("Use local history") {
                Task { await droplet.selectChartSource(.local) }
            }
            .buttonStyle(DroppyAccentButtonStyle(size: .small))
            Button("Open Services settings") {
                droplet.openServicesPage()
            }
            .buttonStyle(DroppyQuietButtonStyle(size: .small))
        }
    }

    private var notReadyState: some View {
        ChartEmptyPanel(
            title: "Statistics are not ready",
            message: "\(sourceLabel) has not finished calculating this period. Try again when the statistics are ready.",
            symbol: "clock.badge.exclamationmark",
        ) {
            Button("Try again") {
                Task { await droplet.refreshCharts() }
            }
            .buttonStyle(DroppyAccentButtonStyle(size: .small))
            if !isLocalDisplayed {
                Button("Use local history") {
                    Task { await droplet.selectChartSource(.local) }
                }
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
            }
        }
    }

    private func failedState(_ failure: ChartFailure) -> some View {
        ChartEmptyPanel(
            title: "Charts could not be loaded",
            message: failureDescription(failure),
            symbol: "exclamationmark.triangle",
        ) {
            Button("Try again") {
                Task { await droplet.refreshCharts() }
            }
            .buttonStyle(DroppyAccentButtonStyle(size: .small))
            if failureOffersSettings(failure) {
                Button("Open Services settings") {
                    droplet.openServicesPage()
                }
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
            }
            if !isLocalDisplayed {
                Button("Use local history") {
                    Task { await droplet.selectChartSource(.local) }
                }
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
            }
        }
    }

    // MARK: - Notice

    private var notice: ChartNotice? {
        guard state.chartState.snapshot != nil else { return nil }
        if let failure = state.chartState.refreshFailure {
            let title: String = switch failure {
            case .offline:
                isLocalDisplayed ? "Could not refresh · showing saved charts" : "Offline · showing saved charts"
            case .needsSignIn:
                "Sign in again · showing saved charts"
            case .appCredentials:
                "Last.fm app credentials needed · showing saved charts"
            case .rateLimited:
                "Rate limited · showing saved charts"
            case .notReady:
                "Statistics not ready · showing saved charts"
            case .localRead:
                "Could not refresh · showing saved charts"
            case .service, .invalidRange:
                "Could not refresh · showing saved charts"
            }
            return ChartNotice(
                title: title,
                detail: "\(savedAgeText) · \(sourceLabel), \(periodLabel), \(state.chartState.selection.type.displayName.lowercased())",
                showsRetry: true,
                showsSettings: failureOffersSettings(failure),
            )
        }
        if state.chartState.isRefreshing {
            return ChartNotice(
                title: "Refreshing charts · saved results stay visible",
                detail: savedAgeText,
                showsRetry: false,
                showsSettings: false,
            )
        }
        return nil
    }

    // MARK: - Derived

    private var isLocalDisplayed: Bool {
        switch state.chartState.effectiveSource {
        case .local:
            true
        case .service:
            false
        case .none:
            state.chartState.selection.source == .local
        }
    }

    private var serviceUnsupported: Bool {
        state.currentConnection?.kind == .libreFM
    }

    private var unsupportedServiceName: String {
        state.currentConnection?.kind.displayName ?? "This service"
    }

    private var visiblePeriods: [ChartPeriod] {
        isLocalDisplayed || state.chartState.selection.source == .local
            ? ChartPeriod.allCases
            : [.week, .month, .year, .allTime]
    }

    private var sourceNoteText: String {
        switch state.chartState.effectiveSource {
        case let .service(_, kind, _, _, displayName):
            return "\(kind.displayName) · \(displayName)"
        case let .local(reason):
            switch reason {
            case .selected:
                if state.currentConnection?.kind == .libreFM {
                    return "On this Mac · Libre.fm has no charts API"
                }
                return "On this Mac · Local history only"
            case let .unsupported(kind):
                return "\(kind.displayName) has no charts API. Showing this Mac's history."
            }
        case .none:
            return "No connection selected"
        }
    }

    private var sourceLabel: String {
        switch state.chartState.effectiveSource {
        case let .service(_, kind, _, _, displayName):
            "\(kind.displayName) · \(displayName)"
        case .local:
            "On this Mac"
        case .none:
            "No connection"
        }
    }

    private var periodLabel: String {
        ChartCopy.periodLabel(state.chartState, calendar: ChartCalendar.current)
    }

    private var listTitle: String {
        ChartCopy.listTitle(type: state.chartState.selection.type, period: periodLabel)
    }

    private var savedAgeText: String {
        if let savedAt = state.chartState.snapshot?.savedAt {
            return "Saved \(relativeAge(savedAt))"
        }
        switch state.chartState.phase {
        case .loading, .idle:
            return "First load"
        default:
            return "No saved charts"
        }
    }

    private func relativeAge(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 {
            return "just now"
        }
        if seconds < 3600 {
            return "\(Int(seconds / 60)) min ago"
        }
        if seconds < 86_400 {
            return "\(Int(seconds / 3600)) hr ago"
        }
        return "\(Int(seconds / 86_400)) d ago"
    }

    private var omissionText: String? {
        guard state.chartState.phase == .ready,
              let omitted = state.chartState.snapshot?.omittedCount,
              omitted > 0
        else { return nil }
        return "\(omitted.formatted()) \(omitted == 1 ? "listen is" : "listens are") not in this list for missing \(missingMetadataField)."
    }

    private var missingMetadataField: String {
        switch state.chartState.selection.type {
        case .artists: "artist names"
        case .albums: "album details"
        case .tracks: "track or artist names"
        }
    }

    private var missingMetadataTitle: String {
        switch state.chartState.selection.type {
        case .artists: "No artist details in this range"
        case .albums: "No album details in this range"
        case .tracks: "No track or artist details in this range"
        }
    }

    private var emptyMessage: String {
        if isLocalDisplayed {
            return "Play something on this Mac, or try another period."
        }
        return "Try another period, or browse this Mac's local history."
    }

    private func returnedRangeText(_ range: ChartReturnedRange) -> String {
        let start = range.start.formatted(date: .abbreviated, time: .omitted)
        let end = range.end.formatted(date: .abbreviated, time: .omitted)
        guard let updated = range.lastUpdated else {
            return "Returned span \(start) – \(end)"
        }
        return "Returned span \(start) – \(end) · statistics updated \(updated.formatted(date: .abbreviated, time: .shortened))"
    }

    private func failureDescription(_ failure: ChartFailure) -> String {
        switch failure {
        case .offline:
            if isLocalDisplayed {
                return "This Mac's history could not be read. Try again."
            }
            return "Tracklog could not reach \(sourceLabel). Check your connection and try again."
        case .needsSignIn:
            return "The saved sign-in for \(sourceLabel) was rejected. Sign in again in Settings; saved charts stay visible."
        case .appCredentials:
            return "Last.fm needs application credentials in Settings before it can return charts."
        case .rateLimited:
            return "\(sourceLabel) is rate limiting requests. Try again shortly."
        case let .service(message):
            return message ?? "The service rejected the chart request."
        case .localRead:
            return "This Mac's history could not be read. Try again."
        case .invalidRange:
            return "That date range is not valid. Save a new Custom range in Settings."
        case .notReady:
            return "\(sourceLabel) has not finished calculating this period. Try again later."
        }
    }

    private func failureOffersSettings(_ failure: ChartFailure) -> Bool {
        switch failure {
        case .needsSignIn, .appCredentials: true
        default: false
        }
    }
}

// MARK: - Choices

struct ChartChoiceButton: View {
    let title: String
    let isSelected: Bool
    var fillsWidth = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Group {
            if isSelected {
                Button(action: action) { label }
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
                    .accessibilityAddTraits(.isSelected)
            } else {
                Button(action: action) { label }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
            }
        }
        .disabled(!isEnabled)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(isSelected ? "Selected" : "Not selected"))
    }

    private var label: some View {
        HStack(spacing: DroppySpacing.xs) {
            Text(title)
                .lineLimit(1)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
    }
}

// MARK: - Rows

struct ChartRankRow: View {
    let item: ChartItem
    let type: ChartType
    let unit: ChartCountUnit
    let artwork: Data?
    let sourceLabel: String
    let periodLabel: String
    @Environment(\.colorSchemeContrast) private var colorContrast

    var body: some View {
        HStack(spacing: DroppySpacing.md) {
            Text("\(item.rank)")
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                .frame(width: 22, alignment: .trailing)
                .accessibilityHidden(true)
            ArtworkSleeve(
                size: 52,
                artwork: artwork,
                identity: item.identityKey,
                isCircular: type == .artists,
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: DroppySpacing.sm)
            VStack(alignment: .trailing, spacing: 1) {
                Text(item.count.formatted())
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .monospacedDigit()
                    .lineLimit(1)
                Text(ChartCopy.countUnit(item.count, unit))
                    .font(.caption2)
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            }
            .accessibilityHidden(true)
        }
        .padding(.horizontal, DroppySpacing.lg)
        .frame(height: 68)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityValue(Text(ChartCopy.rowAccessibilityValue(source: sourceLabel, period: periodLabel)))
        .overlay(alignment: .bottom) {
            if SurfaceContrast.isIncreased(colorContrast) {
                SurfaceSeparator()
                    .padding(.horizontal, DroppySpacing.lg)
            }
        }
    }

    private var accessibilityLabel: String {
        ChartCopy.rowAccessibilityLabel(
            rank: item.rank,
            title: item.title,
            subtitle: item.subtitle,
            count: item.count,
            unit: unit,
        )
    }
}

// MARK: - State panel

struct ChartEmptyPanel<Actions: View>: View {
    let title: String
    let message: String
    let symbol: String
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: DroppySpacing.sm) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            Text(message)
                .font(.body)
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
            HStack(spacing: DroppySpacing.sm) {
                actions
            }
            .padding(.top, DroppySpacing.xs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DroppySpacing.lg)
    }
}

// MARK: - Notice

struct ChartNotice {
    let title: String
    let detail: String
    let showsRetry: Bool
    let showsSettings: Bool
}

struct ChartNoticeView: View {
    let notice: ChartNotice
    let droplet: TracklogDroplet

    var body: some View {
        HStack(alignment: .center, spacing: DroppySpacing.sm) {
            Image(systemName: "exclamationmark.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(notice.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                Text(notice.detail)
                    .font(.caption2)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: DroppySpacing.sm)
            if notice.showsSettings {
                Button("Settings") {
                    droplet.openServicesPage()
                }
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
            }
            if notice.showsRetry {
                Button("Try again") {
                    Task { await droplet.refreshCharts() }
                }
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
            }
        }
        .padding(.horizontal, DroppySpacing.md)
        .padding(.vertical, DroppySpacing.xs)
        .background(
            RoundedRectangle(cornerRadius: DroppyRadius.sm, style: .continuous)
                .fill(AdaptiveColors.notchSurfaceCardFill.opacity(0.7)),
        )
        .accessibilityElement(children: .contain)
    }
}

// swiftlint:enable file_length type_body_length
