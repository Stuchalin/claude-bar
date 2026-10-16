import AppKit
import ClaudeBarCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsModel = SettingsModel(settings: SettingsStore(), secrets: KeychainSecretStore())
    private let launchAtLogin = LaunchAtLoginModel()
    private var settingsWindowController: SettingsWindowController?
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        statusItemController = StatusItemController(
            onOpenSettings: { [weak self] in self?.openSettings() },
            onQuit: { NSApp.terminate(nil) }
        )
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        launchAtLogin.refresh()
    }

    private func openSettings() {
        let controller = settingsWindowController
            ?? SettingsWindowController(settings: settingsModel, launchAtLogin: launchAtLogin)
        settingsWindowController = controller
        controller.present()
    }
}
