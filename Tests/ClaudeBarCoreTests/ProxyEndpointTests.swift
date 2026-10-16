@testable import ClaudeBarCore
import Foundation
import Testing

@Suite("ProxyEndpoint")
struct ProxyEndpointTests {
    @Test(
        "joins the usage path to the base URL with or without a trailing slash",
        arguments: [
            ("https://proxy.example.com", "https://proxy.example.com/api/oauth/usage"),
            ("https://proxy.example.com/", "https://proxy.example.com/api/oauth/usage"),
            ("http://10.0.0.5:8080", "http://10.0.0.5:8080/api/oauth/usage"),
            ("https://example.com/claude", "https://example.com/claude/api/oauth/usage"),
            ("https://example.com/claude/", "https://example.com/claude/api/oauth/usage"),
            ("https://example.com/a/b//", "https://example.com/a/b/api/oauth/usage"),
            ("  HTTPS://Proxy.Example.COM/Prefix  ", "https://proxy.example.com/Prefix/api/oauth/usage"),
        ]
    )
    func joinsUsagePath(input: String, expected: String) throws {
        let endpoint = try ProxyEndpoint(validating: input)
        #expect(endpoint.usageURL.absoluteString == expected)
    }

    @Test(
        "normalizes scheme and host case and drops trailing slashes",
        arguments: [
            ("HTTPS://Proxy.Example.com/", "https://proxy.example.com"),
            ("https://proxy.example.com/claude/", "https://proxy.example.com/claude"),
            ("http://localhost:3000", "http://localhost:3000"),
        ]
    )
    func normalizes(input: String, expected: String) throws {
        #expect(try ProxyEndpoint(validating: input).normalizedString == expected)
    }

    @Test(
        "rejects invalid input",
        arguments: [
            ("", ProxyEndpoint.ValidationError.empty),
            ("   \n", .empty),
            ("proxy.example.com", .unsupportedScheme),
            ("ftp://proxy.example.com", .unsupportedScheme),
            ("file:///tmp/proxy", .unsupportedScheme),
            ("https://", .missingHost),
            ("https:///path", .missingHost),
            ("https://user@proxy.example.com", .containsCredentials),
            ("https://user:pass@proxy.example.com", .containsCredentials),
            ("https://proxy.example.com/?secret=x", .containsQuery),
            ("https://proxy.example.com/?", .containsQuery),
            ("https://proxy.example.com/#frag", .containsFragment),
            ("https://proxy example.com", .malformed),
        ]
    )
    func rejects(input: String, expected: ProxyEndpoint.ValidationError) {
        #expect(throws: expected) {
            try ProxyEndpoint(validating: input)
        }
    }

    @Test("flags plain HTTP as insecure", arguments: [
        ("http://proxy.example.com", true),
        ("https://proxy.example.com", false),
    ])
    func insecure(input: String, isInsecure: Bool) throws {
        #expect(try ProxyEndpoint(validating: input).isInsecure == isInsecure)
    }
}
