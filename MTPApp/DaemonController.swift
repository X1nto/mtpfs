import FSKit
import Foundation
import Observation
import ServiceManagement
import os

private let log = Logger(subsystem: "dev.xinto.mtpfs", category: "DaemonController")

@MainActor
@Observable
final class DaemonController {
    private(set) var agentRegistered = false
    private(set) var helperRegistered = false
    private(set) var extensionEnabled = false

    private(set) var registrationError: String?

    var agentStatus: SMAppService.Status {
        SMAppService.agent(plistName: "\(MTPDaemonLabel).plist").status
    }

    var helperStatus: SMAppService.Status {
        SMAppService.daemon(plistName: "\(MTPMountHelperLabel).plist").status
    }

    func refreshStatus() {
        let status = agentStatus
        agentRegistered = (status == .enabled)

//        if #available(macOS 27.0, *) {
//            helperRegistered = true
//        } else {
        helperRegistered = (helperStatus == .enabled)
//        }

        Task {
            await refreshExtensionStatus()
        }
    }

    private func refreshExtensionStatus() async {
        let modules = try? await FSClient.shared.installedExtensions
        extensionEnabled = modules?.contains { $0.bundleIdentifier == MTPModuleBundleID && $0.isEnabled } ?? false
    }

    func registerAgent() {
        let service = SMAppService.agent(plistName: "\(MTPDaemonLabel).plist")

        switch service.status {
        case .enabled:
            agentRegistered = true
            registrationError = nil
        case .requiresApproval:
            agentRegistered = false
            registrationError = nil
        default:
            do {
                try service.register()
                agentRegistered = true
                registrationError = nil
            } catch {
                agentRegistered = false
                registrationError = "Could not register the helper: \(error.localizedDescription)"
                log.error("agent register failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func registerHelperDaemon() {
//        guard #unavailable(macOS 27.0) else {
//            helperRegistered = true
//            return
//        }

        let service = SMAppService.daemon(plistName: "\(MTPMountHelperLabel).plist")

        switch service.status {
        case .enabled:
            helperRegistered = true
            registrationError = nil
        case .requiresApproval:
            helperRegistered = false
            registrationError = nil
        default:
            do {
                try service.register()
                helperRegistered = true
                registrationError = nil
            } catch {
                helperRegistered = false
                registrationError = "Could not register the mount helper: \(error.localizedDescription)"
                log.error("helper daemon register failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
