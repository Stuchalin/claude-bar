import ClaudeBarCore
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: SettingsModel
    let launchAtLogin: LaunchAtLoginModel

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
                LaunchAtLoginRow(model: launchAtLogin)
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
            Text("macOS cannot find ClaudeBar as a login item. Install it with `make install` and launch it from ~/Applications.")
                .foregroundStyle(.secondary)
        }
        if let error = model.errorMessage {
            Label(error, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }
}
