import ClaudeBarCore
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: SettingsModel
    let launchAtLogin: LaunchAtLoginModel
    let coordinator: RefreshCoordinator
    let history: HistoryStatusModel

    var body: some View {
        Form {
            Section("Proxy") {
                TextField("Proxy URL", text: $settings.draftURL, prompt: Text("https://proxy.example.com"))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                SecureField("Secret", text: $settings.draftSecret)
                if let warning = settings.insecureDraftWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if let readError = settings.secretReadError {
                    Label(readError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section("General") {
                Picker("Refresh", selection: $settings.refreshInterval) {
                    ForEach(RefreshInterval.allCases) { interval in
                        Text(interval.title).tag(interval)
                    }
                }
                LaunchAtLoginRow(model: launchAtLogin)
            }

            Section("Connection") {
                ConnectionRow(coordinator: coordinator)
            }

            Section("History") {
                HistoryRow(history: history)
            }

            Section {
                HStack {
                    if let error = settings.errorMessage {
                        Label(error, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                    } else if let status = settings.statusMessage {
                        Label(status, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Spacer()
                    Button("Save") { settings.save() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Check connection against the committed settings, with the coordinator's current result.
private struct ConnectionRow: View {
    let coordinator: RefreshCoordinator

    var body: some View {
        let status = coordinator.status
        HStack {
            statusLabel(status)
            Spacer()
            Button("Check connection") { coordinator.trigger(.checkConnection) }
                .disabled(!status.isConfigured || status.connection == .loading || status.cooldownUntil != nil)
        }
        if let cooldown = status.cooldownUntil {
            Text("Rate limited. Cooldown ends at \(cooldown.formatted(date: .omitted, time: .shortened)).")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func statusLabel(_ status: RefreshStatus) -> some View {
        switch status.connection {
        case _ where !status.isConfigured:
            Text("Save the proxy URL and secret first.")
                .foregroundStyle(.secondary)
        case .idle:
            Text("Not checked yet.")
                .foregroundStyle(.secondary)
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…")
            }
        case .succeeded:
            Label("Connected.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .failed(error):
            Label(error.hint, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }
}

/// History storage state and Clear history with a confirmation.
private struct HistoryRow: View {
    let history: HistoryStatusModel
    @State private var isConfirming = false

    var body: some View {
        HStack {
            if let message = history.health.message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if let clearMessage = history.clearMessage {
                Text(clearMessage)
                    .foregroundStyle(.secondary)
            } else {
                Text("Usage history is kept for one year on this Mac.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Clear history…") { isConfirming = true }
                .disabled(!history.canClear)
        }
        .confirmationDialog("Clear usage history?", isPresented: $isConfirming) {
            Button("Clear history", role: .destructive) { history.clearHistory() }
        } message: {
            Text("This deletes every recorded observation. Current usage is not affected.")
        }
    }
}

private struct LaunchAtLoginRow: View {
    let model: LaunchAtLoginModel

    var body: some View {
        Toggle("Launch at login", isOn: Binding(get: { model.isOn }, set: { model.setEnabled($0) }))
        switch model.state {
        case .enabled, .notRegistered:
            EmptyView()
        case .requiresApproval:
            VStack(alignment: .leading, spacing: 6) {
                Text("Registered, but macOS needs your approval in System Settings → General → Login Items.")
                    .foregroundStyle(.secondary)
                Button("Open System Settings") { model.openSystemSettings() }
            }
        case .notFound:
            Text("macOS cannot find ClaudeBar as a login item. Install it to /Applications with Homebrew (`brew install --cask stuchalin/claude-bar/claudebar`) or `make install`, then launch it from there.")
                .foregroundStyle(.secondary)
        }
        if let error = model.errorMessage {
            Label(error, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }
}
