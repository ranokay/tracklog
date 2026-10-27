import Foundation

// MARK: - Simple edits

extension CaptureRuntime {
    /// Loads the rules the pipeline applies and the Edits page lists. A read
    /// failure leaves the previous rules in place and surfaces the failure
    /// instead of silently applying an empty or stale set.
    func loadSimpleEdits() async {
        guard let editStore else { return }
        do {
            state.simpleEdits = try await editStore.edits()
            if state.failure?.stage == .edits {
                state.failure = nil
            }
        } catch {
            state.failure = .edits(error: error)
        }
    }
}

public extension CaptureRuntime {
    /// Saves a rule, then refreshes the list so the page shows the store's
    /// order and assigned id. Validation and storage errors reach the caller.
    @discardableResult
    func saveSimpleEdit(_ rule: SimpleEditRule) async throws -> SimpleEditRule {
        guard let editStore else {
            throw DatabaseError.unavailable("simple edits are unavailable")
        }
        let saved = try await editStore.save(rule)
        await loadSimpleEdits()
        return saved
    }

    func deleteSimpleEdit(id: Int64) async throws {
        guard let editStore else {
            throw DatabaseError.unavailable("simple edits are unavailable")
        }
        try await editStore.deleteEdit(id: id)
        await loadSimpleEdits()
    }
}
