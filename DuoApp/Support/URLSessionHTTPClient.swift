import F1TV
import Foundation

/// `HTTPClient` over an ephemeral URLSession: no shared cookies, no disk cache, 15 s timeout.
/// Errors never carry the request (it holds token headers) or its URL.
final class URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw F1TVError.network("Unexpected response")
            }
            return HTTPResponse(status: http.statusCode, body: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as F1TVError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw F1TVError.network(Self.describe(error.code))
        } catch {
            throw F1TVError.network("Network error")
        }
    }

    private static func describe(_ code: URLError.Code) -> String {
        switch code {
        case .timedOut: return "The request timed out"
        case .notConnectedToInternet: return "No internet connection"
        case .networkConnectionLost: return "The connection was lost"
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return "Can't reach F1 TV"
        default: return "Network error"
        }
    }
}
