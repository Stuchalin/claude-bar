import Foundation

/// Non-secret settings persisted in `UserDefaults`. The secret lives only in a `SecretStore`.
public final class SettingsStore {
    enum Key {
        static let proxyURL = "proxyURL"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The committed proxy base URL, as `ProxyEndpoint.normalizedString`.
    public var proxyURL: String? {
        get { defaults.string(forKey: Key.proxyURL) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.proxyURL)
            } else {
                defaults.removeObject(forKey: Key.proxyURL)
            }
        }
    }

    /// The committed endpoint, or `nil` when none is stored or the stored value no longer validates.
    public var proxyEndpoint: ProxyEndpoint? {
        proxyURL.flatMap { try? ProxyEndpoint(validating: $0) }
    }
}
