import Foundation
import os

private let log = Logger(subsystem: "dev.xinto.mtpfs.mtphelperd", category: "Helper")

final class MTPMountHelperServer: NSObject, MTPMountHelperProtocol, NSXPCListenerDelegate {

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        do {
            try connection.setCodeSigningRequirement(MTPClientCodeRequirement)
        } catch {
            log.error("code-signing check setup failed: \(String(describing: error), privacy: .public)")
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: MTPMountHelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func prepareMountpoint(name: String, reply: @escaping (String?, Error?) -> Void) {
        guard !name.isEmpty, !name.contains("/"), !name.contains(".."), name != "." else {
            reply(nil, POSIXError(.EINVAL))
            return
        }

        guard let connection = NSXPCConnection.current() else {
            reply(nil, POSIXError(.EPERM))
            return
        }
        let callerUID = connection.effectiveUserIdentifier
        let callerGID = connection.effectiveGroupIdentifier

        let path = "/Volumes/\(name)"

        guard Darwin.mkdir(path, 0o755) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EPERM
            log.error("mkdir(\(path, privacy: .public)) failed: \(String(cString: strerror(errno)), privacy: .public)")
            reply(nil, POSIXError(code))
            return
        }

        if Darwin.lchown(path, callerUID, callerGID) != 0 {
            // non-fatal, mounting still works
            log.error("chown(\(path, privacy: .public)) failed: \(String(cString: strerror(errno)), privacy: .public)")
        }

        log.info("prepared mountpoint \(path, privacy: .public) for uid=\(callerUID)")
        reply(path, nil)
    }

    func removeMountpoint(path: String, reply: @escaping (Error?) -> Void) {
        let parent = (path as NSString).deletingLastPathComponent
        let base = (path as NSString).lastPathComponent
        guard parent == "/Volumes", !base.isEmpty, !base.contains("/") else {
            reply(POSIXError(.EINVAL))
            return
        }

        if Darwin.rmdir(path) != 0 {
            if errno != ENOENT {
                let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                log.error("rmdir(\(path, privacy: .public)) failed: \(String(cString: strerror(errno)), privacy: .public)")
                reply(POSIXError(code))
                return
            }
        }

        log.info("removed mountpoint \(path, privacy: .public)")
        reply(nil)
    }
}
