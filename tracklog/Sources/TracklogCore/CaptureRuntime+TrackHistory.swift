import Foundation

// MARK: - Entity details

public extension CaptureRuntime {
    /// Opens one detail page from a list. The page replaces any open page.
    func openEntityDetail(_ request: EntityRequest) async {
        await entityDetail?.open(request)
    }

    /// An in-page link, such as a top-track row. The current page stays on the
    /// bounded stack so Back returns to it.
    func pushEntityDetail(_ request: EntityRequest) async {
        await entityDetail?.push(request)
    }

    /// Back reloads the revealed page from scratch, or closes the detail when
    /// the first page was showing.
    func backEntityDetail() async {
        await entityDetail?.back()
    }

    func closeEntityDetail() {
        entityDetail?.close()
    }

    func reloadEntityDetail() async {
        await entityDetail?.reload()
    }

    func loadMoreEntityListens() async {
        await entityDetail?.loadMoreTrackListens()
    }

    func retryEntityService() async {
        await entityDetail?.retryService()
    }

    func loadImageOverrides() async {
        await entityDetail?.loadOverrides()
    }

    func beginImageOverride(_ request: EntityRequest) {
        entityDetail?.beginOverride(request)
    }

    func clearImageOverrideDraft() {
        entityDetail?.clearOverrideDraft()
    }

    func saveImageOverride(
        kind: EntityKind,
        key: String,
        title: String,
        subtitle: String,
        data: Data,
    ) async throws {
        guard let entityDetail else {
            throw ImageOverrideError.noSelection
        }
        try await entityDetail.saveOverride(
            kind: kind,
            key: key,
            title: title,
            subtitle: subtitle,
            data: data,
        )
    }

    func removeImageOverride(kind: EntityKind, key: String) async throws {
        guard let entityDetail else {
            throw ImageOverrideError.noSelection
        }
        try await entityDetail.removeOverride(kind: kind, key: key)
    }
}
