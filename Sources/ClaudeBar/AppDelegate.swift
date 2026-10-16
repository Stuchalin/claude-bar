import AppKit
import ClaudeBarCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let secrets = KeychainSecretStore()
    private lazy var settingsModel = SettingsModel(settings: SettingsStore(), secrets: secrets)
    private let launchAtLogin = LaunchAtLoginModel()
    private let historyStatus = HistoryStatusModel()
    private var historyStore: HistoryStore?
    private var coordinator: RefreshCoordinator?
    private var settingsWindowController: SettingsWindowController?
    private var statusItemController: StatusItemController?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()

        let historyStore = HistoryStore(onHealthChange: historyStatus.healthSink())
        historyStatus.attach(historyStore)
        self.historyStore = historyStore

        let configuration = settingsModel.configuration
        let coordinator = RefreshCoordinator(
            fetcher: ProxyUsageFetcher(secrets: secrets),
            history: historyStore,
            endpoint: configuration.endpoint,
            secretRevision: configuration.secretRevision,
            interval: configuration.interval
        )
        coordinator.bind(to: settingsModel)
        self.coordinator = coordinator
        statusItemController = StatusItemController(
            coordinator: coordinator,
            history: historyStatus,
            onOpenSettings: { [weak self] in self?.openSettings() },
            onQuit: { NSApp.terminate(nil) }
        )
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.coordinator?.trigger(.wake) }
        }
        coordinator.start()
        coordinator.trigger(.launch)
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
        historyStore?.close()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        launchAtLogin.refresh()
    }

    private func openSettings() {
        guard let coordinator else { return }
        let controller = settingsWindowController
            ?? SettingsWindowController(
                settings: settingsModel, launchAtLogin: launchAtLogin, coordinator: coordinator, history: historyStatus
            )
        settingsWindowController = controller
        controller.present()
    }
}
