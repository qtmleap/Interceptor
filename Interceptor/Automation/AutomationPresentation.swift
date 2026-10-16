import AutomationCore
import AutomationRepository
import AutomationRuntime
import Foundation

/// Local, non-network failures surfaced by the foundation UI.
enum AutomationInputError: Error, Equatable {
    case storeUnavailable
    case fileTooLarge, fileUnreadable
    case sourceTooLarge, eventInvalid, configInvalid
    case fingerprintFormat
}

/// What the user may conclude about where a script or repository came from. Never "safe" or "Apple-verified".
enum AutomationTrustBadge: Equatable {
    case unsigned, signedKeyUnverified, publisherKeyVerified, localEdit, localFile

    init(_ trust: TrustState) {
        switch trust {
        case .unsignedAcknowledged: self = .unsigned
        case .signedUnverified: self = .signedKeyUnverified
        case .pinned: self = .publisherKeyVerified
        }
    }

    /// Local edits and local files never inherit the publisher's trust.
    init(_ provenance: Provenance) {
        switch provenance.origin {
        case .repository: self = provenance.trustAtImport.map(AutomationTrustBadge.init) ?? .unsigned
        case .localEdit: self = .localEdit
        case .localImport: self = .localFile
        }
    }

    var titleKey: String {
        switch self {
        case .unsigned: "AUTO_TRUST_UNSIGNED"
        case .signedKeyUnverified: "AUTO_TRUST_SIGNED_UNVERIFIED"
        case .publisherKeyVerified: "AUTO_TRUST_KEY_VERIFIED"
        case .localEdit: "AUTO_TRUST_LOCAL_EDIT"
        case .localFile: "AUTO_TRUST_LOCAL_FILE"
        }
    }

    var systemImage: String {
        switch self {
        case .unsigned: "exclamationmark.triangle"
        case .signedKeyUnverified: "questionmark.seal"
        case .publisherKeyVerified: "checkmark.seal"
        case .localEdit: "pencil"
        case .localFile: "doc"
        }
    }
}

enum AutomationErrorText {
    /// Localization key for an error. Mismatch and continuity failures have no "continue anyway" path.
    static func key(for error: Error) -> String {
        switch error {
        case let e as AutomationInputError:
            switch e {
            case .storeUnavailable: return "AUTO_ERR_STORE_UNAVAILABLE"
            case .fileTooLarge: return "AUTO_ERR_FILE_TOO_LARGE"
            case .fileUnreadable: return "AUTO_ERR_FILE_UNREADABLE"
            case .sourceTooLarge: return "AUTO_ERR_SOURCE_TOO_LARGE"
            case .eventInvalid: return "AUTO_ERR_EVENT_INVALID"
            case .configInvalid: return "AUTO_ERR_CONFIG_INVALID"
            case .fingerprintFormat: return "AUTO_ERR_FINGERPRINT_FORMAT"
            }
        case let e as AutomationError:
            switch e {
            case .invalidURL: return "AUTO_ERR_URL"
            case .fingerprintMismatch: return "AUTO_ERR_FINGERPRINT_MISMATCH"
            case .invalidSignature: return "AUTO_ERR_SIGNATURE"
            case .hashMismatch, .sizeMismatch, .metadataMismatch: return "AUTO_ERR_HASH"
            case .repositoryIdentityChanged: return "AUTO_ERR_IDENTITY"
            case .keyChanged, .signatureRemoved: return "AUTO_ERR_KEY"
            case .rollback, .sameSequenceDifferentPayload: return "AUTO_ERR_ROLLBACK"
            case .expired, .notYetValid, .lifetimeTooLong: return "AUTO_ERR_TIME"
            case .staleGeneration, .staleSnapshot: return "AUTO_ERR_STALE"
            case .corruptStore: return "AUTO_ERR_CORRUPT"
            case .saveFailed: return "AUTO_ERR_SAVE"
            case .limitExceeded: return "AUTO_ERR_LIMIT"
            case .noChange: return "AUTO_ERR_NO_CHANGE"
            case .unknownRepository, .unknownRevision: return "AUTO_ERR_UNKNOWN"
            case .acknowledgmentRequired: return "AUTO_ERR_ACK"
            case .invalidJSON, .duplicateKey, .invalidBase64, .invalidManifest: return "AUTO_ERR_FORMAT"
            }
        case let e as RepositoryClientError:
            switch e {
            case .timedOut: return "AUTO_ERR_TIMEOUT"
            case .responseTooLarge: return "AUTO_ERR_TOO_LARGE"
            case .redirected, .unexpectedStatus, .nonHTTPResponse, .transport: return "AUTO_ERR_NETWORK"
            }
        case let e as JavaScriptExecutionError:
            switch e {
            case .timeout: return "AUTO_ERR_JS_TIMEOUT"
            case .cancelled: return "AUTO_ERR_JS_CANCELLED"
            case .memoryOrStack: return "AUTO_ERR_JS_MEMORY"
            case .invalidInput: return "AUTO_ERR_JS_INPUT"
            case .invalidResult: return "AUTO_ERR_JS_RESULT"
            case .scriptError: return "AUTO_ERR_JS_SCRIPT"
            case .busy: return "AUTO_ERR_JS_BUSY"
            case .internalFailure: return "AUTO_ERR_GENERIC"
            }
        default:
            return "AUTO_ERR_GENERIC"
        }
    }
}

extension RepositoryRecord {
    var displayName: String { snapshot?.index.name ?? url.canonical }
    var keyFingerprint: PublicKeyFingerprint? {
        switch trust {
        case .signedUnverified(let k), .pinned(let k): k
        case .unsignedAcknowledged: nil
        }
    }
}

enum FingerprintInput {
    /// Lowercased full 64-hex fingerprint, or nil when the text is not exactly that.
    static func normalized(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.utf8.count == 64 && t.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }) ? t : nil
    }
}
