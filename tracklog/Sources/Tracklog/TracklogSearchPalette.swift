// swiftlint:disable file_length type_body_length
import DroppyKit
import SwiftUI
import TracklogCore

/// The transient palette state the panel keeps across a refused Settings
/// handoff: the typed query, selection, collapsed and expanded groups, and the
/// one inline notice. It is never persisted.
@MainActor
final class SearchPaletteModel: ObservableObject {
    @Published var query = ""
    @Published var notice: String?
    @Published var selectedID: String?
    @Published var collapsed: Set<CatalogueGroupKind> = []
    @Published var expanded: Set<CatalogueGroupKind> = []

    var onMove: ((Int) -> Void)?
    var onActivate: (() -> Void)?
    var onOptionActivate: (() -> Void)?
    var onCommandActivate: (() -> Void)?
    var onEscape: (() -> Void)?
}

/// One keyboard-addressable item: every group header, every visible result,
/// and a Show-more row. The field keeps focus; arrows move this selection.
enum SearchPaletteItem: Equatable {
    case group(CatalogueGroupKind)
    case row(CatalogueRow)
    case showMore(CatalogueGroupKind)

    var id: String {
        switch self {
        case let .group(kind): "group:\(kind.rawValue)"
        case let .row(row): "row:\(row.id)"
        case let .showMore(kind): "more:\(kind.rawValue)"
        }
    }
}

struct TracklogSearchPalette: View {
    let droplet: TracklogDroplet
    @ObservedObject var state: TracklogAppState
    @ObservedObject var model: SearchPaletteModel
    let announce: (String) -> Void
    let close: () -> Void

