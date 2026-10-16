import AppKit

// AppKit entry point: a menu bar accessory app with no Dock icon and no SwiftUI `App`.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
