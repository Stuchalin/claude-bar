import Foundation

/// Why a usage fetch failed, with a user-facing hint.
///
/// claude-code-proxy mirrors upstream status and body, so 401/403/502 are ambiguous. Only the
/// proxy's own known bodies (claude-code-proxy `server.js`, request handler) map to specific
/// cases; anything else with those statuses is a generic authorization / access / server error.
public enum UsageFetchError: Error, Equatable, Sendable {
    /// No secret is stored in Keychain.
    case missingSecret
    /// Keychain refused or failed the read; never treated as an empty secret.
    case secretUnreadable(SecretStoreError)

    /// 401 with the proxy's body: the `x-proxy-secret` is missing or wrong.
    case proxySecretRejected
    /// 401 from upstream (or an unknown body): the proxy forwarded the request but was refused.
    case unauthorized
    /// 403 with the proxy's body: the proxy's access window has expired.
    case accessWindowExpired
    /// 403 with the proxy's `forbidden` body and one of its model/effort policy messages
    /// (claude-code-proxy `server.js`, `modelDecision` / `effortDecision`).
    case proxyPolicyRejected(message: String)
    /// 403 from upstream (or an unknown body).
    case forbidden
    /// 502 with the proxy's body: the proxy host has no Claude credentials.
    case proxyMissingCredentials
    /// 502 with the proxy's `bad gateway` body: the proxy could not reach Anthropic.
    case upstreamUnreachable
    /// 429. `retryAfter` comes from the `Retry-After` header (seconds or HTTP date), `nil` if absent
    /// or unparseable; the caller applies its default cooldown then.
    case rateLimited(retryAfter: Date?)
    /// Any 5xx not recognized above.
    case serverError(status: Int)
    /// A redirect to another origin (or a scheme downgrade) was refused so the secret is not sent there.
    case redirectRefused(status: Int)
    /// Any other unexpected status.
    case unexpectedStatus(Int)
    /// HTTP 200 whose body is not a usage JSON object.
    case invalidResponse
    /// The request timed out (30 s).
    case timeout
    /// Transport failure before an HTTP response (DNS, connection refused, TLS, offline, …).
    case network(URLError.Code)
    case cancelled

    /// One sentence for the menu's error row.
    public var hint: String {
        switch self {
        case .missingSecret:
            "No proxy secret is saved. Enter it in Settings."
        case let .secretUnreadable(error):
            error.message
        case .proxySecretRejected:
            "The proxy rejected the secret. Check it in Settings."
        case .unauthorized:
            "Authorization failed (HTTP 401). The proxy secret or the proxy's Claude login may be invalid."
        case .accessWindowExpired:
            "The proxy's access window has expired. Ask the proxy owner to extend it."
        case let .proxyPolicyRejected(message):
            "The proxy refused the request: \(message)"
        case .forbidden:
            "Access denied (HTTP 403) by the proxy or by Anthropic."
        case .proxyMissingCredentials:
            "The proxy has no Claude credentials. Log into Claude Code on the proxy host."
        case .upstreamUnreachable:
            "The proxy could not reach Anthropic (HTTP 502)."
        case .rateLimited:
            "Anthropic is rate limiting usage requests (HTTP 429)."
        case let .serverError(status):
            "Server error (HTTP \(status)) from the proxy or Anthropic."
        case let .redirectRefused(status):
            "The proxy redirected to another address (HTTP \(status)); not followed so the secret stays private. Check the proxy URL."
        case let .unexpectedStatus(status):
            "Unexpected response (HTTP \(status)) from the proxy."
        case .invalidResponse:
            "The proxy returned a response that is not Claude usage data. Check the proxy URL."
        case .timeout:
            "The proxy did not answer within 30 seconds."
        case .network:
            "Cannot reach the proxy. Check the URL and the network."
        case .cancelled:
            "The request was cancelled."
        }
    }

    /// Longest proxy policy message kept in the hint.
    static let maxMessageLength = 200

    /// The policy messages claude-code-proxy builds in `modelDecision` and `effortDecision`.
    static func isProxyPolicyMessage(_ message: String) -> Bool {
        let patterns = [
            #"^model '.+' is not in this proxy's allowed list$"#,
            #"^model '.+' is blocked by this proxy$"#,
            #"^effort '.+' exceeds this proxy's maximum of '.+' — lower the effort and retry$"#,
        ]
        return patterns.contains { message.range(of: $0, options: .regularExpression) != nil }
    }

    /// Maps a non-200 response to an error, recognizing the proxy's own bodies.
    static func from(status: Int, body: Data, retryAfter: Date?) -> UsageFetchError {
        let json = try? JSONDecoder().decode(JSONValue.self, from: body)
        let errorString = json?["error"]?.stringValue
        let errorObject = json?["error"]?.objectValue

        switch status {
        case 300 ..< 400:
            return .redirectRefused(status: status)
        case 401:
            return errorString == "unauthorized: missing or invalid proxy secret" ? .proxySecretRejected : .unauthorized
        case 403:
            guard json?["type"]?.stringValue == "error", errorObject?["type"]?.stringValue == "forbidden",
                  let message = errorObject?["message"]?.stringValue
            else { return .forbidden }
            if message == "access window has expired" { return .accessWindowExpired }
            guard isProxyPolicyMessage(message) else { return .forbidden }
            return .proxyPolicyRejected(message: String(message.prefix(maxMessageLength)))
        case 429:
            return .rateLimited(retryAfter: retryAfter)
        case 502:
            if errorString?.hasPrefix("no upstream credentials available") == true { return .proxyMissingCredentials }
            if errorString == "bad gateway" { return .upstreamUnreachable }
            return .serverError(status: status)
        case 500 ..< 600:
            return .serverError(status: status)
        default:
            return .unexpectedStatus(status)
        }
    }
}
