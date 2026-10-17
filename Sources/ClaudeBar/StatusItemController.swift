import AppKit
import ClaudeBarCore
import Observation
import SwiftUI

/// Owns the status item (the two-bar icon with the Claude watermark) and its menu: the CodexBar-style
/// Claude card, the next attempt time, the history health row, Refresh, Settings… and Quit.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let coordinator: RefreshCoordinator
    private let history: HistoryStatusModel
    private let onOpenSettings: () -> Void
    private let onQuit: () -> Void
    private var lastHistoryMessage: String?
    private var lastIconModel: MenuBarIconModel?

    init(
        coordinator: RefreshCoordinator,
        history: HistoryStatusModel,
        onOpenSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.history = history
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
        let (status, historyMessage) = withObservationTracking {
            (coordinator.status, history.health.message)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeStatus() }
        }
        lastHistoryMessage = historyMessage
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

        let footer = [RefreshStatusText.timingLine(status, time: time), historyMessage].compactMap { $0 }
        if !footer.isEmpty {
            menu.addItem(.separator())
            footer.forEach(addInfo)
        }

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

    private func addInfo(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    func menuWillOpen(_ menu: NSMenu) {
        coordinator.trigger(.menuOpen)
        // Countdowns are relative to now: rebuild on every open, not only on status changes.
        rebuildMenu(coordinator.status, historyMessage: lastHistoryMessage)
    }

    @objc private func refresh() { coordinator.trigger(.manualRefresh) }
    @objc private func openSettings() { onOpenSettings() }
    @objc private func quit() { onQuit() }
}
