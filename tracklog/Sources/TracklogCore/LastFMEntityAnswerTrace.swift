import Foundation

/// How one entity `getInfo` attempt was sent. The variants are tried in this
/// order, and only after an earlier attempt answered an empty object.
enum LastFMEntityVariant: String, Equatable, Sendable {
    case post
    case get
    case postNoUsername = "post-no-username"
    case getNoUsername = "get-no-username"

    var verb: HTTPMethod {
        switch self {
        case .post, .postNoUsername: .post
        case .get, .getNoUsername: .get
        }
    }
}

/// One attempt at an entity read, as the host log records it. A refused
/// attempt has no answer, only the reason the service or transport gave.
struct LastFMEntityAttempt: Equatable, Sendable {
    let method: String
    let variant: LastFMEntityVariant
    let answer: LastFMEntityAnswerTrace?
    let refusal: String?

    /// The one line the host log receives for this attempt. It names the
    /// shape only: no value from the answer, no parameter, key, signature or
    /// URL.
    func logLine(rendered: Bool, emptyEntityRejected: Bool) -> String {
        var fields = ["Last.fm \(method) attempt: variant=\(variant.rawValue)"]
        if let answer {
            fields += answer.fields
        } else {
            fields.append("refused=\(refusal ?? "other")")
        }
        if emptyEntityRejected {
            fields.append("empty-entity=yes")
        }
        fields.append("rendered=\(rendered ? "yes" : "no")")
        return fields.joined(separator: " ")
    }
}

/// The shape of one entity `getInfo` answer. Every field describes the
/// answer's shape, never a value from it, so the line is safe to log.
struct LastFMEntityAnswerTrace: Equatable, Sendable {
    /// Longest media type the line keeps. A real `Content-Type` is far shorter.
    private static let mediaTypeLimit = 64
    /// Most top-level key names the line keeps.
    private static let keyLimit = 16

    let statusCode: Int
    let bodyBytes: Int
    let contentType: String?
    let parsedAsJSON: Bool
    let topLevelKeys: [String]
    /// The JSON type found under the entity's key: `object`, `string`,
    /// `array`, `number`, `boolean`, `null`, `other`, or `absent`.
    let entityShape: String
    /// True when the body is a JSON object with no keys: the answer Last.fm
    /// sends for a signed read it does not accept, and the only answer that
    /// triggers a retry.
    let emptyObject: Bool
    /// The decoding failure's kind and coding path, when decoding threw.
    var decodeFailure: String?

    init(method _: String, entityKey: String, response: HTTPResponse) {
        statusCode = response.statusCode
        bodyBytes = response.body.count
        contentType = Self.mediaType(response.header("Content-Type"))
        let object = try? JSONSerialization.jsonObject(with: response.body)
        parsedAsJSON = object != nil
        let dictionary = object as? [String: Any]
        topLevelKeys = Self.keyNames(dictionary?.keys)
        entityShape = Self.shape(of: dictionary?[entityKey])
        emptyObject = dictionary?.isEmpty == true
        decodeFailure = nil
    }

    /// The fields after the attempt's name, in the order the line uses.
    fileprivate var fields: [String] {
        [
            "status=\(statusCode)",
            "bytes=\(bodyBytes)",
            "content-type=\(contentType ?? "none")",
            "json=\(parsedAsJSON ? "yes" : "no")",
            "keys=\(topLevelKeys.isEmpty ? "none" : topLevelKeys.joined(separator: ","))",
            "entity=\(entityShape)",
            "present=\(entityShape == "object" ? "yes" : "no")",
            "decode=\(decodeFailure ?? "ok")",
        ]
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

    /// Schema key names only. A key outside the plain identifier pattern is
    /// replaced, so an unexpected key cannot carry a value into the line.
    private static func keyNames(_ keys: [String: Any].Keys?) -> [String] {
        guard let keys else { return [] }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_#@")
        let names = keys.map { key -> String in
            guard !key.isEmpty, key.count <= 32, key.allSatisfy({ allowed.contains($0) }) else {
                return "<redacted>"
            }
            return key
        }
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
