import Foundation

let mtpBaseBundleID: String = {
    let id = Bundle.main.bundleIdentifier ?? "dev.xinto.mtpfs"
    for suffix in [".mtpd", ".mtpmounterd", ".fsext"] where id.hasSuffix(suffix) {
        return String(id.dropLast(suffix.count))
    }
    return id
}()


let MTPFSShortName = mtpBaseBundleID.hasSuffix(".debug") ? "mtpfsdebug" : "mtpfs"

let MTPDaemonLabel = "\(mtpBaseBundleID).mtpd"
let MTPDaemonPlistName = "dev.xinto.mtpfs.mtpd.plist"
let MTPMachServiceName = "85342F9WTR.\(mtpBaseBundleID).mtpd"
let MTPModuleBundleID = "\(mtpBaseBundleID).fsext"
let MTPClientCodeRequirement = #"anchor apple generic and certificate leaf[subject.OU] = "85342F9WTR""#

let MTPMountHelperLabel = "\(mtpBaseBundleID).mtpmounterd"
let MTPMountHelperPlistName = "dev.xinto.mtpfs.mtpmounterd.plist"
let MTPMountHelperMachServiceName = "85342F9WTR.\(mtpBaseBundleID).mtpmounterd"
