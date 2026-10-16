import Foundation
import Security

/// Errors from a secret store. They carry a status code, never the secret itself.
public enum SecretStoreError: Error, Equatable, Sendable {
    case readFailed(status: Int32)
    case writeFailed(status: Int32)
    case deleteFailed(status: Int32)
    case unexpectedData

    public var message: String {
        switch self {
        case let .readFailed(status): "Could not read the secret from Keychain (\(Self.describe(status)))."
        case let .writeFailed(status): "Could not save the secret to Keychain (\(Self.describe(status)))."
        case let .deleteFailed(status): "Could not remove the secret from Keychain (\(Self.describe(status)))."
        case .unexpectedData: "The Keychain item for the secret has an unexpected format."
        }
    }

    private static func describe(_ status: Int32) -> String {
        if let text = SecCopyErrorMessageString(status, nil) as String? {
            return "\(text), OSStatus \(status)"
        }
        return "OSStatus \(status)"
    }
}

/// Storage for the proxy secret.
///
/// `read()` returns `nil` only when no secret is stored; any other failure throws, so a denied
/// read is never mistaken for an empty secret.
public protocol SecretStore: Sendable {
    func read() throws(SecretStoreError) -> String?
    func write(_ secret: String) throws(SecretStoreError)
    func delete() throws(SecretStoreError)
}

/// Keychain generic-password item: service = bundle ID, account = `proxy-secret`.
public struct KeychainSecretStore: SecretStore {
    public let service: String
    public let account: String

    public init(service: String = AppIdentity.bundleID, account: String = AppIdentity.secretAccount) {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func read() throws(SecretStoreError) -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let secret = String(data: data, encoding: .utf8) else {
                throw .unexpectedData
            }
            return secret
        case errSecItemNotFound:
            return nil
        default:
            throw .readFailed(status: status)
        }
    }

    public func write(_ secret: String) throws(SecretStoreError) {
        let data = Data(secret.utf8)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = baseQuery
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw .writeFailed(status: addStatus) }
        default:
            throw .writeFailed(status: status)
        }
    }

    public func delete() throws(SecretStoreError) {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw .deleteFailed(status: status)
        }
    }
}
