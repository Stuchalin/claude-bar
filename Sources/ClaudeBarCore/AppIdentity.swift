/// Identifiers shared by the app, its Keychain item and the packaging script.
public enum AppIdentity {
    /// Bundle identifier written into Info.plist by `Scripts/package_app.sh`.
    /// Also the Keychain service name, so it stays the same when the binary runs unbundled.
    public static let bundleID = "ru.sdfpro.ClaudeBar"

    /// Keychain account under which the proxy secret is stored.
    public static let secretAccount = "proxy-secret"
}
