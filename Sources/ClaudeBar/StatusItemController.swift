import AppKit

/// Owns the placeholder status item and its menu (Settings…, Quit).
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let onOpenSettings: () -> Void
    private let onQuit: () -> Void

    init(onOpenSettings: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "ClaudeBar")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "ClaudeBar"
        }
        statusItem.menu = makeMenu()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit ClaudeBar", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func openSettings() { onOpenSettings() }
    @objc private func quit() { onQuit() }
}
