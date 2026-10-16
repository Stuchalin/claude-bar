import Foundation
import Observation

/// Draft and committed proxy settings behind the Settings window.
///
/// Save validates the draft, mutates the secret store first and only on success persists and
/// publishes the new URL. A failed save keeps the draft and leaves the committed settings untouched.
@MainActor
@Observable
public final class SettingsModel {
    public var draftURL = ""
    public var draftSecret = ""

    /// Inline error from the last save attempt.
    public private(set) var errorMessage: String?
    /// Set when the stored secret could not be read; the field is then left empty, not "no secret".
    public private(set) var secretReadError: String?
    /// Confirmation after a successful save, cleared on the next attempt or reload.
    public private(set) var statusMessage: String?
    /// The URL that the rest of the app uses; changes only on a successful save.
    public private(set) var committedEndpoint: ProxyEndpoint?

    private enum StoredSecret: Equatable {
        case unknown
        case missing
        case present(String)
    }

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private var storedSecret = StoredSecret.unknown

    public init(settings: SettingsStore, secrets: any SecretStore) {
        self.settings = settings
        self.secrets = secrets
        committedEndpoint = settings.proxyEndpoint
    }

    /// Warning shown while the draft URL is a valid plain-HTTP URL.
    public var insecureDraftWarning: String? {
        guard let endpoint = try? ProxyEndpoint(validating: draftURL), endpoint.isInsecure else { return nil }
        return "This URL uses plain HTTP: the secret travels unencrypted."
    }

    /// Resets the draft from the committed settings and the secret store.
    public func loadDraft() {
        errorMessage = nil
        statusMessage = nil
        draftURL = settings.proxyURL ?? ""
        do {
            if let secret = try secrets.read() {
                storedSecret = .present(secret)
                draftSecret = secret
            } else {
                storedSecret = .missing
                draftSecret = ""
            }
            secretReadError = nil
        } catch {
            storedSecret = .unknown
            draftSecret = ""
            secretReadError = error.message
        }
    }

    /// Commits the draft. Returns `true` on success; on failure `errorMessage` says why.
    @discardableResult
    public func save() -> Bool {
        errorMessage = nil
        statusMessage = nil

        let endpoint: ProxyEndpoint
        do {
            endpoint = try ProxyEndpoint(validating: draftURL)
        } catch {
            errorMessage = error.message
            return false
        }

        let secret = draftSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else {
            errorMessage = "Enter the proxy secret."
            return false
        }

        if storedSecret != .present(secret) {
            do {
                try secrets.write(secret)
            } catch {
                errorMessage = error.message
                return false
            }
            storedSecret = .present(secret)
        }
        secretReadError = nil

        settings.proxyURL = endpoint.normalizedString
        draftURL = endpoint.normalizedString
        draftSecret = secret
        committedEndpoint = endpoint
        statusMessage = "Saved."
        return true
    }
}
