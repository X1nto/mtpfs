import AppKit
import Foundation
import Security
import ServiceManagement
import os

private let log = Logger(subsystem: "dev.xinto.mtpfs", category: "DaemonLifecycle")

struct DeploymentIdentity: Equatable {
    let bundlePath: String
    let codeIdentity: String

    var fingerprint: String {
        "\(bundlePath)\u{1}\(codeIdentity)"
    }

    static func current() -> DeploymentIdentity {
        let url = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        return DeploymentIdentity(
            bundlePath: url.path,
            codeIdentity: cdHash(of: url) ?? fallbackIdentity()
        )
    }

    static func bundlePath(from fingerprint: String) -> String {
        String(fingerprint.prefix { $0 != "\u{1}" })
    }

    private static func cdHash(of bundleURL: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &code) == errSecSuccess,
              let code
        else {
            return nil
        }
        var infoCF: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &infoCF) == errSecSuccess,
              let info = infoCF as? [String: Any],
              let hash = info[kSecCodeInfoUnique as String] as? Data
        else {
            return nil
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private static func fallbackIdentity() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        var mtime: TimeInterval = 0
        if let exec = Bundle.main.executableURL,
           let date = try? exec.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        {
            mtime = date.timeIntervalSince1970
        }
        return "v\(version)+m\(Int(mtime))"
    }
}

enum DaemonLifecycle {

    private static let lsregister = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister")
    private static let launchctl = URL(fileURLWithPath: "/bin/launchctl")
    private static let pkill = URL(fileURLWithPath: "/usr/bin/pkill")

    /// - Returns: `true` if a stale copy was found and removed.
    @discardableResult
    static func reconcileLaunchServices(canonicalBundlePath: String, bundleID: String) -> Bool {
        let canonical = URL(fileURLWithPath: canonicalBundlePath).resolvingSymlinksInPath().standardizedFileURL
        let stale = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID)
            .map { $0.resolvingSymlinksInPath().standardizedFileURL }
            .filter { $0.path != canonical.path }

        if stale.isEmpty {
            return false
        }

        for url in stale {
            run(lsregister, ["-u", url.path])
        }
        
        run(lsregister, ["-f", canonical.path])
        return true
    }

    static func restartAgent(label: String) {
        let target = "gui/\(getuid())/\(label)"
        run(launchctl, ["kickstart", "-k", target])
    }

    static func restartFSKitAgent() {
        run(pkill, ["-x", "fskit_agent"])
    }

    static func deregisterAll(agentPlist: String, daemonPlist: String) {
        try? SMAppService.agent(plistName: agentPlist).unregister()
        try? SMAppService.daemon(plistName: daemonPlist).unregister()
    }
    
    @discardableResult
    private static func run(_ tool: URL, _ args: [String]) -> Int32? {
        guard FileManager.default.isExecutableFile(atPath: tool.path) else {
            log.error("tool missing: \(tool.path, privacy: .public)")
            return nil
        }
        let task = Process()
        task.executableURL = tool
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            log.error("\(tool.lastPathComponent, privacy: .public) failed to launch: \(String(describing: error), privacy: .public)")
            return nil
        }
        task.waitUntilExit()
        return task.terminationStatus
    }
}
