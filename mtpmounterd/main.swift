import Foundation

let server = MTPMountHelperServer()
let listener = NSXPCListener(machServiceName: MTPMountHelperMachServiceName)
listener.delegate = server
listener.resume()

RunLoop.main.run()
