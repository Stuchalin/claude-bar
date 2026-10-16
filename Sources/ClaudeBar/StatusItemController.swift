import AppKit
import ClaudeBarCore
import Observation

/// Owns the placeholder status item and its menu: usage rows, update and error rows, the next
/// attempt time, Refresh, Settings… and Quit. Replaced by the cards and icon of later tasks.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let coordinator: RefreshCoordinator
    private let onOpenSettings: () -> Void
    private let onQuit: () -> Void

    init(coordinator: RefreshCoordinator, onOpenSettings: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.coordinator = coordinator
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "ClaudeBar")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
        }
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        observeStatus()
    }

    private func observeStatus() {
        let status = withObservationTracking {
            coordinator.status
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeStatus() }
        }
        render(status)
    }

    private func render(_ status: RefreshStatus) {
        let title = RefreshStatusText.statusTitle(status)
        statusItem.button?.title = " " + title
        statusItem.button?.toolTip = "ClaudeBar — \(title)"
        rebuildMenu(status)
    }

    private func rebuildMenu(_ status: RefreshStatus) {
        menu.removeAllItems()
        let time: RefreshStatusText.TimeFormat = { $0.formatted(date: .omitted, time: .shortened) }

        addInfo(RefreshStatusText.metricLine(title: "Session", state: status.session, time: time))
        addInfo(RefreshStatusText.metricLine(title: "Weekly", state: status.weekly, time: time))
        for row in status.scoped {
            let title = "Weekly \(row.displayName ?? row.key)"
            addInfo(row.isAmbiguous
                ? "\(title): ambiguous (several rows share this name)"
                : RefreshStatusText.metricLine(title: title, state: row.state, time: time))
        }

        menu.addItem(.separator())
        addInfo(RefreshStatusText.updatedLine(status, time: time))
        if let error = RefreshStatusText.errorLine(status) { addInfo(error) }
        if let timing = RefreshStatusText.timingLine(status, time: time) { addInfo(timing) }

        menu.addItem(.separator())
        let refresh = NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r")
        refresh.target = self
        refresh.isEnabled = status.isConfigured && status.cooldownUntil == nil
        menu.addItem(refresh)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit ClaudeBar", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func addInfo(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    func menuWillOpen(_ menu: NSMenu) {
        coordinator.trigger(.menuOpen)
    }

    @objc private func refresh() { coordinator.trigger(.manualRefresh) }
    @objc private func openSettings() { onOpenSettings() }
    @objc private func quit() { onQuit() }
}