    @FocusState private var fieldFocused: Bool
    @State private var wasSearching = false
    @State private var userMovedSelection = false
    @State private var hasAnnouncedAutomaticSelection = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchBar
            if let notice = model.notice {
                noticeBar(notice)
                    .padding(.top, DroppySpacing.xs)
            }
            if state.lastFMNeedsAppCredentialRemedy || state.catalogueSearch.appCredentialProblem != nil {
                credentialsBar
                    .padding(.top, DroppySpacing.xs)
            }
            catalogueBar
                .padding(.top, DroppySpacing.sm)
            results
            footer
        }
        .padding(DroppySpacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DroppyPanelSurface(cornerRadius: 26))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onAppear {
            installKeyHandlers()
            ensureSelection()
            fieldFocused = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                fieldFocused = true
            }
        }
        .onChange(of: model.query) { _, value in
            model.notice = nil
            model.selectedID = nil
            userMovedSelection = false
            hasAnnouncedAutomaticSelection = false
            droplet.paletteQueryChanged(value)
        }
        .onChange(of: state.catalogueSearch.isSearching) { _, searching in
            if searching, !wasSearching {
                announce("Searching the Last.fm catalogue.")
            } else if !searching, wasSearching, state.catalogueSearch.hasSearched {
                announce(summary(of: state.catalogueSearch))
                ensureSelection()
            }
            wasSearching = searching
        }
        .onChange(of: state.catalogueSearch) { _, _ in
            ensureSelection()
        }
        .onChange(of: model.collapsed) { _, _ in
            ensureSelection()
        }
        .onChange(of: model.expanded) { _, _ in
            ensureSelection()
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: DroppySpacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                .accessibilityHidden(true)
            TextField("Search the Last.fm catalogue", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .focused($fieldFocused)
                .accessibilityLabel(Text("Search the Last.fm catalogue"))
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                    fieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                }
                .buttonStyle(.plain)
                .help("Clear the search")
                .accessibilityLabel(Text("Clear the search"))
            }
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(DroppyCircleButtonStyle(size: 24))
            .help("Close search")
            .accessibilityLabel(Text("Close search"))
        }
        .padding(.horizontal, DroppySpacing.md)
        .frame(height: 54)
        .background(
            RoundedRectangle(cornerRadius: DroppyRadius.ms, style: .continuous)
                .fill(AdaptiveColors.notchSurfaceCardFill),
        )
    }

    // MARK: - Bars

    private func noticeBar(_ text: String) -> some View {
        HStack(spacing: DroppySpacing.sm) {
            Image(systemName: "exclamationmark.circle")
                .font(.caption.weight(.semibold))
                .accessibilityHidden(true)
            Text(text)
                .font(.caption)
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                .lineLimit(2)
            Spacer(minLength: DroppySpacing.sm)
            Button("Dismiss") {
                model.notice = nil
            }
            .buttonStyle(DroppyQuietButtonStyle(size: .small))
        }
        .padding(.horizontal, DroppySpacing.md)
        .padding(.vertical, DroppySpacing.xs)
        .background(
            RoundedRectangle(cornerRadius: DroppyRadius.sm, style: .continuous)
                .fill(AdaptiveColors.overlayAuto(0.08)),
        )
        .accessibilityElement(children: .contain)
    }

    private var credentialsBar: some View {
        HStack(alignment: .center, spacing: DroppySpacing.sm) {
            Image(systemName: "key.slash")
                .font(.caption.weight(.semibold))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(credentialTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                Text(credentialDetail)
                    .font(.caption2)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DroppySpacing.sm)
            Button("Open Settings") {
                droplet.openLastFMAppCredentialsFromPalette()
            }
            .buttonStyle(DroppyQuietButtonStyle(size: .small))
        }
        .padding(.horizontal, DroppySpacing.md)
        .padding(.vertical, DroppySpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DroppyRadius.sm, style: .continuous)
                .fill(AdaptiveColors.overlayAuto(0.08)),
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(credentialTitle))
        .accessibilityValue(Text(credentialDetail))
    }

    private var credentialTitle: String {
        if let problem = state.catalogueSearch.appCredentialProblem {
            return problem.title
        }
        return state.lastFMAppCredentialProblem?.title ?? "Last.fm app credentials are missing"
    }

    private var credentialDetail: String {
        if let problem = state.catalogueSearch.appCredentialProblem {
            return problem.detail
        }
        return state.lastFMAppCredentialProblem?.detail
            ?? "Search needs your own Last.fm API key and shared secret. Save them in Settings before searching."
    }

    private var catalogueBar: some View {
        HStack(spacing: DroppySpacing.xs) {
            Text("Last.fm catalogue")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            Spacer(minLength: DroppySpacing.sm)
            if state.catalogueSearch.isSearching {
                ProgressView()
                    .controlSize(.mini)
                Text("Searching")
                    .font(.caption2)
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            } else if state.catalogueSearch.isWaiting {
                Text("Waiting to search")
                    .font(.caption2)
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            } else if state.catalogueSearch.hasSearched {
                Text("Not cached")
                    .font(.caption2)
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            } else {
                Text("Type at least two characters")
                    .font(.caption2)
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Last.fm catalogue"))
    }

    // MARK: - Results

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(CatalogueGroupKind.allCases) { kind in
                        groupView(kind)
                    }
                    if !state.catalogueSearch.hasSearched, !state.catalogueSearch.isWaiting {
                        Text("Type an artist, album or track name to search the Last.fm catalogue.")
                            .font(.callout)
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            .padding(.top, DroppySpacing.lg)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .padding(.top, DroppySpacing.xs)
            }
            .onChange(of: model.selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func groupView(_ kind: CatalogueGroupKind) -> some View {
        let group = state.catalogueSearch.group(kind) ?? CatalogueGroupState(kind: kind)
        let isCollapsed = model.collapsed.contains(kind)
        VStack(alignment: .leading, spacing: 0) {
            groupHeader(kind, group: group, isCollapsed: isCollapsed)
                .id(SearchPaletteItem.group(kind).id)
            if !isCollapsed {
                switch group.phase {
                case .idle:
                    EmptyView()
                case .loading:
                    groupStatus("Searching…")
                case .ready:
                    rows(group, kind: kind)
                case .empty:
                    groupStatus(
                        group.detail.map { "No \(kind.title.lowercased()) match this search. \($0)" }
                            ?? "No \(kind.title.lowercased()) match this search.",
                    )
                case .unavailable:
                    groupStatus(group.detail ?? "This group is unavailable.")
                case let .failed(failure):
                    failureStatus(failure)
                }
            }
        }
        .padding(.bottom, DroppySpacing.xs)
    }

    private func groupHeader(
        _ kind: CatalogueGroupKind,
        group: CatalogueGroupState,
        isCollapsed: Bool,
    ) -> some View {
        let isSelected = model.selectedID == SearchPaletteItem.group(kind).id
        return Button {
            toggleGroup(kind)
        } label: {
            HStack(spacing: DroppySpacing.xs) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    .frame(width: 12)
                    .accessibilityHidden(true)
                Text(kind.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                if let detail = group.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: DroppySpacing.sm)
                groupStatusLabel(group)
            }
            .padding(.horizontal, DroppySpacing.xs)
            .frame(height: 30)
            .background(rowBackground(isSelected, radius: DroppyRadius.sm))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(kind.title))
        .accessibilityValue(Text(headerAccessibilityValue(group, isCollapsed: isCollapsed)))
        .accessibilityHint(Text("Return to collapse or expand this group"))
    }

    private func headerAccessibilityValue(
        _ group: CatalogueGroupState,
        isCollapsed: Bool,
    ) -> String {
        var parts = [isCollapsed ? "Collapsed" : "Expanded"]
        switch group.phase {
        case .idle:
            parts.append("Not searched")
        case .loading:
            parts.append("Searching")
        case .ready:
            parts.append("\(group.rows.count) results")
        case .empty:
            parts.append("No matches")
        case .unavailable:
            parts.append("Unavailable")
        case let .failed(failure):
            parts.append("Failed. \(failure.message)")
        }
        if let detail = group.detail, !detail.isEmpty {
            parts.append(detail)
        }
        return parts.joined(separator: ". ")
    }

    @ViewBuilder
    private func groupStatusLabel(_ group: CatalogueGroupState) -> some View {
        switch group.phase {
        case .ready:
            Text("\(group.rows.count)")
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
        case .empty:
            statusPill("No matches")
        case .unavailable:
            statusPill("Unavailable")
        case .failed:
            statusPill("Failed")
        case .loading:
            ProgressView()
                .controlSize(.mini)
        case .idle:
            EmptyView()
        }
    }

    private func statusPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(AdaptiveColors.overlayAuto(0.1)),
            )
    }

    private func groupStatus(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, DroppySpacing.md)
            .padding(.vertical, DroppySpacing.xs)
    }

    @ViewBuilder
    private func rows(_ group: CatalogueGroupState, kind: CatalogueGroupKind) -> some View {
        let isExpanded = model.expanded.contains(kind)
        let visible = isExpanded ? group.rows : Array(group.rows.prefix(CatalogueSearchReadModel.visibleRowLimit))
        ForEach(visible) { row in
            resultRow(row)
        }
        if group.rows.count > CatalogueSearchReadModel.visibleRowLimit, !isExpanded {
            showMoreRow(kind, count: group.rows.count)
        }
    }

    @ViewBuilder
    private func resultRow(_ row: CatalogueRow) -> some View {
        if row.pageURL == nil {
            rowButton(row)
        } else {
            rowButton(row)
                .accessibilityAction(named: Text("Open on Last.fm")) {
                    openLastFM(row)
                }
        }
    }

    private func rowButton(_ row: CatalogueRow) -> some View {
        let isSelected = model.selectedID == SearchPaletteItem.row(row).id
        return Button {
            activate(.row(row))
        } label: {
            HStack(spacing: DroppySpacing.sm) {
                if state.hasImageOverride(for: row) {
                    ArtworkSleeve(
                        size: 28,
                        artwork: state.imageOverrideData(for: row),
                        identity: "\(row.group.rawValue)\u{1F}\(row.title)",
                        isCircular: row.group == .artists,
                    )
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !row.subtitle.isEmpty {
                        Text(row.subtitle)
                            .font(.caption)
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: DroppySpacing.sm)
                Image(systemName: rowIcon(row))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, DroppySpacing.md)
            .frame(height: 42)
            .background(rowBackground(isSelected, radius: DroppyRadius.sm))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(SearchPaletteItem.row(row).id)
        .accessibilityLabel(Text(rowAccessibilityLabel(row)))
        .accessibilityValue(Text("Last.fm catalogue"))
        .accessibilityHint(Text(primaryHint(for: row)))
        .accessibilityAction(named: Text("Play")) {
            droplet.playPaletteRow(row)
        }
        .contextMenu {
            Button("Play") {
                droplet.playPaletteRow(row)
            }
            if row.pageURL != nil {
                Button("Open on Last.fm") {
                    openLastFM(row)
                }
            }
        }
    }

    private func showMoreRow(_ kind: CatalogueGroupKind, count: Int) -> some View {
        let isSelected = model.selectedID == SearchPaletteItem.showMore(kind).id
        return Button {
            expand(kind)
        } label: {
            HStack(spacing: DroppySpacing.xs) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                Text("Show more \(kind.title.lowercased())")
                    .font(.caption.weight(.medium))
                Spacer()
                Text("\(count)")
                    .font(.caption2)
                    .monospacedDigit()
            }
            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            .padding(.horizontal, DroppySpacing.md)
            .frame(height: 32)
            .background(rowBackground(isSelected, radius: DroppyRadius.sm))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(SearchPaletteItem.showMore(kind).id)
        .accessibilityLabel(Text("Show more \(kind.title.lowercased())"))
        .accessibilityValue(Text("\(count) results"))
        .accessibilityHint(Text("Return to show every result in this group"))
    }

    private func failureStatus(_ failure: CatalogueSearchFailure) -> some View {
        HStack(alignment: .center, spacing: DroppySpacing.sm) {
            Text(failure.message)
                .font(.caption)
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DroppySpacing.sm)
            if failure.needsSettings {
                Button("Settings") {
                    droplet.openLastFMAppCredentialsFromPalette()
                }
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
            }
            Button("Try again") {
                droplet.retryCatalogueSearch()
            }
            .buttonStyle(DroppyQuietButtonStyle(size: .small))
        }
        .padding(.horizontal, DroppySpacing.md)
        .padding(.vertical, DroppySpacing.xs)
    }

    private func rowBackground(_ isSelected: Bool, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(isSelected ? AdaptiveColors.overlayAuto(0.1) : .clear)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: DroppySpacing.sm) {
            if state.playbackTemplate == nil {
                Text("Return opens details · ⌥Return sets up play · ⌘Return opens Last.fm")
                    .font(.caption2)
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    .accessibilityLabel(
                        Text(
                            "Return opens details. Option-Return opens Search settings because "
                                + "no playback URL is set. Command-Return opens Last.fm.",
                        ),
                    )
                Spacer(minLength: DroppySpacing.sm)
                Button("Set up in Settings") {
                    droplet.openSearchSettingsFromPalette()
                }
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
            } else {
                Text("Return opens details · ⌥Return plays · ⌘Return opens Last.fm · Esc clears, then closes")
                    .font(.caption2)
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    .accessibilityLabel(
                        Text(
                            "Return opens details. Option-Return plays. Command-Return opens Last.fm. Escape clears the text, then closes.",
                        ),
                    )
                Spacer(minLength: 0)
            }
        }
        .padding(.top, DroppySpacing.xs)
    }

    // MARK: - Selection and keys

    private var visibleItems: [SearchPaletteItem] {
        var items: [SearchPaletteItem] = []
        for kind in CatalogueGroupKind.allCases {
            guard let group = state.catalogueSearch.group(kind) else { continue }
            items.append(.group(kind))
            guard !model.collapsed.contains(kind) else { continue }
            let limit = model.expanded.contains(kind)
                ? group.rows.count
                : min(CatalogueSearchReadModel.visibleRowLimit, group.rows.count)
            for row in group.rows.prefix(limit) {
                items.append(.row(row))
            }
            if group.rows.count > CatalogueSearchReadModel.visibleRowLimit, !model.expanded.contains(kind) {
                items.append(.showMore(kind))
            }
        }
        return items
    }

    private func installKeyHandlers() {
        model.onMove = { [self] delta in move(delta) }
        model.onActivate = { [self] in activateSelected() }
        model.onOptionActivate = { [self] in optionActivateSelected() }
        model.onCommandActivate = { [self] in commandActivateSelected() }
        model.onEscape = { [self] in escape() }
    }

    private func move(_ delta: Int) {
        let items = visibleItems
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == model.selectedID } ?? (delta > 0 ? -1 : 0)
        let next = min(max(current + delta, 0), items.count - 1)
        userMovedSelection = true
        hasAnnouncedAutomaticSelection = true
        model.selectedID = items[next].id
        announce(announcement(for: items[next]))
    }

    private func activateSelected() {
        guard let item = visibleItems.first(where: { $0.id == model.selectedID }) else { return }
        activate(item)
    }

    private func optionActivateSelected() {
        guard case let .row(row)? = visibleItems.first(where: { $0.id == model.selectedID }) else {
            return
        }
        droplet.playPaletteRow(row)
    }

    private func commandActivateSelected() {
        guard let item = visibleItems.first(where: { $0.id == model.selectedID }) else { return }
        switch item {
        case let .row(row):
            openLastFM(row)
        default:
            activate(item)
        }
    }

    private func activate(_ item: SearchPaletteItem) {
        switch item {
        case let .group(kind):
            toggleGroup(kind)
            fieldFocused = true
        case let .showMore(kind):
            expand(kind)
            fieldFocused = true
        case let .row(row):
            droplet.openPaletteRowDetails(row)
        }
    }

    private func openLastFM(_ row: CatalogueRow) {
        droplet.openLastFMPageFromPalette(row)
    }

    private func escape() {
        if model.query.isEmpty {
            close()
        } else {
            model.query = ""
            model.notice = nil
            fieldFocused = true
        }
    }

    private func ensureSelection() {
        let items = visibleItems
        if let selected = model.selectedID, items.contains(where: { $0.id == selected }) {
            return
        }
        guard !userMovedSelection, let first = firstRow(in: items) else {
            model.selectedID = nil
            return
        }
        model.selectedID = first.id
        if !hasAnnouncedAutomaticSelection {
            hasAnnouncedAutomaticSelection = true
            announce(announcement(for: first))
        }
    }

    private func firstRow(in items: [SearchPaletteItem]) -> SearchPaletteItem? {
        items.first {
            if case .row = $0 {
                true
            } else {
                false
            }
        }
    }

    private func toggleGroup(_ kind: CatalogueGroupKind) {
        userMovedSelection = true
        if model.collapsed.contains(kind) {
            model.collapsed.remove(kind)
            announce("\(kind.title) expanded.")
        } else {
            model.collapsed.insert(kind)
            announce("\(kind.title) collapsed.")
        }
        fieldFocused = true
    }

    private func expand(_ kind: CatalogueGroupKind) {
        userMovedSelection = true
        model.expanded.insert(kind)
        if let group = state.catalogueSearch.group(kind),
           group.rows.count > CatalogueSearchReadModel.visibleRowLimit {
            model.selectedID = SearchPaletteItem.row(
                group.rows[CatalogueSearchReadModel.visibleRowLimit],
            ).id
        }
        announce("Showing all \(kind.title.lowercased()).")
        fieldFocused = true
    }

    private func announcement(for item: SearchPaletteItem) -> String {
        switch item {
        case let .group(kind):
            let state = model.collapsed.contains(kind) ? "collapsed" : "expanded"
            return "\(kind.title) group, \(state)."
        case let .showMore(kind):
            return "Show more \(kind.title.lowercased())."
        case let .row(row):
            let title = row.subtitle.isEmpty ? row.title : "\(row.title), \(row.subtitle)"
            return "\(row.group.title), \(title). \(primaryHint(for: row))"
        }
    }

    private func summary(of search: CatalogueSearchState) -> String {
        let parts = search.groups.map { group -> String in
            switch group.phase {
            case .idle:
                "\(group.kind.title), not searched"
            case .loading:
                "\(group.kind.title), searching"
            case .ready:
                "\(group.kind.title), \(group.rows.count) results"
            case .empty:
                "\(group.kind.title), no matches"
            case .unavailable:
                "\(group.kind.title), unavailable. \(group.detail ?? "")"
            case let .failed(failure):
                "\(group.kind.title), failed. \(failure.message)"
            }
        }
        return parts.joined(separator: ". ")
    }

    private func rowIcon(_: CatalogueRow) -> String {
        "info.circle"
    }

    private func rowAccessibilityLabel(_ row: CatalogueRow) -> String {
        row.subtitle.isEmpty ? row.title : "\(row.title), \(row.subtitle)"
    }

    private func primaryHint(for row: CatalogueRow) -> String {
        if row.pageURL == nil {
            return "Return opens details. Option-Return plays. No Last.fm page is available."
        }
        return "Return opens details. Option-Return plays. Command-Return opens the Last.fm page."
    }
}

// swiftlint:enable file_length type_body_length
