import Foundation

/// The one normalization behind every track and listen identity.
enum Identity {
    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func joined(_ fields: [String]) -> String {
        fields.map(normalized).joined(separator: "\u{1F}")
    }
}
