import Foundation
import os

private let log = Logger(subsystem: "dev.xinto.mtpfs.mtpd", category: "Engine")

final class MTPService: NSObject, MTPServiceProtocol {

    private static let libmtpInit: Void = { LIBMTP_Init() }()

    private var device: UnsafeMutablePointer<LIBMTP_mtpdevice_struct>?
    private var storageID: UInt32 = 0
    private let queue = DispatchQueue(label: "dev.xinto.mtpfs.libmtp", qos: .userInitiated)

    private var cachedStorage: MTPStorageInfo?
    
    private var supportsRangedRead = false
    private var supportsEditObjects = false

    private var editingObjectID: UInt32?
    private var editFlush: DispatchWorkItem?
    private var editingSize: UInt64 = 0

    private var sessionOwners: Set<Int32> = []
    static let localOwnerPID: Int32 = 0
    
    private var callerPID: Int32 {
        NSXPCConnection.current()?.processIdentifier ?? Self.localOwnerPID
    }

    override init() {
        _ = MTPService.libmtpInit
        super.init()
    }
    
    func openSession(reply: @escaping (Data?, Error?) -> Void) {
        let owner = callerPID
        queue.async {
            if self.device != nil, let cached = self.cachedStorage {
                self.sessionOwners.insert(owner)
                self.encode(cached, reply: reply)
                return
            }

            guard let device = Self.openUncachedDevice() else {
                reply(nil, POSIXError(.ENODEV))
                return
            }

            guard LIBMTP_Get_Storage(device, 0) == 0, let storage = device.pointee.storage else {
                LIBMTP_Release_Device(device)
                reply(nil, POSIXError(.EIO))
                return
            }

            self.device = device
            self.storageID = storage.pointee.id
            self.supportsRangedRead = LIBMTP_Check_Capability(device, LIBMTP_DEVICECAP_GetPartialObject) != 0
            self.supportsEditObjects =
                LIBMTP_Check_Capability(device, LIBMTP_DEVICECAP_SendPartialObject) != 0
                && LIBMTP_Check_Capability(device, LIBMTP_DEVICECAP_EditObjects) != 0

            let label = storage.pointee.StorageDescription.map { String(cString: $0) } ?? "MTP Storage"
            let info = MTPStorageInfo(
                freeBytes: storage.pointee.FreeSpaceInBytes,
                totalBytes: storage.pointee.MaxCapacity,
                label: label
            )
            self.cachedStorage = info
            self.sessionOwners = [owner]
            self.encode(info, reply: reply)
        }
    }

    func closeSession(reply: @escaping (Error?) -> Void) {
        let owner = callerPID
        queue.async {
            self.retire(owner: owner, why: "closeSession")
            reply(nil)
        }
    }

    func releaseSessionsForDeadClient(pid: Int32) {
        queue.async {
            self.retire(owner: pid, why: "client died")
        }
    }

    func forceCloseSession() {
        queue.async {
            if self.device == nil {
                return
            }
            log.info("forceCloseSession: releasing device, discarding \(self.sessionOwners.count) holder(s)")
            self.sessionOwners.removeAll()
            self.abandonEdit()
            self.releaseDevice()
        }
    }

    private func retire(owner: Int32, why: String) {
        if sessionOwners.remove(owner) == nil {
            return
        }
        if sessionOwners.isEmpty {
            flushEdit()
            releaseDevice()
        }
    }

    private static func openUncachedDevice() -> UnsafeMutablePointer<LIBMTP_mtpdevice_struct>? {
        var rawDevices: UnsafeMutablePointer<LIBMTP_raw_device_t>?
        var count: Int32 = 0

        let status = LIBMTP_Detect_Raw_Devices(&rawDevices, &count)
        guard status == LIBMTP_ERROR_NONE, let rawDevices, count > 0 else {
            log.error("openUncachedDevice: detect failed (status=\(status.rawValue), count=\(count))")
            return nil
        }
        defer { free(rawDevices) }

        // TODO: match on the candidate's USB serial instead of taking the first to support multiple devices.
        for index in 0..<Int(count) {
            if let device = LIBMTP_Open_Raw_Device_Uncached(rawDevices.advanced(by: index)) {
                return device
            }
            log.error("openUncachedDevice: could not open raw device \(index)")
        }
        return nil
    }

