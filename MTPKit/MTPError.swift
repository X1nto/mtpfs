import CLibMTP
import os

private let log = Logger(subsystem: "dev.xinto.mtpfs.mtpkit", category: "Error")

public enum MTPError: Error, Equatable, Sendable {
    case accessDenied
    case deviceNotFound
    case deviceBusy
    case deviceTimedOut
    case deviceError
    case folderNotEmpty
    case invalidData
    case ioFailure
    case outOfMemory
    case operationCancelled
    case operationUnsupported
    case objectNotFound
    case storageFull
    case storageOffline
    case storageNotReady
    case writeProtected

    public var isFatal: Bool {
        switch self {
        case .deviceNotFound, .storageOffline, .ioFailure:
            return true
        default:
            return false
        }
    }
}

extension MTPError {

    private static let ptpOperationNotSupported: UInt16 = 0x2005
    private static let ptpInvalidObjectHandle: UInt16 = 0x2009
    private static let ptpInvalidObjectFormatCode: UInt16 = 0x200B
    private static let ptpStoreFull: UInt16 = 0x200C
    private static let ptpObjectWriteProtected: UInt16 = 0x200D
    private static let ptpStoreReadOnly: UInt16 = 0x200E
    private static let ptpAccessDenied: UInt16 = 0x200F
    private static let ptpPartialDeletion: UInt16 = 0x2012
    private static let ptpStoreNotAvailable: UInt16 = 0x2013
    private static let ptpNoValidObjectInfo: UInt16 = 0x2015
    private static let ptpDeviceBusy: UInt16 = 0x2019
    private static let ptpInvalidParentObject: UInt16 = 0x201A
    private static let ptpSpecificationOfDestinationUnsupported: UInt16 = 0x2020
    private static let ptpErrorTimeout: UInt16 = 0x02FA
    private static let ptpErrorCancel: UInt16 = 0x02FB
    private static let ptpErrorIO: UInt16 = 0x02FF

    static func diagnose(
        _ device: UnsafeMutablePointer<LIBMTP_mtpdevice_struct>,
        fallback: MTPError = .deviceError,
        doing operation: String? = nil
    ) -> MTPError {
        var messages: [String] = []
        var verdict: MTPError?

        var node = LIBMTP_Get_Errorstack(device)
        while let current = node {
            let text = current.pointee.error_text.map { String(cString: $0) } ?? ""
            if !text.isEmpty {
                messages.append(text)
            }

            switch current.pointee.errornumber {
            case LIBMTP_ERROR_NO_DEVICE_ATTACHED:
                verdict = .deviceNotFound
            case LIBMTP_ERROR_MEMORY_ALLOCATION:
                verdict = verdict ?? .outOfMemory
            case LIBMTP_ERROR_STORAGE_FULL:
                verdict = .storageFull
            case LIBMTP_ERROR_CANCELLED:
                verdict = verdict ?? .operationCancelled
            case LIBMTP_ERROR_PTP_LAYER, LIBMTP_ERROR_USB_LAYER:
                if let ptp = ptpCode(in: text), let mapped = map(ptp) {
                    verdict = mapped
                }
            default:
                break
            }

            node = current.pointee.next
        }

        LIBMTP_Clear_Errorstack(device)

        let result = verdict ?? fallback
        
        if let operation {
            log.error(
                """
                \(operation, privacy: .public): \(messages.last ?? "no diagnostic on the error stack", privacy: .public) \
                -> \(String(describing: result), privacy: .public)
                """
            )
        }
        return result
    }

    private static func ptpCode(in text: String) -> UInt16? {
        guard let colon = text.firstIndex(of: ":") else {
            return nil
        }
        let token = text[..<colon].split(separator: " ").last.map(String.init)
        guard let token, token.count == 4 else {
            return nil
        }
        return UInt16(token, radix: 16)
    }

    private static func map(_ ptp: UInt16) -> MTPError? {
        switch ptp {
        case ptpOperationNotSupported:
            return .operationUnsupported
        case ptpStoreFull:
            return .storageFull
        case ptpAccessDenied:
            return .accessDenied
        case ptpObjectWriteProtected, ptpStoreReadOnly:
            return .writeProtected
        case ptpInvalidObjectHandle, ptpInvalidParentObject:
            return .objectNotFound
        case ptpStoreNotAvailable:
            return .storageOffline
        case ptpDeviceBusy:
            return .deviceBusy
        case ptpErrorTimeout:
            return .deviceTimedOut
        case ptpErrorCancel:
            return .operationCancelled
        case ptpErrorIO:
            return .ioFailure
        case ptpInvalidObjectFormatCode, ptpNoValidObjectInfo, ptpSpecificationOfDestinationUnsupported:
            return .invalidData
        case ptpPartialDeletion:
            return .folderNotEmpty
        default:
            return nil
        }
    }
}
