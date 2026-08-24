import Foundation

public struct ProjectID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct ScanSessionID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct CoverageTransactionID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public enum DetectorID: String, Codable, CaseIterable, Sendable {
    case secret
    case nodeLockfile = "node_lockfile"
    case advisory
    case lifecycle
    case gitEvidence = "git_evidence"
}

public enum FindingKind: String, Codable, Sendable {
    case probableSecret = "probable_secret"
    case vulnerability
    case maliciousPackage = "malicious_package"
    case lifecycleDeclaration = "lifecycle_declaration"
}

public struct RuleID: Hashable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard Self.isValid(rawValue) else {
            return nil
        }
        self.rawValue = rawValue
    }

    private static func isValid(_ rawValue: String) -> Bool {
        !rawValue.isEmpty && !rawValue.unicodeScalars.contains(where: isDisallowedScalar)
    }
}

public enum SourceView: String, Codable, Sendable {
    case workingTree = "working_tree"
    case index
    case currentHead = "current_head"
}

public enum DetectorTerminalState: String, Codable, Sendable {
    case complete
    case partial
    case cancelled
    case failed
    case unavailable
    case disabled
}

public enum ScanTerminalState: String, Codable, Sendable {
    case complete
    case partial
    case cancelled
    case failed
    case unavailable
}

public enum CoverageReasonCode: String, Codable, CaseIterable, Sendable {
    case externalBoundary = "external_boundary"
    case mountBoundary = "mount_boundary"
    case identityChanged = "identity_changed"
    case unreadable
    case binary
    case ordinaryFileTooLarge = "ordinary_file_too_large"
    case lockfileTooLarge = "lockfile_too_large"
    case manifestTooLarge = "manifest_too_large"
    case unsupportedLockRevision = "unsupported_lock_revision"
    case unsupportedCoordinate = "unsupported_coordinate"
    case gitPreflightRejected = "git_preflight_rejected"
    case gitIgnoreUnsupported = "git_ignore_unsupported"
    case gitDescriptorBudget = "git_descriptor_budget"
    case gitTimeout = "git_timeout"
    case advisoryCacheMissing = "advisory_cache_missing"
    case globalByteBudget = "global_byte_budget"
    case wallTimeBudget = "wall_time_budget"
    case specialFile = "special_file"
    case symlinkCycle = "symlink_cycle"
    case linkHopLimit = "link_hop_limit"
    case directoryBudget = "directory_budget"
    case entryBudget = "entry_budget"
    case pathTooLong = "path_too_long"
    case cancelled
}

public enum FindingConfidence: String, Sendable, Equatable {
    case high
    case reviewSuggested = "review_suggested"
}

public enum AdvisorySource: String, Sendable, Equatable {
    case osv
}

public struct UpstreamSeverity: Sendable, Equatable {
    let scheme: String
    let value: String

    init?(scheme: String, value: String) {
        guard Self.isValid(scheme), Self.isValid(value) else {
            return nil
        }
        self.scheme = scheme
        self.value = value
    }

    private static func isValid(_ value: String) -> Bool {
        !value.isEmpty
            && value.unicodeScalars.count <= 256
            && !value.unicodeScalars.contains(where: isDisallowedScalar)
    }
}

public enum FindingAssessment: Sendable, Equatable {
    case confidence(FindingConfidence)
    case upstreamSeverity([UpstreamSeverity])
    case sourceClassifiedMaliciousPackage(AdvisorySource)
}

public enum FindingProvenance: Sendable, Equatable {
    case secretRule
    case advisory(source: AdvisorySource, generation: UUID)
    case lifecycleRule
}

public enum SuppressionIneligibilityReason: Sendable, Equatable {
    case unstableIdentity
    case rulePolicy
    case ephemeralKeyState
}

public enum SuppressionEligibility: Sendable, Equatable {
    case eligible
    case ineligible(SuppressionIneligibilityReason)
}

public enum SessionSuppressionState: Sendable, Equatable {
    case notSuppressed
    case suppressed
    case unavailableEphemeral
    case keyResetRequired
}

private func isDisallowedScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
        return true
    default:
        return scalar.properties.generalCategory == .control
    }
}
