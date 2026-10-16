import Foundation

/// Fetches `{proxy}/api/oauth/usage` through claude-code-proxy.
///
/// The secret goes only in the `x-proxy-secret` header, is never logged, and is never sent to
/// another origin: redirects are followed only within the same scheme, host and port.
/// Nothing is cached and no cookies are stored.
public final class UsageClient: Sendable {
    static let timeout: TimeInterval = 30
    static let secretHeader = "x-proxy-secret"
    static let betaHeader = ("anthropic-beta", "oauth-2025-04-20")

    private let session: URLSession
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - configuration: base session configuration; tests inject stub protocol classes here.
    ///   - now: clock for `fetchedAt` and seconds-based `Retry-After`.
    public init(
        configuration: URLSessionConfiguration = .ephemeral,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = Self.timeout
        session = URLSession(configuration: configuration, delegate: SameOriginRedirectGuard(), delegateQueue: nil)
        self.now = now
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// Reads the secret from `secrets`, then fetches.
    public func fetchUsage(
        endpoint: ProxyEndpoint,
        secrets: any SecretStore
    ) async throws(UsageFetchError) -> UsageSnapshot {
        let secret: String?
        do {
            secret = try secrets.read()
        } catch {
            throw .secretUnreadable(error)
        }
        guard let secret, !secret.isEmpty else { throw .missingSecret }
        return try await fetchUsage(endpoint: endpoint, secret: secret)
    }

    public func fetchUsage(endpoint: ProxyEndpoint, secret: String) async throws(UsageFetchError) -> UsageSnapshot {
        let request = Self.makeRequest(url: endpoint.usageURL, secret: secret)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Self.transportError(error)
        }
        guard let http = response as? HTTPURLResponse else { throw .invalidResponse }

        let receivedAt = now()
        guard http.statusCode == 200 else {
            let retryAfter = RetryAfter.date(from: http.value(forHTTPHeaderField: "Retry-After"), now: receivedAt)
            throw UsageFetchError.from(status: http.statusCode, body: data, retryAfter: retryAfter)
        }
        do {
            return try UsageResponseParser.parse(data, fetchedAt: receivedAt)
        } catch {
            throw .invalidResponse
        }
    }

    static func makeRequest(url: URL, secret: String) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue(secret, forHTTPHeaderField: secretHeader)
        request.setValue(betaHeader.1, forHTTPHeaderField: betaHeader.0)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    static func transportError(_ error: any Error) -> UsageFetchError {
        if error is CancellationError { return .cancelled }
        guard let urlError = error as? URLError else { return .network(.unknown) }
        switch urlError.code {
        case .timedOut: return .timeout
        case .cancelled: return .cancelled
        default: return .network(urlError.code)
        }
    }
}

/// Follows a redirect only to the same scheme, host and port as the original request, so the
/// secret header (which URLSession copies onto the redirected request) never leaves the origin.
/// A refused redirect completes the task with the 3xx response.
final class SameOriginRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let original = task.originalRequest?.url, let target = request.url,
              Self.isSameOrigin(original, target)
        else { return nil }
        return request
    }

    static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}

/// Parses an HTTP `Retry-After` value: delay seconds or an HTTP date (RFC 9110 IMF-fixdate).
enum RetryAfter {
    static func date(from raw: String?, now: Date) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw.allSatisfy(\.isASCIIDigit) {
            return Int(raw).map { now.addingTimeInterval(TimeInterval($0)) }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.date(from: raw)
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
