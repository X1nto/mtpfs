import CLibMTP
import Foundation
import os

private let log = Logger(subsystem: "dev.xinto.mtpfs.mtpkit", category: "Device")

public final class MTPDevice {

    public typealias ChunkSink = (UnsafeRawBufferPointer) -> Bool

    private static let queue = DispatchQueue(label: "dev.xinto.mtpfs.mtpkit", qos: .userInitiated)

    private static let initToken: Void = { LIBMTP_Init() }()

    private static let padBlockSize = 64 * 1024

    private var handle: UnsafeMutablePointer<LIBMTP_mtpdevice_struct>?

    private var _storage: MTPStorage?
    public var storage: MTPStorage? {
        Self.queue.sync {
            _storage
        }
    }

    private var storageID: UInt32 { _storage?.id ?? 0 }

    public let capabilities: MTPCapabilities

    private var editingObjectID: UInt32?
    private var editingSize: UInt64 = 0
    private var editFlush: DispatchWorkItem?

    public enum StorageProbe {
        case ready(MTPStorage)
        case notReady
        case gone(MTPError)
    }

    private init(
        handle: UnsafeMutablePointer<LIBMTP_mtpdevice_struct>,
        storage: MTPStorage?,
        capabilities: MTPCapabilities
    ) {
        self.handle = handle
        self._storage = storage
        self.capabilities = capabilities
    }

    public static func open(matching match: MTPDeviceMatch) throws -> MTPDevice {
        try queue.sync {
            _ = initToken

            guard let handle = openRaw(vendorID: match.vendorID, productID: match.productID) else {
                throw MTPError.deviceNotFound
            }

            LIBMTP_Clear_Errorstack(handle)

            let capabilities = MTPCapabilities(
                rangedRead: LIBMTP_Check_Capability(handle, LIBMTP_DEVICECAP_GetPartialObject) != 0,
                editObjects: LIBMTP_Check_Capability(handle, LIBMTP_DEVICECAP_SendPartialObject) != 0
                    && LIBMTP_Check_Capability(handle, LIBMTP_DEVICECAP_EditObjects) != 0
            )

            let storage = handle.pointee.storage.map { makeStorage(from: $0) }

            return MTPDevice(handle: handle, storage: storage, capabilities: capabilities)
        }
    }

    public func probeStorage() -> StorageProbe {
        Self.queue.sync {
            guard let handle = self.handle else {
                return .gone(.deviceNotFound)
            }
            
            flushEdit()

            LIBMTP_Clear_Errorstack(handle)
            
            // Sorting would reorder the storage list between calls.
            if LIBMTP_Get_Storage(handle, Int32(LIBMTP_STORAGE_SORTBY_NOTSORTED)) >= 0,
               let storagePtr = handle.pointee.storage
            {
                let storage = Self.makeStorage(from: storagePtr)
                _storage = storage
                return .ready(storage)
            }

            let error = MTPError.diagnose(handle, fallback: .storageNotReady, doing: "probeStorage")
            if error.isFatal {
                abandonEdit()
                LIBMTP_Release_Device(handle)
                self.handle = nil
                return .gone(error)
            }
            return .notReady
        }
    }

    public func refreshStorage() throws -> MTPStorage {
        switch probeStorage() {
        case .ready(let storage):
            return storage
        case .notReady:
            throw MTPError.storageNotReady
        case .gone(let error):
            throw error
        }
    }

    private static func makeStorage(from ptr: UnsafeMutablePointer<LIBMTP_devicestorage_struct>) -> MTPStorage {
        let rawTotal = ptr.pointee.MaxCapacity
        let rawFree = ptr.pointee.FreeSpaceInBytes
        // libmtp reports uint64 max when storage info can't be queried
        let total = rawTotal == .max ? 0 : rawTotal
        let free = (rawFree == .max || total == 0) ? 0 : min(rawFree, total)
        let label = ptr.pointee.StorageDescription.map { String(cString: $0) } ?? "MTP Storage"
        return MTPStorage(
            id: ptr.pointee.id,
            label: label,
            freeBytes: free,
            totalBytes: total
        )
    }

    private static func openRaw(vendorID: Int?, productID: Int?) -> UnsafeMutablePointer<LIBMTP_mtpdevice_struct>? {
        var rawDevices: UnsafeMutablePointer<LIBMTP_raw_device_t>?
        var count: Int32 = 0

        let status = LIBMTP_Detect_Raw_Devices(&rawDevices, &count)
        guard status == LIBMTP_ERROR_NONE, let rawDevices, count > 0 else {
            log.error("openRaw: detect failed (status=\(status.rawValue), count=\(count))")
            return nil
        }
        defer {
            free(rawDevices)
        }

        for index in 0..<Int(count) {
            let raw = rawDevices.advanced(by: index)
            if let vid = vendorID, Int(raw.pointee.device_entry.vendor_id) != vid {
                continue
            }
            if let pid = productID, Int(raw.pointee.device_entry.product_id) != pid {
                continue
            }
            if let device = LIBMTP_Open_Raw_Device_Uncached(raw) {
                return device
            }
            log.error("openRaw: could not open raw device \(index)")
        }
        return nil
    }

