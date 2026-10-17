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

        // `--history-fixtures` (this launch only) swaps the charts' reader for synthetic in-memory
        // data under its own source, with the charts' clock frozen at launch so the fixture windows
        // stay current. Recording still goes to the real store, which never sees fixtures.
        let useFixtures = UsageHistoryFixtures.isRequested()
        let launchDate = Date()
        let historyCharts = if useFixtures {
            UsageHistoryMenuModel(
                reader: UsageHistoryFixtures.make(now: launchDate), isFixture: true, now: { launchDate }
            )
        } else {
            UsageHistoryMenuModel(reader: historyStore, isFixture: false)
        }
        let settingsModel = settingsModel
        let historySource: @MainActor () -> String? = if useFixtures {
            { UsageHistoryFixtures.source }
        } else {
            { settingsModel.configuration.endpoint?.normalizedString }
        }
        statusItemController = StatusItemController(
            coordinator: coordinator,
            history: historyStatus,
            historyCharts: historyCharts,
            historySource: historySource,
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
