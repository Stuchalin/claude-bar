import Foundation

/// What a stubbed host answers.
enum StubResponse: Sendable {
    case http(status: Int, headers: [String: String] = [:], body: String = "")
    case redirect(status: Int = 302, location: String)
    case failure(URLError.Code)
}

/// URLProtocol that answers from per-host (optionally per-path) handlers and records every request.
///
/// Each test registers its own unique hosts through `StubHosts`, so tests stay parallel-safe.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: StubResponse] = [:]
    nonisolated(unsafe) private static var requests: [String: [URLRequest]] = [:]

    /// Answers `response` for `path` on `host`, or for every other path when `path` is `nil`.
    static func register(host: String, path: String? = nil, response: StubResponse) {
        lock.withLock { handlers[routeKey(host, path)] = response }
    }

    static func unregister(host: String) {
        lock.withLock {
            handlers = handlers.filter { $0.key != host && !$0.key.hasPrefix(host + "/") }
            requests[host] = nil
        }
    }

    private static func routeKey(_ host: String, _ path: String?) -> String {
        path.map { host + $0 } ?? host
    }

    static func recordedRequests(host: String) -> [URLRequest] {
        lock.withLock { requests[host] ?? [] }
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        let response: StubResponse? = Self.lock.withLock {
            Self.requests[host, default: []].append(request)
            return Self.handlers[Self.routeKey(host, request.url?.path)] ?? Self.handlers[host]
        }
        guard let response, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }

        switch response {
        case let .http(status, headers, body):
            deliver(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, body)
        case let .redirect(status, location):
            let redirect = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Location": location]
            )!
            var next = request
            next.url = URL(string: location)
            // Like URLSession's HTTP loader: offer the redirect, and if the delegate refuses it the
            // 3xx response completes the task.
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: redirect)
            deliver(redirect, "moved")
        case let .failure(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}

    private func deliver(_ response: HTTPURLResponse, _ body: String) {
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    /// An ephemeral configuration routed through this protocol.
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }
}

/// Unique stub hosts for one test, unregistered when released.
final class StubHosts {
    private var hosts: [String] = []

    /// Registers a fresh `*.test` host answering `response` and returns it.
    func add(_ response: StubResponse) -> String {
        let host = "h\(UUID().uuidString.lowercased()).test"
        StubURLProtocol.register(host: host, response: response)
        hosts.append(host)
        return host
    }

    deinit {
        hosts.forEach(StubURLProtocol.unregister)
    }
}
