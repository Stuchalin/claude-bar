import Foundation

/// One usage fetch against a proxy endpoint; the coordinator's transport seam.
public protocol UsageFetching: Sendable {
    func fetchUsage(endpoint: ProxyEndpoint) async throws(UsageFetchError) -> UsageSnapshot
}

/// Production fetcher: reads the secret from the store on every attempt, then calls `UsageClient`.
public struct ProxyUsageFetcher: UsageFetching {
    private let client: UsageClient
    private let secrets: any SecretStore

    public init(client: UsageClient = UsageClient(), secrets: any SecretStore) {
        self.client = client
        self.secrets = secrets
    }

    public func fetchUsage(endpoint: ProxyEndpoint) async throws(UsageFetchError) -> UsageSnapshot {
        try await client.fetchUsage(endpoint: endpoint, secrets: secrets)
    }
}
