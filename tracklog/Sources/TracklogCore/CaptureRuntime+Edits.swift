import Foundation

// MARK: - Simple edits

extension CaptureRuntime {
    /// Loads the rules the pipeline applies and the Edits page lists. A read
    /// failure leaves the previous rules in place rather than silently
    /// dropping every edit.
    func loadSimpleEdits() async {
        guard let editStore, let rules = try? await editStore.edits() else { return }
        state.simpleEdits = rules
    }
}

public extension CaptureRuntime {
    /// Saves a rule, then refreshes the list so the page shows the store's
    /// order and assigned id. Validation and storage errors reach the caller.
    @discardableResult
    func saveSimpleEdit(_ rule: SimpleEditRule) async throws -> SimpleEditRule {
        guard let editStore else {
            throw DatabaseError.open("simple edits are unavailable")
        }
        let saved = try await editStore.save(rule)
        await loadSimpleEdits()
        return saved
    }

    func deleteSimpleEdit(id: Int64) async throws {
        guard let editStore else { return }
        try await editStore.deleteEdit(id: id)
        await loadSimpleEdits()
    }
}
