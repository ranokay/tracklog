import Foundation
import TracklogCore

/// The production HTTP transport. One session owns the timeouts and the
/// descriptive User-Agent every request carries. Adapters never open a
/// session of their own.
final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    init(
        userAgent: String = TracklogHTTP.userAgent,
        timeout: TimeInterval = 15,
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.httpAdditionalHeaders = [
            "User-Agent": userAgent,
            "Accept": "application/json",
        ]
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            headers[String(describing: name)] = String(describing: value)
        }
        return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    }
}