    private func releaseDevice() {
        if let device {
            LIBMTP_Release_Device(device)
            self.device = nil
        }
        cachedStorage = nil
        storageID = 0
        supportsEditObjects = false
        supportsRangedRead = false
    }

    func listObjects(parentID: UInt32, reply: @escaping (Data?, Error?) -> Void) {
        queue.async {
            guard let device = self.device else {
                reply(nil, POSIXError(.EIO))
                return
            }
            
            self.flushEdit()

            var results: [MTPObjectInfo] = []

            LIBMTP_Clear_Errorstack(device)
            var node = LIBMTP_Get_Files_And_Folders(device, self.storageID, parentID)

            // null might mean both "empty directory" and "transaction failed"
            if node == nil, let stack = LIBMTP_Get_Errorstack(device) {
                let message = stack.pointee.error_text.map { String(cString: $0) } ?? "unknown"
                log.error("listObjects(parent=\(parentID)): libmtp error: \(message, privacy: .public)")
                LIBMTP_Clear_Errorstack(device)
                reply(nil, POSIXError(.EIO))
                return
            }

            while let current = node {
                let next = current.pointee.next
                let itemID = current.pointee.item_id
                let parID = current.pointee.parent_id
                let name = current.pointee.filename.map { String(cString: $0) } ?? ""
                let isDirectory = current.pointee.filetype == LIBMTP_FILETYPE_FOLDER
                let size = current.pointee.filesize
                let modificationTime = current.pointee.modificationdate
                LIBMTP_destroy_file_t(current)
                node = next

                results.append(MTPObjectInfo(
                    objectID: itemID,
                    parentID: parID,
                    name: name,
                    isDirectory: isDirectory,
                    fileSize: size,
                    modificationDate: modificationTime == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(modificationTime)),
                    creationDate: nil
                ))
            }
            self.encode(results, reply: reply)
        }
    }

    func getObjectInfo(objectID: UInt32, reply: @escaping (Data?, Error?) -> Void) {
        queue.async {
            guard let device = self.device else {
                reply(nil, POSIXError(.EIO))
                return
            }
            
            self.flushEdit()

            guard let file = LIBMTP_Get_Filemetadata(device, objectID) else {
                reply(nil, POSIXError(.ENOENT))
                return
            }
            let mtime = file.pointee.modificationdate
            let info = MTPObjectInfo(
                objectID: file.pointee.item_id,
                parentID: file.pointee.parent_id,
                name: file.pointee.filename.map { String(cString: $0) } ?? "",
                isDirectory: file.pointee.filetype == LIBMTP_FILETYPE_FOLDER,
                fileSize: file.pointee.filesize,
                modificationDate: mtime == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(mtime)),
                creationDate: nil
            )
            LIBMTP_destroy_file_t(file)
            self.encode(info, reply: reply)
        }
    }

    func readFile(objectID: UInt32, offset: UInt64, length: UInt64, reply: @escaping (Data?, Error?) -> Void) {
        queue.async {
            guard let device = self.device else {
                reply(nil, POSIXError(.EIO))
                return
            }
            
            self.flushEdit()

            if self.supportsRangedRead {
                var raw: UnsafeMutablePointer<UInt8>?
                var got: UInt32 = 0
                let ret = LIBMTP_GetPartialObject(device, objectID, offset, UInt32(clamping: length), &raw, &got)
                if ret == 0, let raw {
                    defer { free(raw) }
                    reply(Data(bytes: raw, count: Int(got)), nil)
                    return
                }
                
                // Partial read is preferred, but it's *fine* if we're forced to full read. Sucks though.
                log.error("GetPartialObject(obj=\(objectID), off=\(offset)) failed (ret=\(ret))")
                LIBMTP_Clear_Errorstack(device)
            }

            guard let full = self.wholeObject(device: device, objectID: objectID) else {
                reply(nil, POSIXError(.EIO))
                return
            }
            
            let start = Int(min(offset, UInt64(full.count)))
            let end = Int(min(offset + length, UInt64(full.count)))
            reply(full[start..<end], nil)
        }
    }

    private func wholeObject(device: UnsafeMutablePointer<LIBMTP_mtpdevice_struct>, objectID: UInt32) -> Data? {
        let buffer = ReadBuffer()
        let ctx = Unmanaged.passRetained(buffer)
        let result = LIBMTP_Get_File_To_Handler(
            device, objectID,
            { _, priv, sendlen, bytes, putlen in
                guard let priv, let bytes, sendlen > 0 else {
                    putlen?.pointee = 0
                    return 0
                }
                let buffer = Unmanaged<ReadBuffer>.fromOpaque(priv).takeUnretainedValue()
                buffer.data.append(bytes, count: Int(sendlen))
                putlen?.pointee = sendlen
                return 0
            },
            ctx.toOpaque(), nil, nil
        )
        ctx.release()
        return result == 0 ? buffer.data : nil
    }

    func writeFile(objectID: UInt32, offset: UInt64, data: Data, reply: @escaping (Error?) -> Void) {
        queue.async {
            guard let device = self.device else {
                reply(POSIXError(.EIO))
                return
            }
            
            if !self.supportsEditObjects {
                log.error("writeFile: device lacks the object editing extensions")
                reply(POSIXError(.ENOTSUP))
                return
            }
            
            guard self.beginEditing(objectID, device: device),
                  self.growEdit(to: offset, objectID: objectID, device: device)
            else {
                reply(POSIXError(.EIO))
                return
            }

            LIBMTP_Clear_Errorstack(device)
            let ret = data.withUnsafeBytes { raw -> Int32 in
                guard let base = raw.baseAddress else {
                    return -1
                }
                return LIBMTP_SendPartialObject(
                    device,
                    objectID,
                    offset,
                    UnsafeMutablePointer(mutating: base.assumingMemoryBound(to: UInt8.self)),
                    UInt32(raw.count)
                )
            }
            if ret != 0 {
                log.error("SendPartialObject(obj=\(objectID), off=\(offset), len=\(data.count)) failed")
                LIBMTP_Clear_Errorstack(device)
                self.flushEdit()
                reply(POSIXError(.EIO))
                return
            }

            self.editingSize = max(self.editingSize, offset + UInt64(data.count))
            self.scheduleEditFlush()
            reply(nil)
        }
    }

    func truncateFile(objectID: UInt32, size: UInt64, reply: @escaping (Error?) -> Void) {
        queue.async {
            guard let device = self.device else {
                reply(POSIXError(.EIO))
                return
            }
            guard self.supportsEditObjects else {
                reply(POSIXError(.ENOTSUP))
                return
            }
            guard self.beginEditing(objectID, device: device) else {
                reply(POSIXError(.EIO))
                return
            }

            LIBMTP_Clear_Errorstack(device)
            if LIBMTP_TruncateObject(device, objectID, size) != 0 {
                log.error("TruncateObject(obj=\(objectID), size=\(size)) failed")
                LIBMTP_Clear_Errorstack(device)
                self.flushEdit()
                reply(POSIXError(.EIO))
                return
            }

            self.editingSize = size
            self.scheduleEditFlush()
            reply(nil)
        }
    }

    private func beginEditing(_ objectID: UInt32, device: UnsafeMutablePointer<LIBMTP_mtpdevice_struct>) -> Bool {
        if editingObjectID == objectID {
            return true
        }
        
        flushEdit()

        LIBMTP_Clear_Errorstack(device)
        if LIBMTP_BeginEditObject(device, objectID) != 0 {
            LIBMTP_Clear_Errorstack(device)
            _ = LIBMTP_EndEditObject(device, objectID)
            LIBMTP_Clear_Errorstack(device)

            if LIBMTP_BeginEditObject(device, objectID) != 0 {
                log.error("BeginEditObject(\(objectID)) failed after clearing a stale edit")
                LIBMTP_Clear_Errorstack(device)
                return false
            }
        }
        editingObjectID = objectID
        editingSize = Self.size(of: device, objectID: objectID) ?? 0
        return true
    }

    private static func size(of device: UnsafeMutablePointer<LIBMTP_mtpdevice_struct>, objectID: UInt32) -> UInt64? {
        guard let file = LIBMTP_Get_Filemetadata(device, objectID) else {
            return nil
        }
        defer { LIBMTP_destroy_file_t(file) }
        return file.pointee.filesize
    }

    private func growEdit(to offset: UInt64, objectID: UInt32, device: UnsafeMutablePointer<LIBMTP_mtpdevice_struct>) -> Bool {
        if offset <= editingSize {
            return true
        }

        LIBMTP_Clear_Errorstack(device)
        
        if LIBMTP_TruncateObject(device, objectID, offset) != 0 {
            LIBMTP_Clear_Errorstack(device)
            return false
        }
        
        editingSize = offset
        return true
    }

    private func flushEdit() {
        editFlush?.cancel()
        editFlush = nil
        guard let objectID = editingObjectID else {
            return
        }
        editingObjectID = nil
        guard let device else {
            return
        }

        if LIBMTP_EndEditObject(device, objectID) != 0 {
            log.error("EndEditObject(\(objectID)) failed")
            LIBMTP_Clear_Errorstack(device)
        }
    }

    private func abandonEdit() {
        editFlush?.cancel()
        editFlush = nil
        editingObjectID = nil
    }

    private func scheduleEditFlush() {
        editFlush?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flushEdit()
        }
        editFlush = work
        queue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func createFile(parentID: UInt32, name: String, size: UInt64, reply: @escaping (UInt32, Error?) -> Void) {
        queue.async {
            guard let device = self.device else {
                reply(0, POSIXError(.EIO))
                return
            }
            self.flushEdit()

            guard let file = LIBMTP_new_file_t() else {
                reply(0, POSIXError(.ENOMEM))
                return
            }

            file.pointee.parent_id = parentID
            file.pointee.storage_id = self.storageID
            file.pointee.filesize = size
            file.pointee.filetype = LIBMTP_FILETYPE_UNKNOWN
            file.pointee.filename = name.withCString { strdup($0) }

            let ret = LIBMTP_Send_File_From_Handler(
                device,
                { _, _, _, _, gotlen in
                    gotlen?.pointee = 0
                    return 0
                },
                nil, file, nil, nil
            )
            let newID = file.pointee.item_id
            LIBMTP_destroy_file_t(file)

            reply(ret == 0 ? newID : 0, ret == 0 ? nil : POSIXError(.EIO))
        }
    }

    func createDirectory(parentID: UInt32, name: String, reply: @escaping (UInt32, Error?) -> Void) {
        queue.async {
            guard let device = self.device else {
                reply(0, POSIXError(.EIO))
                return
            }
            
            self.flushEdit()

            let newID = name.withCString {
                LIBMTP_Create_Folder(device, UnsafeMutablePointer(mutating: $0), parentID, self.storageID)
            }
            reply(newID, newID != 0 ? nil : POSIXError(.EIO))
        }
    }

    func deleteObject(objectID: UInt32, reply: @escaping (Error?) -> Void) {
        queue.async {
            guard let device = self.device else {
                reply(POSIXError(.EIO))
                return
            }
            
            self.flushEdit()

            let ret = LIBMTP_Delete_Object(device, objectID)
            reply(ret == 0 ? nil : POSIXError(.EIO))
        }
    }

    func renameObject(objectID: UInt32, newName: String, reply: @escaping (Error?) -> Void) {
        queue.async {
            guard let device = self.device else {
                reply(POSIXError(.EIO))
                return
            }
            
            self.flushEdit()

            guard let file = LIBMTP_Get_Filemetadata(device, objectID) else {
                reply(POSIXError(.ENOENT))
                return
            }
            let ret = newName.withCString {
                LIBMTP_Set_File_Name(device, file, $0)
            }
            LIBMTP_destroy_file_t(file)
            reply(ret == 0 ? nil : POSIXError(.EIO))
        }
    }

    private func encode<T: Encodable>(_ value: T, reply: (Data?, Error?) -> Void) {
        do {
            reply(try JSONEncoder().encode(value), nil)
        } catch {
            reply(nil, error)
        }
    }
}

private final class ReadBuffer {
    var data = Data()
}
