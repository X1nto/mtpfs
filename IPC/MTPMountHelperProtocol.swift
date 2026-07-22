import Foundation

let MTPMountHelperLabel = "dev.xinto.mtpfs.mtpmounterd"
let MTPMountHelperMachServiceName = "85342F9WTR.dev.xinto.mtpfs.mtpmounterd"

@objc protocol MTPMountHelperProtocol {
    /// - Parameter reply: Path to the created mountpoint
    func prepareMountpoint(name: String, reply: @escaping (String?, Error?) -> Void)
    func removeMountpoint(path: String, reply: @escaping (Error?) -> Void)
}
