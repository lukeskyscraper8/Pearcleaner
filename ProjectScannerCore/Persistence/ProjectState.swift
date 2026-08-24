import Foundation

public enum ProjectStateError: Error, Sendable, Equatable {
    case notImplemented, invalidInput, invalidState, stateUnavailable, backupExclusionFailed
    case transactionBusy, cancelled, notComplete, ephemeralRun, keyResetRequired
    case identifierCollision, duplicateSuppression, suppressionLimit
}

public struct SuppressionRecord: Sendable, Equatable {
    public let fingerprint: SuppressionFingerprint
    public let ruleID: RuleID
    public let ruleVersion: UInt32
    public let createdAt: Date
    public init(fingerprint: SuppressionFingerprint, ruleID: RuleID, ruleVersion: UInt32, createdAt: Date) throws {
        guard ruleVersion > 0, persistableMilliseconds(createdAt) != nil else { throw ProjectStateError.invalidInput }
        self.fingerprint = fingerprint; self.ruleID = ruleID; self.ruleVersion = ruleVersion; self.createdAt = createdAt
    }
}

public struct AttemptSummaryMetadata: Sendable, Equatable {
    public let advisoryCacheSchemaVersion: UInt32?
    public let advisory: AdvisoryCoverageMetadata?
    public init(advisoryCacheSchemaVersion: UInt32?, advisory: AdvisoryCoverageMetadata?) throws {
        guard advisoryCacheSchemaVersion != 0,
              advisory?.lastSuccessfulRefresh.map({ persistableMilliseconds($0) != nil }) ?? true,
              advisory?.activatedAt.map({ persistableMilliseconds($0) != nil }) ?? true else { throw ProjectStateError.invalidInput }
        self.advisoryCacheSchemaVersion = advisoryCacheSchemaVersion; self.advisory = advisory
    }
}

public struct ProjectDetectorSummary: Sendable, Equatable {
    public let detector: DetectorID; public let terminalState: DetectorTerminalState
    public let candidateFiles, scannedFiles, skippedFiles, unsupportedFiles, failedFiles: UInt64
    public let candidateBytes, scannedBytes, skippedBytes, unsupportedBytes, failedBytes: UInt64
    public let reasonCounts: [CoverageReasonCode: UInt64]
}

public struct ProjectRunSummary: Sendable, Equatable {
    public let finishedAt: Date; public let terminalState: ScanTerminalState
    public let detectors: [ProjectDetectorSummary]; public let metadata: AttemptSummaryMetadata
}

public struct ProjectConfigurationSnapshot: Sendable, Equatable {
    public let projectID: ProjectID; public let label: String?; public let bookmark: ProjectBookmark
    public let scannerSchemaVersion: UInt32; public let advisoryCacheSchemaVersion: UInt32?
    public let lastCompleteSummary: ProjectRunSummary?; public let lastAttempt: ProjectRunSummary?
    public let limitOverrides: ScanLimitOverrides; public let effectiveLimits: ScanLimits; public let watchEnabled: Bool
}

public struct ProjectRegistration: Sendable, Equatable {
    public let projectID: ProjectID; public let configuration: ProjectConfigurationSnapshot; public let commit: ProjectStateCommit
}
public enum ProjectStateCommit: Sendable, Equatable { case committed, committedDurabilityUncertain }
public enum ProjectStateAccess: Sendable {
    case persistent(ProjectConfigurationSnapshot, suppressions: [SuppressionRecord], lease: ProjectKeyLease)
    case ephemeral(ProjectConfigurationSnapshot, lease: ProjectKeyLease)
    case resetRequired(ProjectConfigurationSnapshot)
}

func persistableMilliseconds(_ date: Date) -> Int64? {
    let milliseconds = date.timeIntervalSince1970 * 1000
    guard milliseconds.isFinite, milliseconds >= 0, milliseconds.rounded() == milliseconds,
          let value = Int64(exactly: milliseconds), Date(timeIntervalSince1970: Double(value) / 1000) == date else { return nil }
    return value
}

enum ProjectStateJSONCodec {
    static func encode(_ state: PersistedProjectState) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(state)
        } catch {
            throw ProjectStateError.invalidState
        }
    }

    static func decode(_ data: Data, expectedProjectID: ProjectID) throws -> PersistedProjectState {
        guard data.count <= AtomicStateFile.maximumPayloadBytes else { throw ProjectStateError.invalidState }
        do {
            try requireIntegerDateTokens(data)
            let state = try JSONDecoder().decode(PersistedProjectState.self, from: data)
            guard state.projectID == expectedProjectID.rawValue else { throw ProjectStateError.invalidState }
            return state
        } catch {
            throw ProjectStateError.invalidState
        }
    }
}

private func requireIntegerDateTokens(_ data: Data) throws {
    let object = try JSONSerialization.jsonObject(with: data)
    try inspectDateTokens(object)
}