    public func release() {
        Self.queue.sync {
            flushEdit()
            if let handle {
                LIBMTP_Release_Device(handle)
                self.handle = nil
            }
        }
    }


    public func listChildren(parentID: UInt32) throws -> [MTPObject] {
        try Self.queue.sync {
            guard let handle = self.handle else {
                throw MTPError.deviceNotFound
            }
            flushEdit()

            LIBMTP_Clear_Errorstack(handle)

            var handles: UnsafeMutablePointer<UInt32>?
            let count = LIBMTP_Get_Children(handle, storageID, parentID, &handles)

            if count < 0 {
                throw fail(handle, "listChildren(parent=\(parentID))")
            }
            
            guard count != 0, let handles else {
                return []
            }
            
            defer {
                free(handles)
            }

            var results: [MTPObject] = []
            results.reserveCapacity(Int(count))

            for index in 0..<Int(count) {
                guard let file = LIBMTP_Get_Filemetadata(handle, handles[index]) else {
                    log.error(
                        """
                        listChildren(parent=\(parentID)): metadata fetch failed for handle \
                        \(handles[index]) (\(index + 1) of \(count))
                        """
                    )
                    throw MTPError.deviceError
                }
                results.append(Self.object(from: file))
                LIBMTP_destroy_file_t(file)
            }
            return results
        }
    }

    public func metadata(objectID: UInt32) throws -> MTPObject {
        try Self.queue.sync {
            guard let handle = self.handle else {
                throw MTPError.deviceNotFound
            }
            
            flushEdit()
            
            guard let file = LIBMTP_Get_Filemetadata(handle, objectID) else {
                throw MTPError.objectNotFound
            }
            
            defer {
                LIBMTP_destroy_file_t(file)
            }
            
            return Self.object(from: file)
        }
    }

    public func readRange(objectID: UInt32, offset: UInt64, length: UInt64) throws -> Data {
        try Self.queue.sync {
            guard let handle = self.handle else {
                throw MTPError.deviceNotFound
            }
            
            flushEdit()

            var accumulated = Data()
            accumulated.reserveCapacity(Int(clamping: length))
            var cursor = offset
            var remaining = length

            while remaining > 0 {
                var raw: UnsafeMutablePointer<UInt8>?
                var got: UInt32 = 0
                
                LIBMTP_Clear_Errorstack(handle)
                
                let ret = LIBMTP_GetPartialObject(handle, objectID, cursor, UInt32(clamping: remaining), &raw, &got)
                if ret != 0 {
                    throw fail(handle, "GetPartialObject(obj=\(objectID), off=\(cursor))")
                }
                
                guard let raw, got > 0 else {
                    if let raw {
                        free(raw)
                    }
                    break
                }
                
                accumulated.append(raw, count: Int(got))
                free(raw)
                cursor += UInt64(got)
                remaining -= UInt64(got)
            }
            return accumulated
        }
    }

    @discardableResult
    public func readWholeObject(objectID: UInt32, into sink: ChunkSink) throws -> Bool {
        try Self.queue.sync {
            guard let handle = self.handle else {
                throw MTPError.deviceNotFound
            }
            
            flushEdit()

            LIBMTP_Clear_Errorstack(handle)
            
            let outcome = withoutActuallyEscaping(sink) { escapableSink -> (result: Int32, aborted: Bool) in
                let context = StreamContext(sink: escapableSink)
                let boxed = Unmanaged.passRetained(context)
                
                defer {
                    boxed.release()
                }

                let result = LIBMTP_Get_File_To_Handler(
                    handle, objectID,
                    { _, priv, sendlen, bytes, putlen in
                        guard let priv, let bytes, sendlen > 0 else {
                            putlen?.pointee = 0
                            return UInt16(LIBMTP_HANDLER_RETURN_OK)
                        }
                        
                        let context = Unmanaged<StreamContext>.fromOpaque(priv).takeUnretainedValue()
                        let accepted = context.sink(UnsafeRawBufferPointer(start: bytes, count: Int(sendlen)))
                        if !accepted {
                            context.aborted = true
                            putlen?.pointee = 0
                            return UInt16(LIBMTP_HANDLER_RETURN_CANCEL)
                        }
                        
                        putlen?.pointee = sendlen
                        return UInt16(LIBMTP_HANDLER_RETURN_OK)
                    },
                    boxed.toOpaque(), nil, nil
                )
                return (result, context.aborted)
            }

            if outcome.aborted {
                return false
            }
            if outcome.result != 0 {
                throw fail(handle, "Get_File_To_Handler(obj=\(objectID))")
            }
            return true
        }
    }

