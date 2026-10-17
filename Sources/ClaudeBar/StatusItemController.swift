import AppKit
import ClaudeBarCore
import Observation
import SwiftUI

/// Owns the status item (the two-bar icon with the Claude watermark) and its menu: the CodexBar-style
/// Claude card, the "Usage history" charts submenu, the next attempt time, the history health row,
/// Refresh, Settings… and Quit.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let coordinator: RefreshCoordinator
    private let history: HistoryStatusModel
    private let historyCharts: UsageHistoryMenuModel
    private let historySource: @MainActor () -> String?
    /// Built once and re-added on every rebuild, so a status change never replaces an open submenu.
    private lazy var historyItem = makeHistoryItem()
    private let onOpenSettings: () -> Void
    private let onQuit: () -> Void
    private var lastHistoryMessage: String?
    private var lastHistorySource: String??
    private var lastIconModel: MenuBarIconModel?

    init(
        coordinator: RefreshCoordinator,
        history: HistoryStatusModel,
        historyCharts: UsageHistoryMenuModel,
        historySource: @escaping @MainActor () -> String?,
        onOpenSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.history = history
        self.historyCharts = historyCharts
        self.historySource = historySource
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.imagePosition = .imageOnly
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        observeStatus()
    }

    private func observeStatus() {
        let (status, historyMessage, source) = withObservationTracking {
            (coordinator.status, history.health.message, self.historySource())
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeStatus() }
        }
        lastHistoryMessage = historyMessage
        // A committed URL change hides the old source's charts at once, not at the next menu open.
        if lastHistorySource != .some(source) {
            lastHistorySource = .some(source)
            reloadHistoryCharts()
        }
        render(status, historyMessage: historyMessage)
    }

    private func render(_ status: RefreshStatus, historyMessage: String?) {
        renderIcon(MenuBarIconModel(status: status))
        rebuildMenu(status, historyMessage: historyMessage)
    }

    private func renderIcon(_ model: MenuBarIconModel) {
        guard let button = statusItem.button else { return }
        if model != lastIconModel {
            lastIconModel = model
            button.image = Self.templateImage(model)
        }
        button.title = ""
        button.toolTip = model.accessibilityLabel
        button.setAccessibilityLabel(model.accessibilityLabel)
    }

    /// An 18×18 pt template image with 1× and 2× bitmaps, so neither scale is resampled.
    private static func templateImage(_ model: MenuBarIconModel) -> NSImage {
        let size = NSSize(width: MenuBarIconRenderer.sizePoints, height: MenuBarIconRenderer.sizePoints)
        let image = NSImage(size: size)
        for scale in [1, 2] {
            guard let raster = MenuBarIconRenderer.render(model, scale: scale) else { continue }
            let rep = NSBitmapImageRep(cgImage: raster.image)
            rep.size = size
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        image.accessibilityDescription = model.accessibilityLabel
        return image
    }

    private func rebuildMenu(_ status: RefreshStatus, historyMessage: String?) {
        menu.removeAllItems()
        let time: RefreshStatusText.TimeFormat = { $0.formatted(date: .omitted, time: .shortened) }

        menu.addItem(cardItem(MenuCardModel(status: status, now: Date(), time: time)))

        menu.addItem(.separator())
        menu.addItem(historyItem)
        let footer = [RefreshStatusText.timingLine(status, time: time), historyMessage].compactMap { $0 }
        footer.forEach(addInfo)

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

    /// The card in a disabled item: it shows no selection and takes no clicks.
    private func cardItem(_ model: MenuCardModel) -> NSMenuItem {
        let hosting = NSHostingView(rootView: MenuCardView(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: MenuCardLayout.width, height: 1)
        let height = ceil(hosting.fittingSize.height)
        hosting.frame = NSRect(x: 0, y: 0, width: MenuCardLayout.width, height: max(1, height))
        let item = NSMenuItem()
        item.title = ""
        item.view = hosting
        item.isEnabled = false
        return item
    }

    /// "Usage history" with one hosted chart view. The item is enabled so the series picker
    /// takes clicks; the view keeps a fixed height in every state.
    private func makeHistoryItem() -> NSMenuItem {
        let hosting = NSHostingView(rootView: UsageHistoryMenuView(model: historyCharts))
        hosting.frame = NSRect(x: 0, y: 0, width: UsageHistoryLayout.width, height: 1)
        let height = ceil(hosting.fittingSize.height)
        hosting.frame = NSRect(x: 0, y: 0, width: UsageHistoryLayout.width, height: max(1, height))
        let chartItem = NSMenuItem()
        chartItem.view = hosting
        chartItem.isEnabled = true

        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.addItem(chartItem)
        let item = NSMenuItem(title: historyCharts.isFixture ? "Usage history (fixtures)" : "Usage history",
                              action: nil, keyEquivalent: "")
        item.isEnabled = true
        item.submenu = submenu
        return item
    }

    private func reloadHistoryCharts() {
        var names: [String: String] = [:]
        for row in coordinator.status.scoped where !row.isAmbiguous {
            if let name = row.displayName { names[row.key] = name }
        }
        historyCharts.reload(source: historySource(), scopedNames: names)
    }

    private func addInfo(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    func menuWillOpen(_ menu: NSMenu) {
        coordinator.trigger(.menuOpen)
        // The submenu is reachable only through this menu: load its charts now so they are usually
        // ready by the time it opens.
        reloadHistoryCharts()
        // Countdowns are relative to now: rebuild on every open, not only on status changes.
        rebuildMenu(coordinator.status, historyMessage: lastHistoryMessage)
    }

    @objc private func refresh() { coordinator.trigger(.manualRefresh) }
    @objc private func openSettings() { onOpenSettings() }
    @objc private func quit() { onQuit() }
}
