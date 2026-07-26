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
        newConnection.setCodeSigningRequirement(MTPClientCodeRequirement)

        newConnection.exportedInterface = NSXPCInterface(with: MTPServiceProtocol.self)
        newConnection.exportedObject = daemon.engine

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

dispatchMain()