    public func write(objectID: UInt32, offset: UInt64, data: Data) throws {
        try Self.queue.sync {
            guard let handle = self.handle else {
                throw MTPError.deviceNotFound
            }
            
            if !capabilities.editObjects {
                throw MTPError.operationUnsupported
            }

            try beginEditing(objectID, handle: handle)
            try growEdit(to: offset, objectID: objectID, handle: handle)

            if data.isEmpty {
                scheduleEditFlush()
                return
            }

            LIBMTP_Clear_Errorstack(handle)
            
            let ret = data.withUnsafeBytes { raw -> Int32 in
                guard let base = raw.baseAddress else {
                    return -1
                }
                
                return LIBMTP_SendPartialObject(
                    handle, objectID, offset,
                    UnsafeMutablePointer(mutating: base.assumingMemoryBound(to: UInt8.self)),
                    UInt32(raw.count)
                )
            }
            if ret != 0 {
                let error = fail(handle, "SendPartialObject(obj=\(objectID), off=\(offset), len=\(data.count))")
                if self.handle != nil {
                    flushEdit()
                }
                throw error
            }

            editingSize = max(editingSize, offset + UInt64(data.count))
            scheduleEditFlush()
        }
    }

    public func truncate(objectID: UInt32, to size: UInt64) throws {
        try Self.queue.sync {
            guard let handle = self.handle else {
                throw MTPError.deviceNotFound
            }
            
            guard capabilities.editObjects else {
                throw MTPError.operationUnsupported
            }

            try beginEditing(objectID, handle: handle)

            LIBMTP_Clear_Errorstack(handle)
            if LIBMTP_TruncateObject(handle, objectID, size) != 0 {
                let error = fail(handle, "TruncateObject(obj=\(objectID), size=\(size))")
                
                if self.handle != nil {
                    flushEdit()
                }
                
                throw error
            }

            editingSize = size
            scheduleEditFlush()
        }
    }

    public func createFile(parentID: UInt32, name: String) throws -> UInt32 {
        try Self.queue.sync {
            guard let handle = self.handle else {
                throw MTPError.deviceNotFound
            }
            
            flushEdit()

            guard let file = LIBMTP_new_file_t() else {
                throw MTPError.outOfMemory
            }
            
            file.pointee.parent_id = parentID
            file.pointee.storage_id = storageID
            file.pointee.filesize = 0
            file.pointee.filetype = LIBMTP_FILETYPE_UNKNOWN
            file.pointee.filename = name.withCString { strdup($0) }

            LIBMTP_Clear_Errorstack(handle)
            let ret = LIBMTP_Send_File_From_Handler(
                handle,
                { _, _, _, _, gotlen in
                    gotlen?.pointee = 0
                    return 0
                },
                nil, file, nil, nil
            )
            let newID = file.pointee.item_id
            LIBMTP_destroy_file_t(file)

            if ret != 0 {
                throw fail(handle, "Send_File_From_Handler(parent=\(parentID))")
            }
            return newID
        }
    }

    public func createFolder(parentID: UInt32, name: String) throws -> UInt32 {
        try Self.queue.sync {
            guard let handle = self.handle else {
                throw MTPError.deviceNotFound
            }
            
            flushEdit()

            guard let scratch = name.withCString({ strdup($0) }) else {
                throw MTPError.outOfMemory
            }
            
            defer {
                free(scratch)
            }

            LIBMTP_Clear_Errorstack(handle)
            let newID = LIBMTP_Create_Folder(handle, scratch, parentID, storageID)
            if newID == 0 {
                throw fail(handle, "Create_Folder(parent=\(parentID))")
            }
            return newID
        }
    }

    public func delete(objectID: UInt32) throws {
        try Self.queue.sync {
            guard let handle = self.handle else { throw MTPError.deviceNotFound }
            flushEdit()

            LIBMTP_Clear_Errorstack(handle)
            if LIBMTP_Delete_Object(handle, objectID) != 0 {
                throw fail(handle, "Delete_Object(\(objectID))")
            }
        }
    }

