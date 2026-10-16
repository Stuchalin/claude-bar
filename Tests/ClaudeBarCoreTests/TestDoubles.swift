import ClaudeBarCore
import Foundation

/// Placeholder secret values for tests; never real credentials.
enum Fixture {
    static let dummy = "dummy-secret"
    static let other = "other-secret"
}

/// Secret store that keeps the secret in memory and counts mutations.
final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secret: String?
    private var writes = 0

    init(secret: String? = nil) {
        self.secret = secret
    }

    var writeCount: Int { lock.withLock { writes } }
    var storedSecret: String? { lock.withLock { secret } }

    func read() throws(SecretStoreError) -> String? {
        lock.withLock { secret }
    }

    func write(_ secret: String) throws(SecretStoreError) {
        lock.withLock {
            self.secret = secret
            writes += 1
        }
    }

    func delete() throws(SecretStoreError) {
        lock.withLock { secret = nil }
    }
}

/// Secret store whose operations fail with the configured errors.
struct ThrowingSecretStore: SecretStore {
    var readError: SecretStoreError? = .readFailed(status: -25293)
    var writeError: SecretStoreError? = .writeFailed(status: -25293)
    var deleteError: SecretStoreError? = .deleteFailed(status: -25293)

    func read() throws(SecretStoreError) -> String? {
        if let readError { throw readError }
        return nil
    }

    func write(_ secret: String) throws(SecretStoreError) {
        if let writeError { throw writeError }
    }

    func delete() throws(SecretStoreError) {
        if let deleteError { throw deleteError }
    }
}

/// A `UserDefaults` suite unique to one test, removed when the value is released.
///
/// The suite is addressed by an absolute path in the temporary directory, so cfprefsd's
/// asynchronous writes never leave files in ~/Library/Preferences.
final class IsolatedDefaults {
    let suiteName = FileManager.default.temporaryDirectory
        .appending(path: "ClaudeBarCoreTests.\(UUID().uuidString)").path
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(atPath: suiteName + ".plist")
    }
}