private func inspectDateTokens(_ value: Any) throws {
    if let object = value as? [String: Any] {
        for (key, nested) in object {
            if key == "finishedAt" || key == "createdAt" {
                guard isIntegerJSONNumber(nested) else { throw ProjectStateError.invalidState }
            } else if key == "lastSuccessfulRefresh" || key == "activatedAt" {
                guard nested is NSNull || isIntegerJSONNumber(nested) else {
                    throw ProjectStateError.invalidState
                }
            }
            try inspectDateTokens(nested)
        }
    } else if let array = value as? [Any] {
        for nested in array { try inspectDateTokens(nested) }
    }
}

private func isIntegerJSONNumber(_ value: Any) -> Bool {
    guard let number = value as? NSNumber else { return false }
    switch String(cString: number.objCType) {
    case "c", "s", "i", "l", "q", "C", "S", "I", "L", "Q":
        return true
    default:
        return false
    }
}

struct PersistedProjectState: Codable, Sendable, Equatable {
    static let schema: UInt32 = 1

    let schemaVersion: UInt32
    let projectID: UUID
    var label: String?
    let bookmark: Data
    let keyGeneration: UUID
    var scannerSchemaVersion: UInt32
    var advisoryCacheSchemaVersion: UInt32?
    var lastCompleteSummary: PersistedCompleteSummary?
    var lastAttempt: PersistedAttempt?
    var limitOverrides: PersistedLimitOverrides
    var watchEnabled: Bool
    var suppressions: [PersistedSuppressionRecord]

    init(
        projectID: UUID,
        label: String?,
        bookmark: ProjectBookmark,
        keyGeneration: UUID,
        limitOverrides: ScanLimitOverrides
    ) throws {
        try validateStateLabel(label, error: .invalidInput)
        let bookmarkBytes = ProjectBookmarkPersistence.encode(bookmark)
        try validateBookmark(bookmarkBytes, error: .invalidInput)
        do { _ = try limitOverrides.applying(to: .defaults) }
        catch { throw ProjectStateError.invalidInput }
        schemaVersion = Self.schema
        self.projectID = projectID
        self.label = label
        self.bookmark = bookmarkBytes
        self.keyGeneration = keyGeneration
        scannerSchemaVersion = ScannerModule.schemaVersion
        advisoryCacheSchemaVersion = nil
        lastCompleteSummary = nil
        lastAttempt = nil
        self.limitOverrides = PersistedLimitOverrides(limitOverrides)
        watchEnabled = false
        suppressions = []
    }

    private enum CodingKeys: String, CaseIterable, CodingKey {
        case schemaVersion, projectID, label, bookmark, keyGeneration
        case scannerSchemaVersion, advisoryCacheSchemaVersion
        case lastCompleteSummary, lastAttempt, limitOverrides, watchEnabled, suppressions
    }

