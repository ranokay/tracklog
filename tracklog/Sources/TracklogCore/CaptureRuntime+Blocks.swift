import Foundation

// MARK: - Blocks

extension CaptureRuntime {
    /// Loads the blocks the pipeline evaluates and the Blocks page lists. A
    /// read failure leaves the previous blocks in place, surfaces the failure,
    /// and capture continues with that set.
    func loadBlocks() async {
        guard let blockStore else { return }
        do {
            state.blocks = try await blockStore.blocks()
            if state.failure?.stage == .blocks {
                state.failure = nil
            }
        } catch {
            state.failure = .blocks(error: error)
        }
    }
}

public extension CaptureRuntime {
    /// Saves a block, then refreshes the list so the page shows the store's
    /// order and assigned id. Validation and storage errors reach the caller.
    @discardableResult
    func saveBlock(_ block: BlockRule) async throws -> BlockRule {
        guard let blockStore else {
            throw DatabaseError.unavailable("blocks are unavailable")
        }
        let saved = try await blockStore.save(block)
        await loadBlocks()
        return saved
    }

    func deleteBlock(id: Int64) async throws {
        guard let blockStore else {
            throw DatabaseError.unavailable("blocks are unavailable")
        }
        try await blockStore.deleteBlock(id: id)
        await loadBlocks()
    }
}
