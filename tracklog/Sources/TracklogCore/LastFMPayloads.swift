import Foundation

// MARK: - Payloads

struct ErrorPayload: Decodable {
    let error: Int?
    let message: String?
}

struct TokenPayload: Decodable {
    let token: String?
}

struct SessionPayload: Decodable {
    let session: SessionValue?
}

struct SessionValue: Decodable {
    let name: String?
    let key: String?
}

struct UserPayload: Decodable {
    let user: UserValue?
}

struct UserValue: Decodable {
    let name: String?
}

struct ScrobblePayload: Decodable {
    let scrobbles: ScrobblesValue?
}

struct ScrobblesValue: Decodable {
    let scrobble: ScrobbleList?
}

enum ScrobbleList: Decodable {
    case one(ScrobbleValue)
    case many([ScrobbleValue])

    var items: [ScrobbleValue] {
        switch self {
        case let .one(value): [value]
        case let .many(values): values
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let values = try? container.decode([ScrobbleValue].self) {
            self = .many(values)
        } else {
            self = try .one(container.decode(ScrobbleValue.self))
        }
    }
}

struct ScrobbleValue: Decodable {
    let ignoredMessage: IgnoredMessage?
}

struct IgnoredMessage: Decodable {
    let code: Int?

    enum CodingKeys: String, CodingKey {
        case code
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? container.decode(String.self, forKey: .code) {
            guard let value = Int(text) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .code,
                    in: container,
                    debugDescription: "The ignored code is not an integer.",
                )
            }
            code = value
        } else {
            code = try container.decode(Int.self, forKey: .code)
        }
    }
}
