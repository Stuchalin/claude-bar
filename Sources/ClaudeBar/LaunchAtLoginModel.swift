import AppKit
import Observation
import ServiceManagement

/// Launch-at-login state backed by `SMAppService.mainApp`.
@MainActor
@Observable
final class LaunchAtLoginModel {
    enum State: Equatable {
        case enabled
        case notRegistered
        case requiresApproval
        case notFound
    }

    private(set) var state: State = .notRegistered
    private(set) var errorMessage: String?

    /// Registered with the system, whether or not the user has approved it yet.
    var isOn: Bool { state == .enabled || state == .requiresApproval }

    init() {
        refresh()
    }

    func refresh() {
        state = switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        case .notRegistered: .notRegistered
        @unknown default: .notRegistered
        }
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = "Could not \(enabled ? "enable" : "disable") launch at login: \(error.localizedDescription)"
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