    public func rename(objectID: UInt32, to newName: String) throws {
        try Self.queue.sync {
            guard let handle = self.handle else { throw MTPError.deviceNotFound }
            flushEdit()

            guard let file = LIBMTP_Get_Filemetadata(handle, objectID) else {
                throw MTPError.objectNotFound
            }
            LIBMTP_Clear_Errorstack(handle)
            let ret = newName.withCString { LIBMTP_Set_File_Name(handle, file, $0) }
            LIBMTP_destroy_file_t(file)
            if ret != 0 {
                throw fail(handle, "Set_File_Name(\(objectID))")
            }
        }
    }

    private func beginEditing(_ objectID: UInt32, handle: UnsafeMutablePointer<LIBMTP_mtpdevice_struct>) throws {
        if editingObjectID == objectID {
            return
        }
        
        flushEdit()

        LIBMTP_Clear_Errorstack(handle)
        
        if LIBMTP_BeginEditObject(handle, objectID) != 0 {
            let first = fail(handle, "BeginEditObject(\(objectID))")

//            if self.handle == nil {
//                throw first
//            }

            _ = LIBMTP_EndEditObject(handle, objectID)
            
            LIBMTP_Clear_Errorstack(handle)

            if LIBMTP_BeginEditObject(handle, objectID) != 0 {
                throw fail(handle, "BeginEditObject(\(objectID)) after clearing a stale edit")
            }
        }

        editingObjectID = objectID
        editingSize = Self.size(of: handle, objectID: objectID) ?? 0
    }

    private func growEdit(
        to offset: UInt64,
        objectID: UInt32,
        handle: UnsafeMutablePointer<LIBMTP_mtpdevice_struct>
    ) throws {
        if offset <= editingSize {
            return
        }
        
        let gapStart = editingSize

        LIBMTP_Clear_Errorstack(handle)
        
        if LIBMTP_TruncateObject(handle, objectID, offset) != 0 {
            throw fail(handle, "growEdit: TruncateObject(obj=\(objectID), size=\(offset))")
        }

        var zeros = [UInt8](repeating: 0, count: Self.padBlockSize)
        var cursor = gapStart
        while cursor < offset {
            let chunk = Int(min(UInt64(Self.padBlockSize), offset - cursor))
            LIBMTP_Clear_Errorstack(handle)
            let sent = zeros.withUnsafeMutableBufferPointer { buffer -> Int32 in
                guard let base = buffer.baseAddress else {
                    return -1
                }
                
                return LIBMTP_SendPartialObject(handle, objectID, cursor, base, UInt32(chunk))
            }
            if sent != 0 {
                throw fail(handle, "growEdit: zero-fill at \(cursor) (\(chunk) bytes)")
            }
            cursor += UInt64(chunk)
        }
        editingSize = offset
    }

    private func flushEdit() {
        editFlush?.cancel()
        editFlush = nil
        
        guard let objectID = editingObjectID else {
            return
        }
        
        editingObjectID = nil
        
        guard let handle else {
            return
        }

        if LIBMTP_EndEditObject(handle, objectID) != 0 {
            log.error("EndEditObject(\(objectID)) failed")
            LIBMTP_Clear_Errorstack(handle)
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
        Self.queue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func fail(
        _ handle: UnsafeMutablePointer<LIBMTP_mtpdevice_struct>,
        _ operation: String,
        fallback: MTPError = .deviceError
    ) -> MTPError {
        let error = MTPError.diagnose(handle, fallback: fallback, doing: operation)
        if error.isFatal {
            log.error("device unreachable during \(operation, privacy: .public)")
            abandonEdit()
            if let live = self.handle {
                LIBMTP_Release_Device(live)
                self.handle = nil
            }
        }
        return error
    }

    private static func size(of handle: UnsafeMutablePointer<LIBMTP_mtpdevice_struct>, objectID: UInt32) -> UInt64? {
        guard let file = LIBMTP_Get_Filemetadata(handle, objectID) else {
            return nil
        }
        
        defer {
            LIBMTP_destroy_file_t(file)
        }
        
        return file.pointee.filesize
    }

    private static func object(from file: UnsafeMutablePointer<LIBMTP_file_struct>) -> MTPObject {
        let mtime = file.pointee.modificationdate
        return MTPObject(
            objectID: file.pointee.item_id,
            parentID: file.pointee.parent_id,
            name: file.pointee.filename.map { String(cString: $0) } ?? "",
            isDirectory: file.pointee.filetype == LIBMTP_FILETYPE_FOLDER,
            size: file.pointee.filesize,
            modificationDate: mtime == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(mtime)),
            creationDate: nil // TODO: Figure this out
        )
    }
}

private final class StreamContext {
    let sink: MTPDevice.ChunkSink
    var aborted = false
    
    init(sink: @escaping MTPDevice.ChunkSink) {
        self.sink = sink
    }
}
