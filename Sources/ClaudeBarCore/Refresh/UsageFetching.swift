import Foundation

/// One usage fetch against a proxy endpoint; the coordinator's transport seam.
///
/// An attempt is split in two so its secret belongs to the same configuration generation as its
/// endpoint: the coordinator calls `readSecret()` on the main actor when the attempt starts, then
/// passes the result to `fetchUsage(endpoint:secret:)`. A secret saved later never reaches an
/// attempt that started against the previous URL.
public protocol UsageFetching: Sendable {
    func readSecret() throws(UsageFetchError) -> String
    func fetchUsage(endpoint: ProxyEndpoint, secret: String) async throws(UsageFetchError) -> UsageSnapshot
}

/// Production fetcher: reads the secret from the store at the start of every attempt, then calls
/// `UsageClient`.
public struct ProxyUsageFetcher: UsageFetching {
    private let client: UsageClient
    private let secrets: any SecretStore

    public init(client: UsageClient = UsageClient(), secrets: any SecretStore) {
        self.client = client
        self.secrets = secrets
    }

    public func readSecret() throws(UsageFetchError) -> String {
        try UsageClient.readSecret(from: secrets)
    }

    public func fetchUsage(endpoint: ProxyEndpoint, secret: String) async throws(UsageFetchError) -> UsageSnapshot {
        try await client.fetchUsage(endpoint: endpoint, secret: secret)
    }
}
