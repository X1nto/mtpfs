import CLibMTP
import CLibPTP
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
    case objectTooLarge
    case partialDeletion

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
            case LIBMTP_ERROR_STORAGE_FULL:
                verdict = .storageFull
            case LIBMTP_ERROR_MEMORY_ALLOCATION:
                verdict = verdict ?? .outOfMemory
            case LIBMTP_ERROR_CANCELLED:
                verdict = verdict ?? .operationCancelled
            case LIBMTP_ERROR_CONNECTING:
                verdict = verdict ?? .deviceBusy
            case LIBMTP_ERROR_GENERAL:
                verdict = verdict ?? .deviceError
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
        case UInt16(PTP_RC_OperationNotSupported):
            return .operationUnsupported
        case UInt16(PTP_RC_StoreFull):
            return .storageFull
        case UInt16(PTP_RC_AccessDenied):
            return .accessDenied
        case UInt16(PTP_RC_ObjectWriteProtected), UInt16(PTP_RC_StoreReadOnly):
            return .writeProtected
        case UInt16(PTP_RC_InvalidObjectHandle), UInt16(PTP_RC_InvalidParentObject):
            return .objectNotFound
        case UInt16(PTP_RC_StoreNotAvailable):
            return .storageOffline
        case UInt16(PTP_RC_DeviceBusy):
            return .deviceBusy
        case UInt16(PTP_ERROR_TIMEOUT):
            return .deviceTimedOut
        case UInt16(PTP_ERROR_CANCEL):
            return .operationCancelled
        case UInt16(PTP_ERROR_IO):
            return .ioFailure
        case UInt16(PTP_RC_InvalidObjectFormatCode), UInt16(PTP_RC_NoValidObjectInfo), UInt16(PTP_RC_SpecificationOfDestinationUnsupported):
            return .invalidData
        case UInt16(PTP_RC_PartialDeletion):
            return .partialDeletion
        case UInt16(PTP_RC_MTP_Object_Too_Large):
            return .objectTooLarge
        case UInt16(PTP_RC_MTP_Invalid_ObjectPropCode), UInt16(PTP_RC_MTP_Invalid_ObjectProp_Format),
             UInt16(PTP_RC_MTP_Invalid_ObjectProp_Value), UInt16(PTP_RC_MTP_Invalid_Dataset):
            return .invalidData
        case UInt16(PTP_RC_IncompleteTransfer):
            return .ioFailure
        case UInt16(PTP_RC_InvalidStorageId):
            return .storageNotReady
        case UInt16(PTP_RC_GeneralError), UInt16(PTP_RC_SessionNotOpen):
            return .deviceError
        default:
            return nil
        }
    }
}
