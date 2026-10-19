import AutomationCore
import Foundation

/// Pure state for the fallback check. Every approval-state change invalidates the admitted connection,
/// including additions. The admitted snapshot is captured before tunnel startup and is never refreshed.
struct TunnelAuthorizationMonitor: Sendable {
    enum StopReason: Error, Equatable, Sendable, LocalizedError {
        case consentRequired, activationChanged
        var errorDescription: String? {
            switch self {
                case .consentRequired: String(localized: "AUTO_CAPTURE_CONSENT_REQUIRED")
                case .activationChanged: String(localized: "AUTO_CAPTURE_APPROVAL_CHANGED")
            }
        }
    }

    enum Decision: Equatable, Sendable { case ignore, proceed, stop(StopReason) }

    let admitted: PluginActivationSnapshot?
    private(set) var id: UUID
    private var inFlight = false

    init(admitted: PluginActivationSnapshot?, id: UUID = UUID()) {
        self.admitted = admitted; self.id = id
    }

    mutating func begin(id: UUID) -> Bool {
        guard id == self.id, !inFlight else { return false }
        inFlight = true
        return true
    }

    /// Consent is checked on every timer tick, even while an approval-file read is stalled.
    mutating func begin(id: UUID, consent: Bool) -> Decision {
        guard id == self.id else { return .ignore }
        if !consent {
            return .stop(.consentRequired)
        }
        return begin(id: id) ? .proceed : .ignore
    }

    mutating func finish(current: PluginActivationSnapshot?, consent: Bool, id: UUID) -> Decision {
        guard id == self.id, inFlight else { return .ignore }
        inFlight = false
        if !consent {
            return .stop(.consentRequired)
        }
        if current != admitted {
            return .stop(.activationChanged)
        }
        return .proceed
    }

    mutating func invalidate() {
        id = UUID(); inFlight = false
    }
}
