@testable import ClaudeBarCore
import Foundation
import Testing

@Suite("SettingsStore")
struct SettingsStoreTests {
    @Test("persists the proxy URL across store instances over the same defaults")
    func persistsURL() throws {
        let isolated = IsolatedDefaults()
        let store = SettingsStore(defaults: isolated.defaults)
        #expect(store.proxyURL == nil)
        #expect(store.proxyEndpoint == nil)

        store.proxyURL = "https://proxy.example.com/claude"

        let reopened = SettingsStore(defaults: isolated.defaults)
        #expect(reopened.proxyURL == "https://proxy.example.com/claude")
        let endpoint = try #require(reopened.proxyEndpoint)
        #expect(endpoint.usageURL.absoluteString == "https://proxy.example.com/claude/api/oauth/usage")

        reopened.proxyURL = nil
        #expect(SettingsStore(defaults: isolated.defaults).proxyURL == nil)
    }

    @Test("an invalid stored value yields no endpoint")
    func invalidStoredValue() {
        let isolated = IsolatedDefaults()
        isolated.defaults.set("https://user:pw@proxy.example.com", forKey: SettingsStore.Key.proxyURL)
        #expect(SettingsStore(defaults: isolated.defaults).proxyEndpoint == nil)
    }
}

@MainActor
@Suite("SettingsModel")
struct SettingsModelTests {
    @Test("saving persists the URL and round-trips the secret through the store")
    func saveRoundTrip() throws {
        let isolated = IsolatedDefaults()
        let secrets = InMemorySecretStore()
        let model = SettingsModel(settings: SettingsStore(defaults: isolated.defaults), secrets: secrets)
        model.loadDraft()
        #expect(model.draftSecret.isEmpty)
        #expect(model.secretReadError == nil)

        model.draftURL = "https://Proxy.example.com/"
        model.draftSecret = Fixture.dummy + "\n"
        #expect(model.save())

        #expect(model.errorMessage == nil)
        #expect(model.statusMessage != nil)
        #expect(secrets.storedSecret == Fixture.dummy)
        #expect(model.committedEndpoint?.normalizedString == "https://proxy.example.com")

        let reopened = SettingsModel(settings: SettingsStore(defaults: isolated.defaults), secrets: secrets)
        #expect(reopened.committedEndpoint?.normalizedString == "https://proxy.example.com")
        reopened.loadDraft()
        #expect(reopened.draftURL == "https://proxy.example.com")
        #expect(reopened.draftSecret == Fixture.dummy)
    }

    @Test("an unchanged secret is not rewritten")
    func unchangedSecretNotRewritten() {
        let isolated = IsolatedDefaults()
        let secrets = InMemorySecretStore(secret: Fixture.dummy)
        let model = SettingsModel(settings: SettingsStore(defaults: isolated.defaults), secrets: secrets)
        model.loadDraft()
        model.draftURL = "https://proxy.example.com"
        #expect(model.save())
        #expect(secrets.writeCount == 0)

        model.draftSecret = Fixture.other
        #expect(model.save())
        #expect(secrets.writeCount == 1)
        #expect(secrets.storedSecret == Fixture.other)
    }

    @Test("a failing secret write keeps the draft and leaves committed settings intact")
    func failingWriteLeavesPriorSettings() {
        let isolated = IsolatedDefaults()
        let settings = SettingsStore(defaults: isolated.defaults)
        settings.proxyURL = "https://old.example.com"
        let model = SettingsModel(settings: settings, secrets: ThrowingSecretStore(readError: nil))
        model.loadDraft()

        model.draftURL = "https://new.example.com"
        model.draftSecret = Fixture.dummy
        #expect(!model.save())

        #expect(model.errorMessage == SecretStoreError.writeFailed(status: -25293).message)
        #expect(model.statusMessage == nil)
        #expect(model.draftURL == "https://new.example.com")
        #expect(model.draftSecret == Fixture.dummy)
        #expect(settings.proxyURL == "https://old.example.com")
        #expect(model.committedEndpoint?.normalizedString == "https://old.example.com")
    }

    @Test("an invalid URL is rejected before any secret mutation")
    func invalidURLRejectedFirst() {
        let isolated = IsolatedDefaults()
        let settings = SettingsStore(defaults: isolated.defaults)
        let secrets = InMemorySecretStore()
        let model = SettingsModel(settings: settings, secrets: secrets)
        model.draftURL = "https://proxy.example.com/?secret=x"
        model.draftSecret = Fixture.dummy

        #expect(!model.save())
        #expect(model.errorMessage == ProxyEndpoint.ValidationError.containsQuery.message)
        #expect(secrets.writeCount == 0)
        #expect(settings.proxyURL == nil)
        #expect(model.committedEndpoint == nil)
    }

    @Test("a denied read is reported and never treated as an empty secret")
    func deniedReadIsNotEmptySecret() {
        let isolated = IsolatedDefaults()
        let settings = SettingsStore(defaults: isolated.defaults)
        settings.proxyURL = "https://old.example.com"
        let model = SettingsModel(settings: settings, secrets: ThrowingSecretStore(writeError: nil))
        model.loadDraft()

        #expect(model.secretReadError == SecretStoreError.readFailed(status: -25293).message)
        #expect(model.draftSecret.isEmpty)

        model.draftURL = "https://new.example.com"
        #expect(!model.save())
        #expect(model.errorMessage != nil)
        #expect(settings.proxyURL == "https://old.example.com")
    }

    @Test("the insecure warning follows the draft scheme")
    func insecureWarning() {
        let isolated = IsolatedDefaults()
        let model = SettingsModel(settings: SettingsStore(defaults: isolated.defaults), secrets: InMemorySecretStore())
        model.draftURL = "http://proxy.example.com"
        #expect(model.insecureDraftWarning != nil)
        model.draftURL = "https://proxy.example.com"
        #expect(model.insecureDraftWarning == nil)
        model.draftURL = "not a url"
        #expect(model.insecureDraftWarning == nil)
    }
}
