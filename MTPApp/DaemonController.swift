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
        case .requiresApproval:
            agentRegistered = false
        default:
            do {
                try service.register()
                agentRegistered = true
            } catch {
                log.error("agent register failed: \(String(describing: error), privacy: .public)")
                agentRegistered = (service.status == .enabled)
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
        case .requiresApproval:
            helperRegistered = false
        default:
            do {
                try service.register()
                helperRegistered = true
            } catch {
                log.error("helper daemon register failed: \(String(describing: error), privacy: .public)")
                helperRegistered = (service.status == .enabled)
            }
        }
    }
}
