@testable import ClaudeBarCore
import Foundation
import Testing

private let now = Date(timeIntervalSince1970: 1_792_700_000)

private func makeClient() -> UsageClient {
    UsageClient(configuration: StubURLProtocol.configuration(), now: { now })
}

private func endpoint(_ host: String, scheme: String = "http", path: String = "") throws -> ProxyEndpoint {
    try ProxyEndpoint(validating: "\(scheme)://\(host)\(path)")
}

/// Fetches from a fresh stub host answering `response` and returns the thrown error.
private func fetchError(_ response: StubResponse) async throws -> UsageFetchError {
    let hosts = StubHosts()
    let host = hosts.add(response)
    let endpoint = try endpoint(host)
    let error = await #expect(throws: UsageFetchError.self) {
        try await makeClient().fetchUsage(endpoint: endpoint, secret: Fixture.dummy)
    }
    return try #require(error)
}

@Suite("UsageClient: request and success")
struct UsageClientRequestTests {
    @Test("sends the secret and protocol headers to {proxy}/api/oauth/usage and parses the body")
    func requestShape() async throws {
        let hosts = StubHosts()
        let host = hosts.add(.http(status: 200, body: UsageFixtures.realResponse))
        let endpoint = try endpoint(host, path: "/prefix/")

        let snapshot = try await makeClient().fetchUsage(endpoint: endpoint, secret: Fixture.dummy)
        #expect(snapshot.fetchedAt == now)
        #expect(snapshot.weekly?.usedPercent == 1)

        let request = try #require(StubURLProtocol.recordedRequests(host: host).first)
        #expect(request.url == URL(string: "http://\(host)/prefix/api/oauth/usage"))
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "x-proxy-secret") == Fixture.dummy)
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.timeoutInterval == 30)
        #expect(request.url?.query == nil)
    }

    @Test("reads the secret from the store")
    func readsStore() async throws {
        let hosts = StubHosts()
        let host = hosts.add(.http(status: 200, body: UsageFixtures.realResponse))
        let store = InMemorySecretStore(secret: Fixture.other)

        _ = try await makeClient().fetchUsage(endpoint: endpoint(host), secrets: store)
        let request = try #require(StubURLProtocol.recordedRequests(host: host).first)
        #expect(request.value(forHTTPHeaderField: "x-proxy-secret") == Fixture.other)
    }

    @Test("a missing secret fails before any request")
    func missingSecret() async throws {
        let hosts = StubHosts()
        let host = hosts.add(.http(status: 200, body: UsageFixtures.realResponse))
        let endpoint = try endpoint(host)
        await #expect(throws: UsageFetchError.missingSecret) {
            try await makeClient().fetchUsage(endpoint: endpoint, secrets: InMemorySecretStore())
        }
        #expect(StubURLProtocol.recordedRequests(host: host).isEmpty)
    }

    @Test("a failed Keychain read is reported, not treated as a missing secret")
    func unreadableSecret() async throws {
        let hosts = StubHosts()
        let endpoint = try endpoint(hosts.add(.http(status: 200)))
        await #expect(throws: UsageFetchError.secretUnreadable(.readFailed(status: -25293))) {
            try await makeClient().fetchUsage(endpoint: endpoint, secrets: ThrowingSecretStore())
        }
    }
}

@Suite("UsageClient: HTTP errors")
struct UsageClientErrorTests {
    static let proxyUnauthorized = #"{"error":"unauthorized: missing or invalid proxy secret"}"#
    static let upstreamUnauthorized =
        #"{"type":"error","error":{"type":"authentication_error","message":"OAuth token has expired."}}"#
    static let proxyExpired = #"{"type":"error","error":{"type":"forbidden","message":"access window has expired"}}"#
    static let proxyPolicy =
        #"{"type":"error","error":{"type":"forbidden","message":"model 'x' is blocked by this proxy"}}"#
    static func forbiddenBody(_ message: String) -> String {
        #"{"type":"error","error":{"type":"forbidden","message":"\#(message)"}}"#
    }

    static let modelNotAllowed = "model 'claude-x' is not in this proxy's allowed list"
    static let modelBlocked = "model 'claude-x' is blocked by this proxy"
    static let effortTooHigh = "effort 'max' exceeds this proxy's maximum of 'high' — lower the effort and retry"
    static let upstreamForbidden =
        #"{"type":"error","error":{"type":"permission_error","message":"access window has expired"}}"#
    static let proxyNoCredentials =
        #"{"error":"no upstream credentials available — log into Claude Code on this machine or set ANTHROPIC_OAUTH_TOKEN"}"#
    static let proxyBadGateway = #"{"error":"bad gateway","detail":"getaddrinfo ENOTFOUND api.anthropic.com"}"#

