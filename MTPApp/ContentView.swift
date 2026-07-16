import FSKit
import ServiceManagement
import SwiftUI

private enum WizardState {
    case registerHelper
    case registerMountHelper
    case enableExtension
    case done
}

struct ContentView: View {
    @State private var daemon = DaemonController()
    @State private var helperStepWasRequired = false

    private var wizardState: WizardState {
        if daemon.agentRegistered && daemon.helperRegistered && daemon.extensionEnabled {
            return .done
        }
        if daemon.agentRegistered && daemon.helperRegistered {
            return .enableExtension
        }
        if daemon.agentRegistered {
            return .registerMountHelper
        }
        return .registerHelper
    }

    var body: some View {
        _ContentView(
            state: wizardState,
            error: daemon.registrationError,
            agentStatus: daemon.agentStatus,
            helperStatus: daemon.helperStatus,
            helperStepWasRequired: helperStepWasRequired
        )
        .frame(minWidth: 420, minHeight: 300)
        .onAppear {
            daemon.registerAgent()
            daemon.registerHelperDaemon()
            daemon.refreshStatus()
        }
        .onChange(of: wizardState) { _, newValue in
            if newValue == .registerMountHelper {
                helperStepWasRequired = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            daemon.refreshStatus()
        }
    }

}

private struct _ContentView: View {

    let state: WizardState
    let error: String?
    let agentStatus: SMAppService.Status
    let helperStatus: SMAppService.Status
    let helperStepWasRequired: Bool

    private var extensionStepNumber: Int {
        helperStepWasRequired ? 3 : 2
    }

    var body: some View {
        VStack(alignment: .center) {
            switch state {
            case .registerHelper:
                StepView(
                    number: 1,
                    title: "Register background helper",
                    description: "MTPFS needs a background service to watch for connected phones and mount them automatically."
                ) {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                    } else if agentStatus == .requiresApproval {
                        VStack(spacing: 12) {
                            Text("Open Login Items and enable **MTPFS**.")
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button("Open Login Items") {
                                SMAppService.openSystemSettingsLoginItems()
                            }
                        }
                    }
                }

            case .registerMountHelper:
                StepView(
                    number: 2,
                    title: "Register mount helper",
                    description: "MTPFS needs a privileged helper to create mount points in /Volumes."
                ) {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                    } else if helperStatus == .requiresApproval {
                        VStack(spacing: 12) {
                            Text("Open Login Items and enable **MTPFS**.")
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button("Open Login Items") {
                                SMAppService.openSystemSettingsLoginItems()
                            }
                        }
                    }
                }

            case .enableExtension:
                StepView(
                    number: extensionStepNumber,
                    title: "Enable file system extension",
                    description: "Allow the \"mtp\" extension to run. macOS requires your explicit approval in System Settings."
                ) {
                    VStack(spacing: 12) {
                        Text("Open File System Extensions, then turn on the \"mtp\" extension.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Open File System Extensions") {
                            openFileSystemExtensionsSettings()
                        }
                    }
                }

            case .done:
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.green)
                    Text("Setup complete")
                        .font(.title2).bold()
                    Text("Try plugging in your phone.\nYou can close this window.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(32)
            }
        }
    }

    private func openFileSystemExtensionsSettings() {
        if #available(macOS 27.0, *) {
            FSClient.shared.openFileSystemExtensionsSettings()
        } else {
            let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences")!
            NSWorkspace.shared.open(url)
        }
    }
}

private struct StepView<Content: View>: View {
    let number: Int
    let title: String
    let description: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(.blue)
                        .frame(width: 32, height: 32)
                    Text("\(number)")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            content()
        }
        .padding(24)
    }
}

#Preview("Step 1 - Requires Approval") {
    _ContentView(state: .registerHelper, error: nil, agentStatus: .requiresApproval, helperStatus: .notRegistered, helperStepWasRequired: false)
        .frame(width: 420, height: 300)
}

#Preview("Step 1 - Error") {
    _ContentView(state: .registerHelper, error: "Registration failed. Check System Settings.", agentStatus: .notRegistered, helperStatus: .notRegistered, helperStepWasRequired: false)
        .frame(width: 420, height: 300)
}

#Preview("Step 2 - Requires Approval") {
    _ContentView(state: .registerMountHelper, error: nil, agentStatus: .enabled, helperStatus: .requiresApproval, helperStepWasRequired: true)
        .frame(width: 420, height: 300)
}

#Preview("Step 2 - Error") {
    _ContentView(state: .registerMountHelper, error: "Helper registration failed.", agentStatus: .enabled, helperStatus: .notRegistered, helperStepWasRequired: true)
        .frame(width: 420, height: 300)
}

#Preview("Step 3 - Enable Extension") {
    _ContentView(state: .enableExtension, error: nil, agentStatus: .enabled, helperStatus: .enabled, helperStepWasRequired: true)
        .frame(width: 420, height: 300)
}

#Preview("Step 2 (skipped helper) - Enable Extension") {
    _ContentView(state: .enableExtension, error: nil, agentStatus: .enabled, helperStatus: .enabled, helperStepWasRequired: false)
        .frame(width: 420, height: 300)
}

#Preview("Done") {
    _ContentView(state: .done, error: nil, agentStatus: .enabled, helperStatus: .enabled, helperStepWasRequired: false)
        .frame(width: 420, height: 300)
}
