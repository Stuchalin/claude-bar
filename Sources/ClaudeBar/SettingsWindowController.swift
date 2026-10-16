import AppKit
import ClaudeBarCore
import SwiftUI

/// Owned window hosting the SwiftUI settings form.
@MainActor
final class SettingsWindowController: NSWindowController {
    private let settings: SettingsModel
    private let launchAtLogin: LaunchAtLoginModel

    init(
        settings: SettingsModel,
        launchAtLogin: LaunchAtLoginModel,
        coordinator: RefreshCoordinator,
        history: HistoryStatusModel
    ) {
        self.settings = settings
        self.launchAtLogin = launchAtLogin
        let hosting = NSHostingController(rootView: SettingsView(
            settings: settings, launchAtLogin: launchAtLogin, coordinator: coordinator, history: history
        ))
        let window = NSWindow(contentViewController: hosting)
        window.title = "ClaudeBar Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Reloads the draft and login-item state, then brings the window to the front.
    func present() {
        if window?.isVisible != true {
            settings.loadDraft()
            window?.center()
        }
        launchAtLogin.refresh()
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
