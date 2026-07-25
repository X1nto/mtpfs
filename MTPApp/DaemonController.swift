import FSKit
import Foundation
import Observation
import ServiceManagement
import os

private let log = Logger(subsystem: "dev.xinto.mtpfs", category: "DaemonController")

private let deploymentFingerprintKey = "deploymentFingerprint"

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


    private var isAgentRunning: Bool {
        agentStatus == .enabled ||
        isServiceRunning(domain: "gui/\(getuid())", label: MTPDaemonLabel)
    }

    private var isHelperRunning: Bool {
        helperStatus == .enabled ||
        isServiceRunning(domain: "system", label: MTPMountHelperLabel)
    }
    
    private func isServiceRunning(domain: String, label: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["print", "\(domain)/\(label)"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    func reconcileDeployment() async {
        let identity = DeploymentIdentity.current()
        let stored = UserDefaults.standard.string(forKey: deploymentFingerprintKey)
        let storedPath = stored.map(DeploymentIdentity.bundlePath(from:))

        let firstRun = (stored == nil)
        let pathChanged = (storedPath != nil && storedPath != identity.bundlePath)

        #if DEBUG
        let shouldReconcile = true
        let reason = "debug"
        #else
        let shouldReconcile = (stored != identity.fingerprint)
        let reason = firstRun ? "first-run" : (pathChanged ? "moved" : "updated")
        #endif

        // Persist up front so a crash mid-reconcile doesn't wedge us into a retry loop.
        UserDefaults.standard.set(identity.fingerprint, forKey: deploymentFingerprintKey)

        if !shouldReconcile {
            return
        }
        
        #if DEBUG
        log.info("reconciling deployment (\(reason, privacy: .public)) moved=\(pathChanged) path=\(identity.bundlePath, privacy: .public)")
        #endif
        
        let path = identity.bundlePath
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.xinto.mtpfs"

        await Task.detached(priority: .userInitiated) {
            let removedStale = DaemonLifecycle.reconcileLaunchServices(canonicalBundlePath: path, bundleID: bundleID)

            if pathChanged {
                DaemonLifecycle.repoint(
                    agentPlist: "\(MTPDaemonLabel).plist",
                    daemonPlist: "\(MTPMountHelperLabel).plist"
                )
                DaemonLifecycle.restartFSKitAgent()
            } else if !firstRun {
                DaemonLifecycle.restartAgent(label: MTPDaemonLabel)
                if removedStale {
                    DaemonLifecycle.restartFSKitAgent()
                }
            }
        }.value
    }

    func resetToFirstInstall() async {
        log.info("developer reset: deregistering daemons")
        UserDefaults.standard.removeObject(forKey: deploymentFingerprintKey)

        await Task.detached(priority: .userInitiated) {
            DaemonLifecycle.deregisterAll(
                agentPlist: "\(MTPDaemonLabel).plist",
                daemonPlist: "\(MTPMountHelperLabel).plist"
            )
        }.value

        agentRegistered = false
        helperRegistered = false
        refreshStatus()
    }

    func refreshStatus() {
        agentRegistered = isAgentRunning
        helperRegistered = isHelperRunning

        Task {
            await refreshExtensionStatus()
        }
    }

    private func refreshExtensionStatus() async {
        let modules = try? await FSClient.shared.installedExtensions
        extensionEnabled = modules?.contains { $0.bundleIdentifier == MTPModuleBundleID && $0.isEnabled } ?? false
    }

    func registerAgent() {
        guard !isAgentRunning else {
            agentRegistered = true
            return
        }

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
        guard !isHelperRunning else {
            helperRegistered = true
            return
        }

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