    init(from decoder: any Decoder) throws {
        try requireExactKeys(decoder, CodingKeys.allCases.map(\.rawValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(UInt32.self, forKey: .schemaVersion)
        projectID = try decodeCanonicalUUID(container, forKey: .projectID)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        bookmark = try decodeCanonicalBase64(container, forKey: .bookmark)
        keyGeneration = try decodeCanonicalUUID(container, forKey: .keyGeneration)
        scannerSchemaVersion = try container.decode(UInt32.self, forKey: .scannerSchemaVersion)
        advisoryCacheSchemaVersion = try container.decodeIfPresent(UInt32.self, forKey: .advisoryCacheSchemaVersion)
        lastCompleteSummary = try container.decodeIfPresent(PersistedCompleteSummary.self, forKey: .lastCompleteSummary)
        lastAttempt = try container.decodeIfPresent(PersistedAttempt.self, forKey: .lastAttempt)
        limitOverrides = try container.decode(PersistedLimitOverrides.self, forKey: .limitOverrides)
        watchEnabled = try container.decode(Bool.self, forKey: .watchEnabled)
        suppressions = try container.decode([PersistedSuppressionRecord].self, forKey: .suppressions)
        try validateDecodedState()
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(canonicalUUID(projectID), forKey: .projectID)
        if let label { try container.encode(label, forKey: .label) } else { try container.encodeNil(forKey: .label) }
        try container.encode(bookmark.base64EncodedString(), forKey: .bookmark)
        try container.encode(canonicalUUID(keyGeneration), forKey: .keyGeneration)
        try container.encode(scannerSchemaVersion, forKey: .scannerSchemaVersion)
        if let advisoryCacheSchemaVersion { try container.encode(advisoryCacheSchemaVersion, forKey: .advisoryCacheSchemaVersion) }
        else { try container.encodeNil(forKey: .advisoryCacheSchemaVersion) }
        if let lastCompleteSummary { try container.encode(lastCompleteSummary, forKey: .lastCompleteSummary) }
        else { try container.encodeNil(forKey: .lastCompleteSummary) }
        if let lastAttempt { try container.encode(lastAttempt, forKey: .lastAttempt) }
        else { try container.encodeNil(forKey: .lastAttempt) }
        try container.encode(limitOverrides, forKey: .limitOverrides)
        try container.encode(watchEnabled, forKey: .watchEnabled)
        try container.encode(suppressions, forKey: .suppressions)
    }

    private func validateDecodedState() throws {
        guard schemaVersion == Self.schema,
              scannerSchemaVersion > 0,
              scannerSchemaVersion <= ScannerModule.schemaVersion,
              advisoryCacheSchemaVersion != 0,
              suppressions.count <= 10_000 else { throw ProjectStateError.invalidState }
        try validateStateLabel(label, error: .invalidState)
        try validateBookmark(bookmark, error: .invalidState)
        _ = try ProjectBookmarkPersistence.decode(bookmark)
        _ = try limitOverrides.value.applying(to: .defaults)
        var fingerprints = Set<Data>()
        guard suppressions.allSatisfy({ fingerprints.insert($0.fingerprint).inserted }) else {
            throw ProjectStateError.invalidState
        }
        if let attempt = lastAttempt, attempt.terminalState == .complete {
            guard let complete = lastCompleteSummary, complete.asAttempt == attempt else {
                throw ProjectStateError.invalidState
            }
        }
        if let complete = lastCompleteSummary, complete.terminalState != .complete {
            throw ProjectStateError.invalidState
        }
        if lastCompleteSummary != nil, lastAttempt == nil {
            throw ProjectStateError.invalidState
        }
        guard advisoryCacheSchemaVersion == lastAttempt?.metadata.advisoryCacheSchemaVersion else {
            throw ProjectStateError.invalidState
        }
    }
}

struct PersistedSuppressionRecord: Codable, Sendable, Equatable {
    let fingerprint: Data
    let ruleID: RuleID
    let ruleVersion: UInt32
    let createdAt: Date

    init(_ value: SuppressionRecord) {
        fingerprint = SuppressionFingerprintPersistence.encode(value.fingerprint)
        ruleID = value.ruleID
        ruleVersion = value.ruleVersion
        createdAt = value.createdAt
    }

    private enum CodingKeys: String, CaseIterable, CodingKey {
        case fingerprint, ruleID, ruleVersion, createdAt
    }

    init(from decoder: any Decoder) throws {
        try requireExactKeys(decoder, CodingKeys.allCases.map(\.rawValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fingerprint = try decodeCanonicalBase64(container, forKey: .fingerprint)
        let rawRuleID = try container.decode(String.self, forKey: .ruleID)
        guard let decodedRuleID = RuleID(rawValue: rawRuleID) else { throw ProjectStateError.invalidState }
        ruleID = decodedRuleID
        ruleVersion = try container.decode(UInt32.self, forKey: .ruleVersion)
        createdAt = try decodeMilliseconds(container, forKey: .createdAt)
        guard ruleVersion > 0 else { throw ProjectStateError.invalidState }
        _ = try SuppressionFingerprintPersistence.decode(fingerprint)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fingerprint.base64EncodedString(), forKey: .fingerprint)
        try container.encode(ruleID.rawValue, forKey: .ruleID)
        try container.encode(ruleVersion, forKey: .ruleVersion)
        try container.encode(try requiredMilliseconds(createdAt), forKey: .createdAt)
    }

    var publicValue: SuppressionRecord {
        get throws {
            try SuppressionRecord(
                fingerprint: SuppressionFingerprintPersistence.decode(fingerprint),
                ruleID: ruleID,
                ruleVersion: ruleVersion,
                createdAt: createdAt
            )
        }
    }
}

struct PersistedLimitOverrides: Codable, Sendable, Equatable {
    let generalFiles, secretFileBytes, lockfileBytes, manifestBytes: UInt64?
    let installedManifests, directories, directoryEntries: UInt64?
    let dependencyNodesPerLockfile, dependencyNodesPerSession, inputBytes, wallTimeMilliseconds: UInt64?

    init(_ value: ScanLimitOverrides) {
        generalFiles = value.generalFiles; secretFileBytes = value.secretFileBytes
        lockfileBytes = value.lockfileBytes; manifestBytes = value.manifestBytes
        installedManifests = value.installedManifests; directories = value.directories
        directoryEntries = value.directoryEntries
        dependencyNodesPerLockfile = value.dependencyNodesPerLockfile
        dependencyNodesPerSession = value.dependencyNodesPerSession
        inputBytes = value.inputBytes; wallTimeMilliseconds = value.wallTimeMilliseconds
    }

    var value: ScanLimitOverrides {
        ScanLimitOverrides(
            generalFiles: generalFiles, secretFileBytes: secretFileBytes,
            lockfileBytes: lockfileBytes, manifestBytes: manifestBytes,
            installedManifests: installedManifests, directories: directories,
            directoryEntries: directoryEntries,
            dependencyNodesPerLockfile: dependencyNodesPerLockfile,
            dependencyNodesPerSession: dependencyNodesPerSession,
            inputBytes: inputBytes, wallTimeMilliseconds: wallTimeMilliseconds
        )
    }

    private enum CodingKeys: String, CaseIterable, CodingKey {
        case generalFiles, secretFileBytes, lockfileBytes, manifestBytes, installedManifests
        case directories, directoryEntries, dependencyNodesPerLockfile
        case dependencyNodesPerSession, inputBytes, wallTimeMilliseconds
    }

    init(from decoder: any Decoder) throws {
        try requireExactKeys(decoder, CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generalFiles = try c.decodeIfPresent(UInt64.self, forKey: .generalFiles)
        secretFileBytes = try c.decodeIfPresent(UInt64.self, forKey: .secretFileBytes)
        lockfileBytes = try c.decodeIfPresent(UInt64.self, forKey: .lockfileBytes)
        manifestBytes = try c.decodeIfPresent(UInt64.self, forKey: .manifestBytes)
        installedManifests = try c.decodeIfPresent(UInt64.self, forKey: .installedManifests)
        directories = try c.decodeIfPresent(UInt64.self, forKey: .directories)
        directoryEntries = try c.decodeIfPresent(UInt64.self, forKey: .directoryEntries)
        dependencyNodesPerLockfile = try c.decodeIfPresent(UInt64.self, forKey: .dependencyNodesPerLockfile)
        dependencyNodesPerSession = try c.decodeIfPresent(UInt64.self, forKey: .dependencyNodesPerSession)
        inputBytes = try c.decodeIfPresent(UInt64.self, forKey: .inputBytes)
        wallTimeMilliseconds = try c.decodeIfPresent(UInt64.self, forKey: .wallTimeMilliseconds)
        do { _ = try value.applying(to: .defaults) } catch { throw ProjectStateError.invalidState }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try encodeOptional(generalFiles, to: &c, key: .generalFiles)
        try encodeOptional(secretFileBytes, to: &c, key: .secretFileBytes)
        try encodeOptional(lockfileBytes, to: &c, key: .lockfileBytes)
        try encodeOptional(manifestBytes, to: &c, key: .manifestBytes)
        try encodeOptional(installedManifests, to: &c, key: .installedManifests)
        try encodeOptional(directories, to: &c, key: .directories)
        try encodeOptional(directoryEntries, to: &c, key: .directoryEntries)
        try encodeOptional(dependencyNodesPerLockfile, to: &c, key: .dependencyNodesPerLockfile)
        try encodeOptional(dependencyNodesPerSession, to: &c, key: .dependencyNodesPerSession)
        try encodeOptional(inputBytes, to: &c, key: .inputBytes)
        try encodeOptional(wallTimeMilliseconds, to: &c, key: .wallTimeMilliseconds)
    }
}

struct PersistedAttemptMetadata: Codable, Sendable, Equatable {
    let advisoryCacheSchemaVersion: UInt32?
    let advisory: PersistedAdvisoryMetadata?

    init(_ value: AttemptSummaryMetadata) {
        advisoryCacheSchemaVersion = value.advisoryCacheSchemaVersion
        advisory = value.advisory.map(PersistedAdvisoryMetadata.init)
    }

    private enum CodingKeys: String, CaseIterable, CodingKey {
        case advisoryCacheSchemaVersion, advisory
    }

    init(from decoder: any Decoder) throws {
        try requireExactKeys(decoder, CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        advisoryCacheSchemaVersion = try c.decodeIfPresent(UInt32.self, forKey: .advisoryCacheSchemaVersion)
        advisory = try c.decodeIfPresent(PersistedAdvisoryMetadata.self, forKey: .advisory)
        guard advisoryCacheSchemaVersion != 0,
              advisoryCacheSchemaVersion != nil || advisory == nil else {
            throw ProjectStateError.invalidState
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try encodeOptional(advisoryCacheSchemaVersion, to: &c, key: .advisoryCacheSchemaVersion)
        try encodeOptional(advisory, to: &c, key: .advisory)
    }

    var publicValue: AttemptSummaryMetadata {
        get throws {
            try AttemptSummaryMetadata(
                advisoryCacheSchemaVersion: advisoryCacheSchemaVersion,
                advisory: try advisory?.publicValue
            )
        }
    }
}

struct PersistedAdvisoryMetadata: Codable, Sendable, Equatable {
    let generation: UUID
    let source: AdvisorySource
    let ageSeconds: UInt64
    let lastSuccessfulRefresh: Date?
    let activatedAt: Date?
    let validation: PersistedAdvisoryValidation

    init(_ value: AdvisoryCoverageMetadata) {
        generation = value.generation
        source = value.source
        ageSeconds = value.ageSeconds
        lastSuccessfulRefresh = value.lastSuccessfulRefresh
        activatedAt = value.activatedAt
        validation = PersistedAdvisoryValidation(value.validation)
    }

    private enum CodingKeys: String, CaseIterable, CodingKey {
        case generation, source, ageSeconds, lastSuccessfulRefresh, activatedAt, validation
    }

    init(from decoder: any Decoder) throws {
        try requireExactKeys(decoder, CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generation = try decodeCanonicalUUID(c, forKey: .generation)
        let rawSource = try c.decode(String.self, forKey: .source)
        guard rawSource == "osv" else { throw ProjectStateError.invalidState }
        source = .osv
        ageSeconds = try c.decode(UInt64.self, forKey: .ageSeconds)
        lastSuccessfulRefresh = try decodeOptionalMilliseconds(c, forKey: .lastSuccessfulRefresh)
        activatedAt = try decodeOptionalMilliseconds(c, forKey: .activatedAt)
        validation = try c.decode(PersistedAdvisoryValidation.self, forKey: .validation)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(canonicalUUID(generation), forKey: .generation)
        try c.encode("osv", forKey: .source)
        try c.encode(ageSeconds, forKey: .ageSeconds)
        if let lastSuccessfulRefresh { try c.encode(try requiredMilliseconds(lastSuccessfulRefresh), forKey: .lastSuccessfulRefresh) }
        else { try c.encodeNil(forKey: .lastSuccessfulRefresh) }
        if let activatedAt { try c.encode(try requiredMilliseconds(activatedAt), forKey: .activatedAt) }
        else { try c.encodeNil(forKey: .activatedAt) }
        try c.encode(validation, forKey: .validation)
    }

    var publicValue: AdvisoryCoverageMetadata {
        get throws {
            AdvisoryCoverageMetadata(
                generation: generation,
                source: source,
                ageSeconds: ageSeconds,
                lastSuccessfulRefresh: lastSuccessfulRefresh,
                activatedAt: activatedAt,
                validation: validation.publicValue
            )
        }
    }
}

struct PersistedAdvisoryValidation: Codable, Sendable, Equatable {
    enum State: String, Sendable { case absent, complete, partial, unavailable }
    let state: State
    let reason: CoverageReasonCode?

    init(_ value: AdvisoryValidationState) {
        switch value {
        case .absent: state = .absent; reason = nil
        case .complete: state = .complete; reason = nil
        case .partial(let value): state = .partial; reason = value
        case .unavailable(let value): state = .unavailable; reason = value
        }
    }

    private enum CodingKeys: String, CaseIterable, CodingKey { case state, reason }

    init(from decoder: any Decoder) throws {
        try requireExactKeys(decoder, CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawState = try c.decode(String.self, forKey: .state)
        guard let decodedState = State(rawValue: rawState) else { throw ProjectStateError.invalidState }
        state = decodedState
        if let rawReason = try c.decodeIfPresent(String.self, forKey: .reason) {
            guard let value = CoverageReasonCode(rawValue: rawReason) else { throw ProjectStateError.invalidState }
            reason = value
        } else { reason = nil }
        switch state {
        case .absent, .complete: guard reason == nil else { throw ProjectStateError.invalidState }
        case .partial, .unavailable: guard reason != nil else { throw ProjectStateError.invalidState }
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(state.rawValue, forKey: .state)
        if let reason { try c.encode(reason.rawValue, forKey: .reason) }
        else { try c.encodeNil(forKey: .reason) }
    }

    var publicValue: AdvisoryValidationState {
        switch state {
        case .absent: return .absent
        case .complete: return .complete
        case .partial: return .partial(reason!)
        case .unavailable: return .unavailable(reason!)
        }
    }
}

struct PersistedReasonCount: Codable, Sendable, Equatable {
    let reason: CoverageReasonCode
    let count: UInt64

    private enum CodingKeys: String, CaseIterable, CodingKey { case reason, count }

    init(reason: CoverageReasonCode, count: UInt64) {
        self.reason = reason; self.count = count
    }

    init(from decoder: any Decoder) throws {
        try requireExactKeys(decoder, CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawReason = try c.decode(String.self, forKey: .reason)
        guard let decodedReason = CoverageReasonCode(rawValue: rawReason) else {
            throw ProjectStateError.invalidState
        }
        reason = decodedReason
        count = try c.decode(UInt64.self, forKey: .count)
        guard count > 0 else { throw ProjectStateError.invalidState }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(reason.rawValue, forKey: .reason)
        try c.encode(count, forKey: .count)
    }
}

struct PersistedDetectorCoverage: Codable, Sendable, Equatable {
    let detector: DetectorID
    let terminalState: DetectorTerminalState
    let candidateFiles, scannedFiles, skippedFiles, unsupportedFiles, failedFiles: UInt64
    let candidateBytes, scannedBytes, skippedBytes, unsupportedBytes, failedBytes: UInt64
    let reasonCounts: [PersistedReasonCount]

    init(_ value: DetectorCoverageSnapshot, inputError: ProjectStateError) throws {
        detector = value.detector; terminalState = value.terminalState
        candidateFiles = value.candidateFiles; scannedFiles = value.scannedFiles
        skippedFiles = value.skippedFiles; unsupportedFiles = value.unsupportedFiles
        failedFiles = value.failedFiles; candidateBytes = value.candidateBytes
        scannedBytes = value.scannedBytes; skippedBytes = value.skippedBytes
        unsupportedBytes = value.unsupportedBytes; failedBytes = value.failedBytes
        reasonCounts = value.reasonCounts
            .filter { $0.value > 0 }
            .map { PersistedReasonCount(reason: $0.key, count: $0.value) }
            .sorted { $0.reason.rawValue < $1.reason.rawValue }
        try validate(error: inputError)
    }

    private enum CodingKeys: String, CaseIterable, CodingKey {
        case detector, terminalState, candidateFiles, scannedFiles, skippedFiles
        case unsupportedFiles, failedFiles, candidateBytes, scannedBytes, skippedBytes
        case unsupportedBytes, failedBytes, reasonCounts
    }

    init(from decoder: any Decoder) throws {
        try requireExactKeys(decoder, CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawDetector = try c.decode(String.self, forKey: .detector)
        let rawTerminal = try c.decode(String.self, forKey: .terminalState)
        guard let decodedDetector = DetectorID(rawValue: rawDetector),
              let decodedTerminal = DetectorTerminalState(rawValue: rawTerminal) else {
            throw ProjectStateError.invalidState
        }
        detector = decodedDetector; terminalState = decodedTerminal
        candidateFiles = try c.decode(UInt64.self, forKey: .candidateFiles)
        scannedFiles = try c.decode(UInt64.self, forKey: .scannedFiles)
        skippedFiles = try c.decode(UInt64.self, forKey: .skippedFiles)
        unsupportedFiles = try c.decode(UInt64.self, forKey: .unsupportedFiles)
        failedFiles = try c.decode(UInt64.self, forKey: .failedFiles)
        candidateBytes = try c.decode(UInt64.self, forKey: .candidateBytes)
        scannedBytes = try c.decode(UInt64.self, forKey: .scannedBytes)
        skippedBytes = try c.decode(UInt64.self, forKey: .skippedBytes)
        unsupportedBytes = try c.decode(UInt64.self, forKey: .unsupportedBytes)
        failedBytes = try c.decode(UInt64.self, forKey: .failedBytes)
        reasonCounts = try c.decode([PersistedReasonCount].self, forKey: .reasonCounts)
        try validate(error: .invalidState)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(detector.rawValue, forKey: .detector)
        try c.encode(terminalState.rawValue, forKey: .terminalState)
        try c.encode(candidateFiles, forKey: .candidateFiles); try c.encode(scannedFiles, forKey: .scannedFiles)
        try c.encode(skippedFiles, forKey: .skippedFiles); try c.encode(unsupportedFiles, forKey: .unsupportedFiles)
        try c.encode(failedFiles, forKey: .failedFiles); try c.encode(candidateBytes, forKey: .candidateBytes)
        try c.encode(scannedBytes, forKey: .scannedBytes); try c.encode(skippedBytes, forKey: .skippedBytes)
        try c.encode(unsupportedBytes, forKey: .unsupportedBytes); try c.encode(failedBytes, forKey: .failedBytes)
        try c.encode(reasonCounts, forKey: .reasonCounts)
    }

    private func validate(error: ProjectStateError) throws {
        guard let fileOutcomes = checkedSum(scannedFiles, skippedFiles, unsupportedFiles, failedFiles),
              let byteOutcomes = checkedSum(scannedBytes, skippedBytes, unsupportedBytes, failedBytes),
              fileOutcomes <= candidateFiles,
              byteOutcomes <= candidateBytes else { throw error }
        var reasons = Set<CoverageReasonCode>()
        guard reasonCounts.allSatisfy({ $0.count > 0 && reasons.insert($0.reason).inserted }) else {
            throw error
        }
        if terminalState == .complete {
            guard scannedFiles == candidateFiles,
                  skippedFiles == 0,
                  unsupportedFiles == 0,
                  failedFiles == 0,
                  scannedBytes == candidateBytes,
                  skippedBytes == 0,
                  unsupportedBytes == 0,
                  failedBytes == 0,
                  reasonCounts.isEmpty else { throw error }
        }
    }

    var publicValue: ProjectDetectorSummary {
        ProjectDetectorSummary(
            detector: detector, terminalState: terminalState,
            candidateFiles: candidateFiles, scannedFiles: scannedFiles,
            skippedFiles: skippedFiles, unsupportedFiles: unsupportedFiles,
            failedFiles: failedFiles, candidateBytes: candidateBytes,
            scannedBytes: scannedBytes, skippedBytes: skippedBytes,
            unsupportedBytes: unsupportedBytes, failedBytes: failedBytes,
            reasonCounts: Dictionary(uniqueKeysWithValues: reasonCounts.map { ($0.reason, $0.count) })
        )
    }
}

struct PersistedAttempt: Codable, Sendable, Equatable {
    let finishedAt: Date
    let terminalState: ScanTerminalState
    let detectors: [PersistedDetectorCoverage]
    let metadata: PersistedAttemptMetadata

    init(
        coverage: ScanCoverageSnapshot,
        finishedAt: Date,
        metadata: AttemptSummaryMetadata
    ) throws {
        guard persistableMilliseconds(finishedAt) != nil else {
            throw ProjectStateError.invalidInput
        }
        self.finishedAt = finishedAt
        terminalState = coverage.terminalState
        detectors = try coverage.detectors.map {
            try PersistedDetectorCoverage($0, inputError: .invalidInput)
        }
        self.metadata = PersistedAttemptMetadata(metadata)
        try validate(error: .invalidInput, coverage: coverage, suppliedMetadata: metadata)
    }

    private enum CodingKeys: String, CaseIterable, CodingKey {
        case finishedAt, terminalState, detectors, metadata
    }

    init(from decoder: any Decoder) throws {
        try requireExactKeys(decoder, CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        finishedAt = try decodeMilliseconds(c, forKey: .finishedAt)
        let rawTerminalState = try c.decode(String.self, forKey: .terminalState)
        guard let decodedTerminalState = ScanTerminalState(rawValue: rawTerminalState) else {
            throw ProjectStateError.invalidState
        }
        terminalState = decodedTerminalState
        detectors = try c.decode([PersistedDetectorCoverage].self, forKey: .detectors)
        metadata = try c.decode(PersistedAttemptMetadata.self, forKey: .metadata)
        try validate(error: .invalidState, coverage: nil, suppliedMetadata: nil)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(try requiredMilliseconds(finishedAt), forKey: .finishedAt)
        try c.encode(terminalState.rawValue, forKey: .terminalState)
        try c.encode(detectors, forKey: .detectors)
        try c.encode(metadata, forKey: .metadata)
    }

    private func validate(
        error: ProjectStateError,
        coverage: ScanCoverageSnapshot?,
        suppliedMetadata: AttemptSummaryMetadata?
    ) throws {
        guard detectors.count == DetectorID.allCases.count else { throw error }
        var detectorIDs = Set<DetectorID>()
        guard detectors.allSatisfy({ detectorIDs.insert($0.detector).inserted }),
              detectorIDs == Set(DetectorID.allCases) else { throw error }

        if terminalState == .complete {
            guard detectors.allSatisfy({ $0.terminalState == .complete }),
                  metadata.advisoryCacheSchemaVersion != nil,
                  let advisory = metadata.advisory,
                  advisory.validation.state == .complete else { throw error }
        }

        if let coverage, let suppliedMetadata {
            let advisoryDetails = coverage.detectors.flatMap { detector in
                detector.details.compactMap { detail -> AdvisoryCoverageMetadata? in
                    guard case .advisory(let advisory) = detail else { return nil }
                    return advisory
                }
            }
            if let supplied = suppliedMetadata.advisory {
                guard advisoryDetails.count == 1, advisoryDetails.first == supplied else {
                    throw error
                }
            } else {
                guard advisoryDetails.isEmpty else { throw error }
            }
            guard suppliedMetadata.advisoryCacheSchemaVersion != nil
                    || suppliedMetadata.advisory == nil else { throw error }
        } else {
            guard metadata.advisoryCacheSchemaVersion != nil || metadata.advisory == nil else {
                throw error
            }
        }
    }

    var publicValue: ProjectRunSummary {
        get throws {
            ProjectRunSummary(
                finishedAt: finishedAt,
                terminalState: terminalState,
                detectors: detectors.map(\.publicValue),
                metadata: try metadata.publicValue
            )
        }
    }
}

struct PersistedCompleteSummary: Codable, Sendable, Equatable {
    let finishedAt: Date
    let terminalState: ScanTerminalState
    let detectors: [PersistedDetectorCoverage]
    let metadata: PersistedAttemptMetadata

    init(
        coverage: ScanCoverageSnapshot,
        finishedAt: Date,
        metadata: AttemptSummaryMetadata
    ) throws {
        guard coverage.terminalState == .complete else { throw ProjectStateError.notComplete }
        let attempt = try PersistedAttempt(
            coverage: coverage,
            finishedAt: finishedAt,
            metadata: metadata
        )
        guard attempt.detectors.allSatisfy({ $0.terminalState == .complete }) else {
            throw ProjectStateError.invalidInput
        }
        self.init(attempt: attempt)
    }

    private init(attempt: PersistedAttempt) {
        finishedAt = attempt.finishedAt
        terminalState = attempt.terminalState
        detectors = attempt.detectors
        metadata = attempt.metadata
    }

    private enum CodingKeys: String, CaseIterable, CodingKey {
        case finishedAt, terminalState, detectors, metadata
    }

    init(from decoder: any Decoder) throws {
        try requireExactKeys(decoder, CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        finishedAt = try decodeMilliseconds(c, forKey: .finishedAt)
        let rawTerminalState = try c.decode(String.self, forKey: .terminalState)
        guard rawTerminalState == ScanTerminalState.complete.rawValue else {
            throw ProjectStateError.invalidState
        }
        terminalState = .complete
        detectors = try c.decode([PersistedDetectorCoverage].self, forKey: .detectors)
        metadata = try c.decode(PersistedAttemptMetadata.self, forKey: .metadata)
        guard detectors.count == DetectorID.allCases.count,
              Set(detectors.map(\.detector)) == Set(DetectorID.allCases),
              detectors.allSatisfy({ $0.terminalState == .complete }),
              metadata.advisoryCacheSchemaVersion != nil,
              let advisory = metadata.advisory,
              advisory.validation.state == .complete else {
            throw ProjectStateError.invalidState
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(try requiredMilliseconds(finishedAt), forKey: .finishedAt)
        try c.encode(ScanTerminalState.complete.rawValue, forKey: .terminalState)
        try c.encode(detectors, forKey: .detectors)
        try c.encode(metadata, forKey: .metadata)
    }

    var asAttempt: PersistedAttempt {
        PersistedAttempt(
            decodedFinishedAt: finishedAt,
            terminalState: terminalState,
            detectors: detectors,
            metadata: metadata
        )
    }

    var publicValue: ProjectRunSummary {
        get throws { try asAttempt.publicValue }
    }
}

private extension PersistedAttempt {
    init(
        decodedFinishedAt: Date,
        terminalState: ScanTerminalState,
        detectors: [PersistedDetectorCoverage],
        metadata: PersistedAttemptMetadata
    ) {
        finishedAt = decodedFinishedAt
        self.terminalState = terminalState
        self.detectors = detectors
        self.metadata = metadata
    }
}

extension PersistedProjectState {
    var configuration: ProjectConfigurationSnapshot {
        get throws {
            let overrides = limitOverrides.value
            return ProjectConfigurationSnapshot(
                projectID: ProjectID(rawValue: projectID),
                label: label,
                bookmark: try ProjectBookmarkPersistence.decode(bookmark),
                scannerSchemaVersion: scannerSchemaVersion,
                advisoryCacheSchemaVersion: advisoryCacheSchemaVersion,
                lastCompleteSummary: try lastCompleteSummary?.publicValue,
                lastAttempt: try lastAttempt?.publicValue,
                limitOverrides: overrides,
                effectiveLimits: try overrides.applying(to: .defaults),
                watchEnabled: watchEnabled
            )
        }
    }
}

private struct AnyProjectStateCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func requireExactKeys(_ decoder: any Decoder, _ expected: [String]) throws {
    let container = try decoder.container(keyedBy: AnyProjectStateCodingKey.self)
    guard Set(container.allKeys.map(\.stringValue)) == Set(expected),
          container.allKeys.count == expected.count else {
        throw ProjectStateError.invalidState
    }
}

private func canonicalUUID(_ value: UUID) -> String {
    value.uuidString.lowercased()
}

private func decodeCanonicalUUID<Key: CodingKey>(
    _ container: KeyedDecodingContainer<Key>,
    forKey key: Key
) throws -> UUID {
    let raw = try container.decode(String.self, forKey: key)
    guard let value = UUID(uuidString: raw), canonicalUUID(value) == raw else {
        throw ProjectStateError.invalidState
    }
    return value
}

private func decodeCanonicalBase64<Key: CodingKey>(
    _ container: KeyedDecodingContainer<Key>,
    forKey key: Key
) throws -> Data {
    let raw = try container.decode(String.self, forKey: key)
    guard let data = Data(base64Encoded: raw), data.base64EncodedString() == raw else {
        throw ProjectStateError.invalidState
    }
    return data
}

private func decodeMilliseconds<Key: CodingKey>(
    _ container: KeyedDecodingContainer<Key>,
    forKey key: Key
) throws -> Date {
    let milliseconds = try container.decode(Int64.self, forKey: key)
    guard milliseconds >= 0 else { throw ProjectStateError.invalidState }
    let date = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    guard persistableMilliseconds(date) == milliseconds else {
        throw ProjectStateError.invalidState
    }
    return date
}

private func decodeOptionalMilliseconds<Key: CodingKey>(
    _ container: KeyedDecodingContainer<Key>,
    forKey key: Key
) throws -> Date? {
    guard try !container.decodeNil(forKey: key) else { return nil }
    return try decodeMilliseconds(container, forKey: key)
}

private func requiredMilliseconds(_ date: Date) throws -> Int64 {
    guard let milliseconds = persistableMilliseconds(date) else {
        throw ProjectStateError.invalidState
    }
    return milliseconds
}

private func encodeOptional<Value: Encodable, Key: CodingKey>(
    _ value: Value?,
    to container: inout KeyedEncodingContainer<Key>,
    key: Key
) throws {
    if let value { try container.encode(value, forKey: key) }
    else { try container.encodeNil(forKey: key) }
}

private func checkedSum(_ values: UInt64...) -> UInt64? {
    var total: UInt64 = 0
    for value in values {
        let result = total.addingReportingOverflow(value)
        guard !result.overflow else { return nil }
        total = result.partialValue
    }
    return total
}

private func validateStateLabel(_ label: String?, error: ProjectStateError) throws {
    guard let label else { return }
    guard label.unicodeScalars.count <= 200,
          !label.unicodeScalars.contains(where: isDisallowedProjectStateScalar) else {
        throw error
    }
}

private func isDisallowedProjectStateScalar(_ scalar: Unicode.Scalar) -> Bool {
    if CharacterSet.controlCharacters.contains(scalar) { return true }
    switch scalar.value {
    case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
        return true
    default:
        return false
    }
}

private func validateBookmark(_ bookmark: Data, error: ProjectStateError) throws {
    guard !bookmark.isEmpty, bookmark.count <= 1_048_576 else { throw error }
    do { _ = try ProjectBookmarkPersistence.decode(bookmark) }
    catch { throw error }
}
