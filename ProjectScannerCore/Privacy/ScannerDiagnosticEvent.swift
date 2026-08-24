import Foundation

public enum ScannerDiagnosticCode: String, Sendable, Equatable {
    case sessionStarted = "session_started"
    case detectorFinished = "detector_finished"
    case coverageLimited = "coverage_limited"
    case rootAuthorizationFailed = "root_authorization_failed"
    case keyUnavailable = "key_unavailable"
    case stateReadFailed = "state_read_failed"
    case stateWriteFailed = "state_write_failed"
}

public enum SanitizedSystemErrorCategory: String, Sendable, Equatable {
    case permissionDenied = "permission_denied"
    case unavailable
    case invalidData = "invalid_data"
    case inputOutput = "input_output"
    case resourceLimit = "resource_limit"
    case cancelled
    case unknown
}

public struct ScannerDiagnosticEvent: Sendable, Equatable {
    public let sessionID: ScanSessionID
    public let detector: DetectorID?
    public let code: ScannerDiagnosticCode
    public let reason: CoverageReasonCode?
    public let count: UInt64?
    public let bytes: UInt64?
    public let durationMilliseconds: UInt64?
    public let systemCategory: SanitizedSystemErrorCategory?
}
