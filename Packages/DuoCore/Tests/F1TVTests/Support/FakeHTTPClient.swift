import Foundation
@testable import F1TV

/// Test double for `HTTPClient`. Answers by matching the request URL path suffix
/// and records every request it receives.
actor FakeHTTPClient: HTTPClient {
    private var routes: [(suffix: String, response: Result<HTTPResponse, Error>)] = []
    private(set) var requests: [HTTPRequest] = []

    init() {}

    func respond(pathSuffix: String, status: Int = 200, body: Data = Data()) {
        routes.append((pathSuffix, .success(HTTPResponse(status: status, body: body))))
    }

    func respond(pathSuffix: String, status: Int = 200, json: String) {
        respond(pathSuffix: pathSuffix, status: status, body: Data(json.utf8))
    }

    func fail(pathSuffix: String, with error: Error) {
        routes.append((pathSuffix, .failure(error)))
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        let path = request.url.path
        // Latest registered route wins, so tests can override earlier answers.
        guard let route = routes.last(where: { path.hasSuffix($0.suffix) }) else {
            return HTTPResponse(status: 404, body: Data())
        }
        return try route.response.get()
    }
}
