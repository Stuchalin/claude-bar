import Foundation

/// A validated claude-code-proxy base URL.
///
/// Accepts `http` and `https` only, rejects credentials, queries and fragments, and keeps an
/// optional path prefix (for a proxy mounted below `/`). The usage endpoint is joined to that
/// prefix by path components, so a trailing slash on the base URL makes no difference.
public struct ProxyEndpoint: Hashable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case empty
        case malformed
        case unsupportedScheme
        case missingHost
        case containsCredentials
        case containsQuery
        case containsFragment

        public var message: String {
            switch self {
            case .empty: "Enter the proxy URL."
            case .malformed: "The proxy URL is not a valid URL."
            case .unsupportedScheme: "The proxy URL must start with http:// or https://."
            case .missingHost: "The proxy URL has no host."
            case .containsCredentials: "Remove the user name and password from the proxy URL; the secret goes in the Secret field."
            case .containsQuery: "Remove the query (?…) from the proxy URL."
            case .containsFragment: "Remove the fragment (#…) from the proxy URL."
            }
        }
    }

    /// Path components appended to the base URL to reach the usage endpoint.
    static let usagePathComponents = ["api", "oauth", "usage"]

    /// The normalized base URL: lowercased scheme and host, no trailing slash.
    public let baseURL: URL

    /// `true` for `http`, where the secret travels unencrypted.
    public var isInsecure: Bool { baseURL.scheme == "http" }

    /// The normalized base URL as stored in settings.
    public var normalizedString: String { baseURL.absoluteString }

    /// `{base}/api/oauth/usage`.
    public var usageURL: URL { appending(pathComponents: Self.usagePathComponents) }

    public init(validating input: String) throws(ValidationError) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .empty }
        guard var components = URLComponents(string: trimmed) else { throw .malformed }

        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw .unsupportedScheme
        }
        guard let host = components.host, !host.isEmpty else { throw .missingHost }
        guard components.user == nil, components.password == nil else { throw .containsCredentials }
        guard components.query == nil else { throw .containsQuery }
        guard components.fragment == nil else { throw .containsFragment }

        components.scheme = scheme
        components.host = host.lowercased()
        components.percentEncodedPath = Self.trimmingTrailingSlashes(components.percentEncodedPath)

        guard let url = components.url else { throw .malformed }
        baseURL = url
    }

    /// Joins percent-encoded-safe path components (no slashes inside a component) to the base path.
    func appending(pathComponents: [String]) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let prefix = components.percentEncodedPath
        components.percentEncodedPath = ([prefix] + pathComponents).joined(separator: "/")
        return components.url!
    }

    private static func trimmingTrailingSlashes(_ path: String) -> String {
        var path = Substring(path)
        while path.hasSuffix("/") { path = path.dropLast() }
        return String(path)
    }
}