    @Test(
        "known proxy bodies map to specific errors; the same status with another body stays generic",
        arguments: [
            (401, proxyUnauthorized, UsageFetchError.proxySecretRejected),
            (401, upstreamUnauthorized, .unauthorized),
            (401, "", .unauthorized),
            (403, proxyExpired, .accessWindowExpired),
            (403, proxyPolicy, .proxyPolicyRejected(message: "model 'x' is blocked by this proxy")),
            (403, forbiddenBody(modelNotAllowed), .proxyPolicyRejected(message: modelNotAllowed)),
            (403, forbiddenBody(modelBlocked), .proxyPolicyRejected(message: modelBlocked)),
            (403, forbiddenBody(effortTooHigh), .proxyPolicyRejected(message: effortTooHigh)),
            (403, forbiddenBody("organization access denied"), .forbidden),
            (403, upstreamForbidden, .forbidden),
            (403, "<html>Forbidden</html>", .forbidden),
            (502, proxyNoCredentials, .proxyMissingCredentials),
            (502, proxyBadGateway, .upstreamUnreachable),
            (502, "<html>Bad Gateway</html>", .serverError(status: 502)),
            (500, proxyBadGateway, .serverError(status: 500)),
            (503, "", .serverError(status: 503)),
            (404, #"{"type":"error","error":{"type":"not_found_error"}}"#, .unexpectedStatus(404)),
        ]
    )
    func statusMapping(status: Int, body: String, expected: UsageFetchError) async throws {
        #expect(try await fetchError(.http(status: status, body: body)) == expected)
    }

    @Test("every error has a non-empty hint that never contains the secret")
    func hints() {
        let errors: [UsageFetchError] = [
            .missingSecret, .secretUnreadable(.readFailed(status: -1)), .proxySecretRejected, .unauthorized,
            .accessWindowExpired, .proxyPolicyRejected(message: "m"), .forbidden, .proxyMissingCredentials,
            .upstreamUnreachable, .rateLimited(retryAfter: nil), .serverError(status: 500),
            .redirectRefused(status: 302), .unexpectedStatus(404), .invalidResponse, .timeout,
            .network(.cannotConnectToHost), .cancelled,
        ]
        for error in errors {
            #expect(!error.hint.isEmpty)
            #expect(!error.hint.contains(Fixture.dummy))
        }
    }

    @Test(
        "429 carries Retry-After as seconds or an HTTP date",
        arguments: [
            (["Retry-After": "120"], Date?.some(now.addingTimeInterval(120))),
            (["Retry-After": " 0 "], now),
            (["Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"], Date(timeIntervalSince1970: 1_792_567_680)),
            (["Retry-After": "soon"], nil),
            (["Retry-After": "-5"], nil),
            ([:], nil),
        ]
    )
    func rateLimited(headers: [String: String], expected: Date?) async throws {
        #expect(try await fetchError(.http(status: 429, headers: headers)) == .rateLimited(retryAfter: expected))
    }

    @Test("a 200 that is not usage JSON is an invalid response", arguments: ["<html>ok</html>", "[]", #"{"ok":true}"#])
    func malformedSuccess(body: String) async throws {
        #expect(try await fetchError(.http(status: 200, body: body)) == .invalidResponse)
    }

    @Test(
        "transport failures",
        arguments: [
            (URLError.Code.timedOut, UsageFetchError.timeout),
            (.cannotConnectToHost, .network(.cannotConnectToHost)),
            (.notConnectedToInternet, .network(.notConnectedToInternet)),
            (.cancelled, .cancelled),
        ]
    )
    func transport(code: URLError.Code, expected: UsageFetchError) async throws {
        #expect(try await fetchError(.failure(code)) == expected)
    }
}

@Suite("UsageClient: redirects")
struct UsageClientRedirectTests {
    @Test("a cross-origin redirect is refused and the other host never receives the secret")
    func crossOrigin() async throws {
        let hosts = StubHosts()
        let other = hosts.add(.http(status: 200, body: UsageFixtures.realResponse))
        let origin = hosts.add(.redirect(location: "http://\(other)/api/oauth/usage"))

        let endpoint = try endpoint(origin)
        await #expect(throws: UsageFetchError.redirectRefused(status: 302)) {
            try await makeClient().fetchUsage(endpoint: endpoint, secret: Fixture.dummy)
        }
        #expect(StubURLProtocol.recordedRequests(host: origin).count == 1)
        #expect(StubURLProtocol.recordedRequests(host: other).isEmpty)
    }

    @Test("a redirect to another port or scheme on the same host is refused")
    func sameHostOtherOrigin() async throws {
        let hosts = StubHosts()
        let origin = hosts.add(.http(status: 200, body: UsageFixtures.realResponse))
        let endpoint = try endpoint(origin)
        for location in ["http://\(origin):8080/api/oauth/usage", "https://\(origin)/api/oauth/usage"] {
            StubURLProtocol.register(
                host: origin, path: "/api/oauth/usage", response: .redirect(status: 307, location: location)
            )
            await #expect(throws: UsageFetchError.redirectRefused(status: 307)) {
                try await makeClient().fetchUsage(endpoint: endpoint, secret: Fixture.dummy)
            }
        }
        #expect(StubURLProtocol.recordedRequests(host: origin).count == 2)
    }

    @Test("a same-origin redirect is followed with the secret")
    func sameOrigin() async throws {
        let hosts = StubHosts()
        let origin = hosts.add(.http(status: 200, body: UsageFixtures.realResponse))
        StubURLProtocol.register(
            host: origin, path: "/api/oauth/usage", response: .redirect(location: "http://\(origin)/moved")
        )

        let snapshot = try await makeClient().fetchUsage(endpoint: endpoint(origin), secret: Fixture.dummy)
        #expect(snapshot.weekly?.usedPercent == 1)
        let requests = StubURLProtocol.recordedRequests(host: origin)
        #expect(requests.map(\.url?.path) == ["/api/oauth/usage", "/moved"])
        #expect(requests.last?.value(forHTTPHeaderField: "x-proxy-secret") == Fixture.dummy)
    }

    @Test(
        "origin comparison",
        arguments: [
            ("http://a.test/x", "http://A.TEST:80/y", true),
            ("https://a.test/x", "https://a.test:443/y", true),
            ("http://a.test/x", "https://a.test/x", false),
            ("http://a.test/x", "http://b.test/x", false),
            ("http://a.test:8080/x", "http://a.test/x", false),
        ]
    )
    func origins(lhs: String, rhs: String, same: Bool) throws {
        let lhs = try #require(URL(string: lhs))
        let rhs = try #require(URL(string: rhs))
        #expect(SameOriginRedirectGuard.isSameOrigin(lhs, rhs) == same)
    }
}
