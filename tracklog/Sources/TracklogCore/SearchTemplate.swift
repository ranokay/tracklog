import Foundation

/// Why a playback URL template was refused. The Settings page shows the
/// message; nothing is saved until the template parses.
public enum SearchTemplateError: Error, Equatable, Sendable, LocalizedError {
    case missingPlaceholder
    case duplicatePlaceholder
    case schemeNotAllowed
    case missingHost
    case userInfoNotAllowed
    case placeholderInAuthority
    case invalidTemplate

    public var errorDescription: String? {
        switch self {
        case .missingPlaceholder:
            "The template needs one {query} placeholder."
        case .duplicatePlaceholder:
            "Use {query} exactly once."
        case .schemeNotAllowed:
            "Use an http or https address. Other schemes are not opened."
        case .missingHost:
            "The template needs a host name, such as example.com."
        case .userInfoNotAllowed:
            "Remove the user name and password from the template."
        case .placeholderInAuthority:
            "Put {query} in the path, query or fragment, never in the host."
        case .invalidTemplate:
            "The template is not a web address that can be opened."
        }
    }
}

/// One validated search-and-play URL template. The placeholder is `{query}`;
/// the typed text is encoded with the RFC 3986 unreserved set before it is
/// substituted, so the query can never choose another destination.
public struct SearchTemplate: Equatable, Sendable {
    public static let placeholder = "{query}"

    public let rawValue: String

    private init(rawValue: String) {
        self.rawValue = rawValue
    }

    // MARK: - Parsing

    public static func parse(_ raw: String) -> Result<SearchTemplate, SearchTemplateError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.components(separatedBy: placeholder)
        guard parts.count > 1 else { return .failure(.missingPlaceholder) }
        guard parts.count == 2 else { return .failure(.duplicatePlaceholder) }

        // A placeholder that becomes part of the host, port or userinfo would
        // let typed text choose the destination. The sentinel is safe to parse
        // and survives in whichever component held the placeholder.
        let sentinel = "palettequeryplaceholder"
        let sample = trimmed.replacingOccurrences(of: placeholder, with: sentinel)
        guard let components = URLComponents(string: sample),
              let scheme = components.scheme?.lowercased()
        else { return .failure(.invalidTemplate) }
        guard scheme == "http" || scheme == "https" else {
            return .failure(.schemeNotAllowed)
        }
        guard let host = components.host, !host.isEmpty else {
            return .failure(.missingHost)
        }
        if host.contains(sentinel)
            || components.user?.contains(sentinel) == true
            || components.password?.contains(sentinel) == true {
            return .failure(.placeholderInAuthority)
        }
        guard components.user == nil, components.password == nil else {
            return .failure(.userInfoNotAllowed)
        }
        guard components.url != nil else {
            return .failure(.invalidTemplate)
        }
        return .success(SearchTemplate(rawValue: trimmed))
    }

    public static func parseOrNil(_ raw: String) -> SearchTemplate? {
        try? parse(raw).get()
    }

    // MARK: - Rendering

    /// The encoded query, or nil for an empty one. A literal `{query}` in the
    /// listener's text is data and is encoded like every other character.
    public func url(for query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let rendered = rawValue.replacingOccurrences(
            of: Self.placeholder,
            with: Self.percentEncoded(trimmed),
        )
        guard let components = URLComponents(string: rendered),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil
        else { return nil }
        return components.url
    }

    /// RFC 3986 unreserved characters only: letters, digits, `-`, `.`, `_`
    /// and `~`. Everything else is percent-encoded as UTF-8, so a space is
    /// `%20` rather than `+`.
    public static func percentEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~",
    )
}
