import Foundation

/// Durable block rules. The metadata pipeline loads them before it persists a
/// captured listen; a match cancels the listen.
public protocol BlockStore: Sendable {
    /// Every saved block, in evaluation order: most specific first, then
    /// newest first.
    func blocks() async throws -> [BlockRule]
    /// Saves a new block or replaces one. A block whose field tuple equals an
    /// existing block's tuple replaces that block. Returns the stored record.
    @discardableResult
    func save(_ block: BlockRule) async throws -> BlockRule
    /// Deletes one block. An unknown id is a no-op.
    func deleteBlock(id: Int64) async throws
}
