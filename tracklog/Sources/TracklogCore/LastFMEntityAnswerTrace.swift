import Foundation

/// The shape of one entity `getInfo` answer, kept when the app cannot read it.
///
/// Every field describes the answer's shape, never a value from it: the body's
/// values, the signed parameters, the session key, the signature and the
/// request URL stay out of the line by construction.
struct LastFMEntityAnswerTrace: Equatable, Sendable {
    /// Longest media type the line keeps. A real `Content-Type` is far shorter.
    private static let mediaTypeLimit = 64
    /// Most top-level key names the line keeps.
    private static let keyLimit = 16

    let method: String
    let statusCode: Int
    let bodyBytes: Int
    let contentType: String?
    let parsedAsJSON: Bool
    let topLevelKeys: [String]
    /// The JSON type found under the entity's key: `object`, `string`,
    /// `array`, `number`, `boolean`, `null`, `other`, or `absent`.
    let entityShape: String
    /// The decoding failure's kind and coding path, when decoding threw.
    var decodeFailure: String?
    /// Set when the decoded entity carried no facts and no link.
    var emptyEntityRejected = false

    init(method: String, entityKey: String, response: HTTPResponse) {
        self.method = method
        statusCode = response.statusCode
        bodyBytes = response.body.count
        contentType = Self.mediaType(response.header("Content-Type"))
        let object = try? JSONSerialization.jsonObject(with: response.body)
        parsedAsJSON = object != nil
        let dictionary = object as? [String: Any]
        topLevelKeys = Self.keyNames(dictionary?.keys)
        entityShape = Self.shape(of: dictionary?[entityKey])
    }

    /// The one line the host log receives for an unreadable answer.
    var logLine: String {
        [
            "Last.fm \(method) answer unreadable:",
            "status=\(statusCode)",
            "bytes=\(bodyBytes)",
            "content-type=\(contentType ?? "none")",
            "json=\(parsedAsJSON ? "yes" : "no")",
            "keys=\(topLevelKeys.isEmpty ? "none" : topLevelKeys.joined(separator: ","))",
            "entity=\(entityShape)",
            "decode=\(decodeFailure ?? "ok")",
            "empty-entity=\(emptyEntityRejected ? "yes" : "no")",
        ].joined(separator: " ")
    }

    func recordingDecodeFailure(_ error: any Error) -> Self {
        var copy = self
        if let decoding = error as? DecodingError {
            copy.decodeFailure = Self.describe(decoding)
        } else {
            copy.decodeFailure = "other"
        }
        return copy
    }

    func rejectingEmptyEntity() -> Self {
        var copy = self
        copy.emptyEntityRejected = true
        return copy
    }

    // MARK: - Helpers

    /// The media type without its parameters, so a charset is not kept.
    private static func mediaType(_ header: String?) -> String? {
        guard let header else { return nil }
        let type = header
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        guard !type.isEmpty else { return nil }
        guard type.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else { return "invalid" }
        return String(type.prefix(mediaTypeLimit))
    }

    /// The top-level keys Last.fm's `getInfo` answers use. A key is logged only
    /// when it is one of these; any other key is logged as `<other>`, so a key
    /// the service did not define cannot carry a value into the line.
    private static let knownKeys: Set<String> = ["artist", "album", "track", "error", "message", "links"]

    private static func keyNames(_ keys: [String: Any].Keys?) -> [String] {
        guard let keys else { return [] }
        let names = keys.map { knownKeys.contains($0) ? $0 : "<other>" }
        return Array(names.sorted().prefix(keyLimit))
    }

    private static func shape(of value: Any?) -> String {
        switch value {
        case nil: "absent"
        case is [String: Any]: "object"
        case is String: "string"
        case is [Any]: "array"
        case is NSNull: "null"
        case let number as NSNumber:
            CFGetTypeID(number) == CFBooleanGetTypeID() ? "boolean" : "number"
        default: "other"
        }
    }

    /// The kind and coding path only. A decoding error's debug text can quote
    /// the value that failed, so it is never logged.
    private static func describe(_ error: DecodingError) -> String {
        let kind = switch error {
        case .keyNotFound: "keyNotFound"
        case .valueNotFound: "valueNotFound"
        case .typeMismatch: "typeMismatch"
        case .dataCorrupted: "dataCorrupted"
        @unknown default: "unknown"
        }
        let context = switch error {
        case let .keyNotFound(_, context),
             let .valueNotFound(_, context),
             let .typeMismatch(_, context),
             let .dataCorrupted(context):
            context
        @unknown default:
            DecodingError.Context(codingPath: [], debugDescription: "")
        }
        let path = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
        return "\(kind)@\(path.isEmpty ? "root" : path.joined(separator: "."))"
    }
}
