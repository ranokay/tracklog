import Foundation

/// Durable simple-edit rules. The metadata pipeline asks for them in
/// application order before it persists a captured listen.
public protocol SimpleEditStore: Sendable {
    /// Every saved rule, in application order: more specific first, then
    /// newest first.
    func edits() async throws -> [SimpleEditRule]
    /// Saves a new rule or replaces one. A rule whose active match tuple equals
    /// an existing rule's tuple replaces that rule. Returns the stored record.
    @discardableResult
    func save(_ rule: SimpleEditRule) async throws -> SimpleEditRule
    /// Deletes one rule. An unknown id is a no-op.
    func deleteEdit(id: Int64) async throws
}
