import Foundation
import os

private let log = Logger(subsystem: "dev.xinto.mtpfs.mtpd", category: "main")

final class DaemonListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let daemon: MTPDaemon

    init(daemon: MTPDaemon) {
        self.daemon = daemon
        super.init()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // The mach name is global: without this check any process on the system could drive the
        // user's phone through us. Reject anything not signed by our team.
        newConnection.setCodeSigningRequirement(MTPClientCodeRequirement)

        newConnection.exportedInterface = NSXPCInterface(with: MTPServiceProtocol.self)
        newConnection.exportedObject = daemon.engine

        // Session references are tied to CONNECTION LIFETIME, not to a cooperative closeSession().
        // FSKit terminates an extension outright (RunningBoard kill, no deactivate), so an
        // extension that opened a session frequently never gets to close it. Refcounting on
        // closeSession alone therefore drifts upward and the device is never released.
        let pid = newConnection.processIdentifier
        let drop = { [weak daemon] in
            daemon?.engine.releaseSessionsForDeadClient(pid: pid)
        }
        newConnection.invalidationHandler = { drop() }
        newConnection.interruptionHandler = { drop() }

        newConnection.resume()
        return true
    }
}

let daemon = MTPDaemon()

let listener = NSXPCListener(machServiceName: MTPMachServiceName)
let delegate = DaemonListenerDelegate(daemon: daemon)
listener.delegate = delegate
listener.resume()

daemon.start()

// The watcher and the listener are both callback-driven; park the main thread.
dispatchMain()
