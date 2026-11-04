import CryptoKit
import Foundation

/// A local edit or delete that did not reach durable storage.
public enum ListenMutationError: Error, Equatable, Sendable {
    /// The row is no longer in local history.
    case notFound
    /// Title and artist are required; album and album artist may be empty.
    case invalidMetadata

    public var message: String {
        switch self {
        case .notFound: "This listen is no longer in this Mac's history."
        case .invalidMetadata: "Track and artist cannot be empty."
        }
    }
}

/// The stored result of one local edit: the corrected listen and the optional
/// simple-edit rule saved with it.
public struct ListenEditResult: Equatable, Sendable {
    public let listen: Listen
    public let rule: SimpleEditRule?

    public init(listen: Listen, rule: SimpleEditRule? = nil) {
        self.listen = listen
        self.rule = rule
    }
}

/// One-off local history mutation. Separate from ``ListenStore`` so read-only
/// fakes and read surfaces do not have to implement writes they never use.
public protocol ListenMutationStore: Sendable {
    /// Edits one stored listen and optionally saves a rule in the same
    /// transaction. Delivery rows are untouched. Returns the corrected listen
    /// and the stored rule, when one was supplied.
    func editListen(
        id: Int64,
        to metadata: ListenMetadata,
        remembering rule: SimpleEditRule?,
    ) async throws -> ListenEditResult

    /// Removes one stored listen, its delivery rows and its local chart cache
    /// rows, and records a hashed tombstone so the same play cannot be
    /// re-captured. Unknown ids throw ``ListenMutationError/notFound``.
    func deleteListen(id: Int64, at date: Date) async throws
}

/// A hidden, one-way fingerprint of a deleted listen's durable dedup key.
///
/// The dedup key contains readable track, artist and album text, so the
/// tombstone stores only this hash. A later capture hashes its key the same way
/// and is refused when the tombstone exists.
public enum ListenTombstone {
    public static func hash(of dedupKey: String) -> String {
        SHA256.hash(data: Data(dedupKey.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// The exact copy one local mutation shows for its delivery consequences.
public struct ListenMutationNotice: Equatable, Sendable {
    public let title: String?
    public let body: String
    public let serviceLines: [String]
    public let footer: String

    public init(
        title: String? = nil,
        body: String,
        serviceLines: [String],
        footer: String,
    ) {
        self.title = title
        self.body = body
        self.serviceLines = serviceLines
        self.footer = footer
    }

    /// The whole notice as one spoken string, for an accessibility
    /// announcement.
    public var spoken: String {
        ([title, body] + serviceLines + [footer])
            .compactMap(\.self)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// The one place the edit page and delete confirmation derive their copy.
/// Delivery state is always read from the rows that actually exist for the
/// listen, so the notice can never claim a target that is not stored.
public enum ListenMutationNoticeBuilder {
    public static let editBody = "Changes stay on this Mac."
    public static let editFooter =
        "Last.fm history cannot be rewritten; Libre.fm and ListenBrainz are not changed by this update."
    public static let deleteBody = "This listen will be removed from this Mac's history."
    public static let deleteFooter =
        "Last.fm cannot rewrite history. Libre.fm and ListenBrainz are not changed by this update."

    public static func edit(
        deliveries: [Delivery],
        connections: [Connection],
    ) -> ListenMutationNotice {
        ListenMutationNotice(
            body: editBody,
            serviceLines: serviceLines(
                deliveries: deliveries,
                connections: connections,
                deleting: false,
            ),
            footer: editFooter,
        )
    }

    public static func delete(
        listen: Listen,
        deliveries: [Delivery],
        connections: [Connection],
    ) -> ListenMutationNotice {
        ListenMutationNotice(
            title: "Delete “\(listen.processed.title)”?",
            body: deleteBody,
            serviceLines: serviceLines(
                deliveries: deliveries,
                connections: connections,
                deleting: true,
            ),
            footer: deleteFooter,
        )
    }

    private static func serviceLines(
        deliveries: [Delivery],
        connections: [Connection],
        deleting: Bool,
    ) -> [String] {
        guard !deliveries.isEmpty else { return ["No service received this listen."] }
        return deliveries.map { delivery in
            let name = serviceName(for: delivery, connections: connections)
            switch delivery.state {
            case .waiting, .retrying:
                let verb = delivery.state == .waiting ? "Waiting" : "Retrying"
                if deleting {
                    return "\(verb) for \(name): that delivery will be discarded. "
                        + "A send already under way may still arrive."
                }
                return "\(verb) for \(name): the next attempt will use these values."
            case .delivered:
                return "Delivered to \(name): that copy stays."
            case .abandoned:
                return "Not delivered to \(name): unchanged."
            }
        }
    }

    private static func serviceName(for delivery: Delivery, connections: [Connection]) -> String {
        delivery.serviceKind?.displayName
            ?? connections.first { $0.id == delivery.connectionID }?.kind.displayName
            ?? "an unknown service"
    }
}
