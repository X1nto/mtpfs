import CLibMTP
import CLibPTP
import Foundation
import os

private let log = Logger(subsystem: "dev.xinto.mtpfs.mtpkit", category: "Device")

enum BulkListingSupport {
    case untried
    case supported
    case unsupported
}

func fetchBulkObjectProperties(
    parentID: UInt32,
    handle: UnsafeMutablePointer<LIBMTP_mtpdevice_struct>,
    support: inout BulkListingSupport // FIXME: Not a big fan of inout
) -> [UInt32: MTPObject]? {
    guard let params = handle.pointee.params else {
        return nil
    }

    var props: UnsafeMutablePointer<MTPProperties>?
    var count: Int32 = 0

    let rc = ptp_mtp_getobjectproplist_level(params.assumingMemoryBound(to: PTPParams.self), parentID, 1, &props, &count)

    if rc != UInt16(PTP_RC_OK) {
        switch Int32(rc) {
        case PTP_RC_OperationNotSupported,
             PTP_RC_MTP_Specification_By_Depth_Unsupported,
             PTP_RC_MTP_Specification_By_Group_Unsupported:

            #if DEBUG
            log.info("bulk listing unsupported (ptp rc \(String(rc, radix: 16)))")
            #endif

            support = .unsupported
        default:
            log.error("bulk listing failed (ptp rc \(String(rc, radix: 16)))")
        }
        return nil
    }

    guard let props else {
        return nil
    }

    defer {
        ptp_destroy_object_prop_list(props, count)
    }

    if support == .untried {
        support = .supported
    }

    var building: [UInt32: PartialObject] = [:]
    for entry in UnsafeBufferPointer(start: props, count: Int(max(count, 0))) {
        if entry.ObjectHandle == parentID {
            continue
        }
        building[entry.ObjectHandle, default: PartialObject()].absorb(entry)
    }

    var objects: [UInt32: MTPObject] = [:]
    objects.reserveCapacity(building.count)
    for (objectID, partial) in building {
        if let object = partial.build(objectID: objectID) {
            objects[objectID] = object
        }
    }
    return objects
}

private struct PartialObject {
    var name: String?
    var parentID: UInt32?
    var size: UInt64?
    var format: UInt16?
    var modified: Date?
    var created: Date?

    mutating func absorb(_ entry: MTPProperties) {
        switch Int32(entry.property) {
        case PTP_OPC_ObjectFileName:
            name = string(from: entry)
        case PTP_OPC_ParentObject:
            parentID = entry.propval.u32
        case PTP_OPC_ObjectFormat:
            format = entry.propval.u16
        case PTP_OPC_ObjectSize:
            size = Int32(entry.datatype) == PTP_DTC_UINT32
                ? UInt64(entry.propval.u32)
                : entry.propval.u64
        case PTP_OPC_DateModified:
            modified = string(from: entry).flatMap(ptpDate)
        case PTP_OPC_DateCreated:
            created = string(from: entry).flatMap(ptpDate)
        default:
            break
        }
    }

    func build(objectID: UInt32) -> MTPObject? {
        guard let name, let format else {
            return nil
        }
        return MTPObject(
            objectID: objectID,
            parentID: parentID ?? 0,
            name: name,
            isDirectory: Int32(format) == PTP_OFC_Association,
            size: size ?? 0,
            modificationDate: modified,
            creationDate: created
        )
    }
}

private func string(from entry: MTPProperties) -> String? {
    guard Int32(entry.datatype) == PTP_DTC_STR, let raw = entry.propval.str else {
        return nil
    }
    return String(cString: raw)
}

private let ptpCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    return calendar
}()

private func ptpDate(_ raw: String) -> Date? {
    let digits = Array(raw.utf8)
    if digits.count < 15 {
        return nil
    }

    func number(at start: Int, length: Int) -> Int? {
        var value = 0
        for index in start..<(start + length) {
            let digit = digits[index]
            guard digit >= UInt8(ascii: "0"), digit <= UInt8(ascii: "9") else {
                return nil
            }
            value = value * 10 + Int(digit - UInt8(ascii: "0"))
        }
        return value
    }

    guard let year = number(at: 0, length: 4),
          let month = number(at: 4, length: 2),
          let day = number(at: 6, length: 2),
          let hour = number(at: 9, length: 2),
          let minute = number(at: 11, length: 2),
          let second = number(at: 13, length: 2)
    else {
        return nil
    }

    return ptpCalendar.date(
        from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )
    )
}
