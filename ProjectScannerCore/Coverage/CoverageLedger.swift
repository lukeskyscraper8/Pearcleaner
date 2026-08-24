import Foundation

public struct DetectorExecutionPlan: Sendable, Equatable {
    public static let allEnabled = DetectorExecutionPlan(detectors: DetectorID.allCases)

    fileprivate let detectors: [DetectorID]

    private init(detectors: [DetectorID]) {
        self.detectors = detectors
    }
}

public enum CoverageDelta: Sendable, Equatable {
    case candidate(files: UInt64, bytes: UInt64)
    case scanned(files: UInt64, bytes: UInt64)
    case skipped(reason: CoverageReasonCode, files: UInt64, bytes: UInt64)
    case unsupported(reason: CoverageReasonCode, files: UInt64, bytes: UInt64)
    case failed(reason: CoverageReasonCode, files: UInt64, bytes: UInt64)
}

public struct RepositoryCoverageID: Hashable, Sendable {
    public let rawValue: UUID

    public init() {
        rawValue = UUID()
    }
}

public enum GitPreflightStatus: Sendable, Equatable {
    case absent
    case complete
    case partial(CoverageReasonCode)
    case unavailable(CoverageReasonCode)
}

public enum GitOperationStatus: Sendable, Equatable {
    case absent
    case complete
    case partial(CoverageReasonCode)
    case unavailable(CoverageReasonCode)
}

public enum LockfileFormat: Sendable, Equatable {
    case npmPackageLock
    case yarnClassic
    case yarnBerry
    case pnpm
}

public enum LockfileCoverageStatus: Sendable, Equatable {
    case absent
    case complete
    case partial(CoverageReasonCode)
    case unavailable(CoverageReasonCode)
}

public enum CoordinateCoverageStatus: Sendable, Equatable {
    case absent
    case complete
    case partial(CoverageReasonCode)
    case unavailable(CoverageReasonCode)
}

public enum InstalledManifestAvailability: Sendable, Equatable {
    case absent
    case complete
    case partial(CoverageReasonCode)
    case unavailable(CoverageReasonCode)
}

public enum CompetingLockfileState: Sendable, Equatable {
    case absent
    case complete(count: UInt64)
    case partial(count: UInt64, reason: CoverageReasonCode)
    case unavailable(CoverageReasonCode)
}

public enum AdvisoryValidationState: Sendable, Equatable {
    case absent
    case complete
    case partial(CoverageReasonCode)
    case unavailable(CoverageReasonCode)
}

public struct AdvisoryCoverageMetadata: Sendable, Equatable {
    public let generation: UUID
    public let source: AdvisorySource
    public let ageSeconds: UInt64
    public let lastSuccessfulRefresh: Date?
    public let activatedAt: Date?
    public let validation: AdvisoryValidationState

    public init(
        generation: UUID,
        source: AdvisorySource,
        ageSeconds: UInt64,
        lastSuccessfulRefresh: Date?,
        activatedAt: Date?,
        validation: AdvisoryValidationState
    ) {
        self.generation = generation
        self.source = source
        self.ageSeconds = ageSeconds
        self.lastSuccessfulRefresh = lastSuccessfulRefresh
        self.activatedAt = activatedAt
        self.validation = validation
    }
}

public enum DetectorCoverageDetail: Sendable, Equatable {
    case gitRepository(
        RepositoryCoverageID,
        preflight: GitPreflightStatus,
        operation: GitOperationStatus
    )
    case lockfile(format: LockfileFormat, status: LockfileCoverageStatus)
    case coordinates(status: CoordinateCoverageStatus, count: UInt64)
    case installedManifests(InstalledManifestAvailability, count: UInt64)
    case competingLockfiles(CompetingLockfileState)
    case advisory(AdvisoryCoverageMetadata)
}

public struct DetectorCoverageSnapshot: Sendable, Equatable {
    public let transactionID: CoverageTransactionID
    public let detector: DetectorID
    public let terminalState: DetectorTerminalState
    public let candidateFiles: UInt64
    public let scannedFiles: UInt64
    public let skippedFiles: UInt64
    public let unsupportedFiles: UInt64
    public let failedFiles: UInt64
    public let candidateBytes: UInt64
    public let scannedBytes: UInt64
    public let skippedBytes: UInt64
    public let unsupportedBytes: UInt64
    public let failedBytes: UInt64
    public let reasonCounts: [CoverageReasonCode: UInt64]
    public let details: [DetectorCoverageDetail]
}

public struct ScanCoverageSnapshot: Sendable, Equatable {
    public let sessionID: ScanSessionID
    public let terminalState: ScanTerminalState
    public let detectors: [DetectorCoverageSnapshot]
}

public enum ScanSessionCondition: Sendable, Equatable {
    case globalLimit(CoverageReasonCode)
    case cancelled
    case failed
    case rootUnavailable
}

public enum DetectorInterruption: Sendable, Equatable {
    case cancelled
    case failed(CoverageReasonCode)
    case unavailable(CoverageReasonCode)
}

public enum CoverageLedgerError: Error, Equatable {
    case alreadyFinalized
    case detectorAlreadyBegun(DetectorID)
    case transactionNotFound(CoverageTransactionID)
    case transactionNotOpen(CoverageTransactionID)
    case outcomeExceedsCandidate(DetectorID)
    case unresolvedCandidates(DetectorID)
    case incompleteDetail(DetectorID)
    case detailNotApplicable(DetectorID)
    case detailLimitExceeded(DetectorID)
    case counterOverflow(DetectorID)
    case unfinishedDetectors
}

public actor CoverageLedger {
    fileprivate enum Phase: Sendable, Equatable {
        case planned
        case open
        case closed(DetectorTerminalState, sessionDerived: Bool)
    }

    fileprivate struct DetectorRecord: Sendable {
        let transactionID: CoverageTransactionID
        let detector: DetectorID
        var phase: Phase = .planned
        var candidateFiles: UInt64 = 0
        var scannedFiles: UInt64 = 0
        var skippedFiles: UInt64 = 0
        var unsupportedFiles: UInt64 = 0
        var failedFiles: UInt64 = 0
        var candidateBytes: UInt64 = 0
        var scannedBytes: UInt64 = 0
        var skippedBytes: UInt64 = 0
        var unsupportedBytes: UInt64 = 0
        var failedBytes: UInt64 = 0
        var reasonCounts: [CoverageReasonCode: UInt64] = [:]
        var details: [DetectorCoverageDetail] = []
        var recordedCandidate = false
        var recordedOutcome = false
    }

    private let sessionID: ScanSessionID
    private let executionPlan: DetectorExecutionPlan
    private let limits: ScanLimits
    private var records: [DetectorRecord]
    private var sessionCondition: ScanSessionCondition?
    private var finalized = false

    public init(
        sessionID: ScanSessionID,
        executionPlan: DetectorExecutionPlan = .allEnabled,
        limits: ScanLimits = .defaults
    ) {
        self.sessionID = sessionID
        self.executionPlan = executionPlan
        self.limits = limits
        records = executionPlan.detectors.map {
            DetectorRecord(transactionID: CoverageTransactionID(rawValue: UUID()), detector: $0)
        }
    }

    public func begin(_ detector: DetectorID) throws -> CoverageTransactionID {
        try requireMutable()
        guard let index = records.firstIndex(where: { $0.detector == detector }) else {
            preconditionFailure("DetectorExecutionPlan omitted a known detector")
        }
        guard records[index].phase == .planned else {
            throw CoverageLedgerError.detectorAlreadyBegun(detector)
        }
        records[index].phase = .open
        return records[index].transactionID
    }

    public func record(_ delta: CoverageDelta, in transaction: CoverageTransactionID) throws {
        try requireMutable()
        let index = try openRecordIndex(for: transaction)
        var updated = records[index]

        do {
            switch delta {
            case let .candidate(files, bytes):
                updated.candidateFiles = try checkedAdding(updated.candidateFiles, files)
                updated.candidateBytes = try checkedAdding(updated.candidateBytes, bytes)
                updated.recordedCandidate = true
            case let .scanned(files, bytes):
                updated.scannedFiles = try checkedAdding(updated.scannedFiles, files)
                updated.scannedBytes = try checkedAdding(updated.scannedBytes, bytes)
                updated.recordedOutcome = true
            case let .skipped(reason, files, bytes):
                updated.skippedFiles = try checkedAdding(updated.skippedFiles, files)
                updated.skippedBytes = try checkedAdding(updated.skippedBytes, bytes)
                try addReason(reason, count: files, to: &updated)
                updated.recordedOutcome = true
            case let .unsupported(reason, files, bytes):
                updated.unsupportedFiles = try checkedAdding(updated.unsupportedFiles, files)
                updated.unsupportedBytes = try checkedAdding(updated.unsupportedBytes, bytes)
                try addReason(reason, count: files, to: &updated)
                updated.recordedOutcome = true
            case let .failed(reason, files, bytes):
                updated.failedFiles = try checkedAdding(updated.failedFiles, files)
                updated.failedBytes = try checkedAdding(updated.failedBytes, bytes)
                try addReason(reason, count: files, to: &updated)
                updated.recordedOutcome = true
            }

            let outcomeFiles = try outcomeTotal(
                updated.scannedFiles,
                updated.skippedFiles,
                updated.unsupportedFiles,
                updated.failedFiles
            )
            let outcomeBytes = try outcomeTotal(
                updated.scannedBytes,
                updated.skippedBytes,
                updated.unsupportedBytes,
                updated.failedBytes
            )
            guard outcomeFiles <= updated.candidateFiles, outcomeBytes <= updated.candidateBytes else {
                throw CoverageLedgerError.outcomeExceedsCandidate(updated.detector)
            }
        } catch is CounterArithmeticError {
            records[index].phase = .closed(.failed, sessionDerived: false)
            throw CoverageLedgerError.counterOverflow(records[index].detector)
        }

        records[index] = updated
    }

    public func record(
        _ detail: DetectorCoverageDetail,
        in transaction: CoverageTransactionID
    ) throws {
        try requireMutable()
        let index = try openRecordIndex(for: transaction)
        var updated = records[index]

        guard detail.isApplicable(to: updated.detector) else {
            throw CoverageLedgerError.detailNotApplicable(updated.detector)
        }

        do {
            try validateDetailCount(detail, in: updated)
        } catch is CounterArithmeticError {
            records[index].phase = .closed(.failed, sessionDerived: false)
            throw CoverageLedgerError.counterOverflow(records[index].detector)
        } catch let error as CoverageLedgerError {
            if case .detailLimitExceeded = error, let limitingDetail = detail.limitExceededDetail {
                updated.details.append(limitingDetail)
                records[index] = updated
            }
            throw error
        }

        updated.details.append(detail)
        records[index] = updated
    }

    public func finish(_ transaction: CoverageTransactionID) throws {
        try requireMutable()
        let index = try openRecordIndex(for: transaction)
        var record = records[index]

        guard record.recordedCandidate, record.recordedOutcome else {
            throw CoverageLedgerError.unresolvedCandidates(record.detector)
        }

        let outcomeFiles: UInt64
        let outcomeBytes: UInt64
        do {
            outcomeFiles = try outcomeTotal(
                record.scannedFiles,
                record.skippedFiles,
                record.unsupportedFiles,
                record.failedFiles
            )
            outcomeBytes = try outcomeTotal(
                record.scannedBytes,
                record.skippedBytes,
                record.unsupportedBytes,
                record.failedBytes
            )
        } catch is CounterArithmeticError {
            records[index].phase = .closed(.failed, sessionDerived: false)
            throw CoverageLedgerError.counterOverflow(record.detector)
        }

        guard outcomeFiles == record.candidateFiles, outcomeBytes == record.candidateBytes else {
            throw CoverageLedgerError.unresolvedCandidates(record.detector)
        }
        guard record.hasRequiredDetails else {
            throw CoverageLedgerError.incompleteDetail(record.detector)
        }

        let hasLimitingFact = record.skippedFiles > 0
            || record.unsupportedFiles > 0
            || record.failedFiles > 0
            || record.skippedBytes > 0
            || record.unsupportedBytes > 0
            || record.failedBytes > 0
            || record.details.contains(where: \.isCoverageLimiting)
        record.phase = .closed(hasLimitingFact ? .partial : .complete, sessionDerived: false)
        records[index] = record
    }

    public func interrupt(
        _ transaction: CoverageTransactionID,
        because reason: DetectorInterruption
    ) throws {
        try requireMutable()
        let index = try openRecordIndex(for: transaction)
        var record = records[index]

        do {
            switch reason {
            case .cancelled:
                try addReason(.cancelled, count: 1, to: &record)
                record.phase = .closed(.cancelled, sessionDerived: false)
            case let .failed(reason):
                try addReason(reason, count: 1, to: &record)
                record.phase = .closed(.failed, sessionDerived: false)
            case let .unavailable(reason):
                try addReason(reason, count: 1, to: &record)
                record.phase = .closed(.unavailable, sessionDerived: false)
            }
        } catch is CounterArithmeticError {
            records[index].phase = .closed(.failed, sessionDerived: false)
            throw CoverageLedgerError.counterOverflow(records[index].detector)
        }

        records[index] = record
    }

    public func record(_ condition: ScanSessionCondition) throws {
        try requireMutable()
        if let current = sessionCondition, current.precedence >= condition.precedence {
            return
        }
        var updatedRecords = records

        for index in updatedRecords.indices {
            let shouldClose: Bool
            switch updatedRecords[index].phase {
            case .planned, .open:
                shouldClose = true
            case let .closed(_, sessionDerived):
                shouldClose = sessionDerived
            }
            guard shouldClose else {
                continue
            }

            if let reason = condition.reasonCode {
                addSessionReason(reason, to: &updatedRecords[index])
            }
            updatedRecords[index].phase = .closed(
                condition.detectorTerminalState,
                sessionDerived: true
            )
        }
        records = updatedRecords
        sessionCondition = condition
    }

    public func finalize() throws -> ScanCoverageSnapshot {
        try requireMutable()
        guard records.allSatisfy(\.isClosed) else {
            throw CoverageLedgerError.unfinishedDetectors
        }

        let terminalState: ScanTerminalState
        if let sessionCondition {
            terminalState = sessionCondition.scanTerminalState
        } else if records.allSatisfy({ $0.terminalState == .complete }) {
            terminalState = .complete
        } else {
            terminalState = .partial
        }

        let snapshot = ScanCoverageSnapshot(
            sessionID: sessionID,
            terminalState: terminalState,
            detectors: records.map(\.snapshot)
        )
        finalized = true
        return snapshot
    }

    private func requireMutable() throws {
        guard !finalized else {
            throw CoverageLedgerError.alreadyFinalized
        }
    }

    private func openRecordIndex(for transaction: CoverageTransactionID) throws -> Int {
        guard let index = records.firstIndex(where: { $0.transactionID == transaction }) else {
            throw CoverageLedgerError.transactionNotFound(transaction)
        }
        guard records[index].phase == .open else {
            throw CoverageLedgerError.transactionNotOpen(transaction)
        }
        return index
    }

    private func checkedAdding(_ left: UInt64, _ right: UInt64) throws -> UInt64 {
        let (sum, overflow) = left.addingReportingOverflow(right)
        guard !overflow else {
            throw CounterArithmeticError()
        }
        return sum
    }

    private func outcomeTotal(_ values: UInt64...) throws -> UInt64 {
        try values.reduce(0, checkedAdding)
    }

    private func addReason(
        _ reason: CoverageReasonCode,
        count: UInt64,
        to record: inout DetectorRecord
    ) throws {
        record.reasonCounts[reason] = try checkedAdding(record.reasonCounts[reason, default: 0], count)
    }

    private func addSessionReason(
        _ reason: CoverageReasonCode,
        to record: inout DetectorRecord
    ) {
        let current = record.reasonCounts[reason, default: 0]
        let (next, overflow) = current.addingReportingOverflow(1)
        if !overflow {
            record.reasonCounts[reason] = next
        }
    }

    private func validateDetailCount(
        _ detail: DetectorCoverageDetail,
        in record: DetectorRecord
    ) throws {
        switch detail {
        case let .coordinates(_, count):
            guard count <= limits.dependencyNodesPerLockfile else {
                throw CoverageLedgerError.detailLimitExceeded(record.detector)
            }
            let existing = try record.details.reduce(into: UInt64.zero) { total, detail in
                guard case let .coordinates(_, count) = detail else { return }
                total = try checkedAdding(total, count)
            }
            let aggregate = try checkedAdding(existing, count)
            guard aggregate <= limits.dependencyNodesPerSession else {
                throw CoverageLedgerError.detailLimitExceeded(record.detector)
            }
        case let .installedManifests(_, count):
            let existing = try record.details.reduce(into: UInt64.zero) { total, detail in
                guard case let .installedManifests(_, count) = detail else { return }
                total = try checkedAdding(total, count)
            }
            let aggregate = try checkedAdding(existing, count)
            guard aggregate <= limits.installedManifests else {
                throw CoverageLedgerError.detailLimitExceeded(record.detector)
            }
        case let .competingLockfiles(state):
            guard let count = state.count else { return }
            let existing = try record.details.reduce(into: UInt64.zero) { total, detail in
                guard case let .competingLockfiles(state) = detail, let count = state.count else { return }
                total = try checkedAdding(total, count)
            }
            let aggregate = try checkedAdding(existing, count)
            guard aggregate <= limits.generalFiles else {
                throw CoverageLedgerError.detailLimitExceeded(record.detector)
            }
        case .gitRepository, .lockfile, .advisory:
            break
        }
    }
}

private struct CounterArithmeticError: Error {}

private extension CoverageLedger.DetectorRecord {
    var isClosed: Bool {
        if case .closed = phase { return true }
        return false
    }

    var terminalState: DetectorTerminalState? {
        guard case let .closed(state, _) = phase else { return nil }
        return state
    }

    var snapshot: DetectorCoverageSnapshot {
        guard let terminalState else {
            preconditionFailure("Only closed detector records can be snapshotted")
        }
        return DetectorCoverageSnapshot(
            transactionID: transactionID,
            detector: detector,
            terminalState: terminalState,
            candidateFiles: candidateFiles,
            scannedFiles: scannedFiles,
            skippedFiles: skippedFiles,
            unsupportedFiles: unsupportedFiles,
            failedFiles: failedFiles,
            candidateBytes: candidateBytes,
            scannedBytes: scannedBytes,
            skippedBytes: skippedBytes,
            unsupportedBytes: unsupportedBytes,
            failedBytes: failedBytes,
            reasonCounts: reasonCounts,
            details: details
        )
    }

    var hasRequiredDetails: Bool {
        switch detector {
        case .secret:
            return true
        case .nodeLockfile:
            return details.satisfiesRequirement(\.isLockfile, usable: \.isUsableLockfile)
                && details.satisfiesRequirement(\.isCoordinate, usable: \.isUsableCoordinate)
                && details.satisfiesRequirement(
                    \.isCompetingLockfile,
                    usable: \.isUsableCompetingLockfile
                )
        case .advisory:
            return details.satisfiesRequirement(\.isAdvisory, usable: \.isUsableAdvisory)
        case .lifecycle:
            return details.satisfiesRequirement(
                \.isInstalledManifest,
                usable: \.isUsableInstalledManifest
            )
        case .gitEvidence:
            return details.satisfiesRequirement(
                \.isGitRepository,
                usable: \.isUsableGitRepository
            )
        }
    }
}

private extension Array where Element == DetectorCoverageDetail {
    func satisfiesRequirement(
        _ matches: KeyPath<Element, Bool>,
        usable: KeyPath<Element, Bool>
    ) -> Bool {
        let requiredDetails = filter { $0[keyPath: matches] }
        return !requiredDetails.isEmpty && requiredDetails.allSatisfy { $0[keyPath: usable] }
    }
}

private extension DetectorCoverageDetail {
    var limitExceededDetail: DetectorCoverageDetail? {
        switch self {
        case .coordinates:
            return .coordinates(status: .partial(.entryBudget), count: 0)
        case .installedManifests:
            return .installedManifests(.partial(.entryBudget), count: 0)
        case .competingLockfiles:
            return .competingLockfiles(.partial(count: 0, reason: .entryBudget))
        case .gitRepository, .lockfile, .advisory:
            return nil
        }
    }

    func isApplicable(to detector: DetectorID) -> Bool {
        switch (detector, self) {
        case (.nodeLockfile, .lockfile),
             (.nodeLockfile, .coordinates),
             (.nodeLockfile, .competingLockfiles),
             (.advisory, .advisory),
             (.lifecycle, .installedManifests),
             (.gitEvidence, .gitRepository):
            return true
        case (.secret, _),
             (.nodeLockfile, _),
             (.advisory, _),
             (.lifecycle, _),
             (.gitEvidence, _):
            return false
        }
    }

    var isCoverageLimiting: Bool {
        switch self {
        case let .gitRepository(_, preflight, operation):
            return preflight.isLimiting || operation.isLimiting
        case let .lockfile(_, status):
            return status.isLimiting
        case let .coordinates(status, _):
            return status.isLimiting
        case let .installedManifests(availability, _):
            return availability.isLimiting
        case let .competingLockfiles(state):
            return state.isLimiting
        case let .advisory(metadata):
            return metadata.validation.isLimiting
        }
    }

    var isGitRepository: Bool {
        if case .gitRepository = self { return true }
        return false
    }

    var isLockfile: Bool {
        if case .lockfile = self { return true }
        return false
    }

    var isCoordinate: Bool {
        if case .coordinates = self { return true }
        return false
    }

    var isInstalledManifest: Bool {
        if case .installedManifests = self { return true }
        return false
    }

    var isCompetingLockfile: Bool {
        if case .competingLockfiles = self { return true }
        return false
    }

    var isAdvisory: Bool {
        if case .advisory = self { return true }
        return false
    }

    var isUsableGitRepository: Bool {
        guard case let .gitRepository(_, preflight, operation) = self else { return false }
        return preflight.isUsable && operation.isUsable
    }

    var isUsableLockfile: Bool {
        guard case let .lockfile(_, status) = self else { return false }
        return status.isUsable
    }

    var isUsableCoordinate: Bool {
        guard case let .coordinates(status, _) = self else { return false }
        return status.isUsable
    }

    var isUsableInstalledManifest: Bool {
        guard case let .installedManifests(availability, _) = self else { return false }
        return availability.isUsable
    }

    var isUsableCompetingLockfile: Bool {
        guard case let .competingLockfiles(state) = self else { return false }
        return state.isUsable
    }

    var isUsableAdvisory: Bool {
        guard case let .advisory(metadata) = self else { return false }
        return metadata.validation.isUsable
    }
}

private protocol CoverageStatus {
    var isUsable: Bool { get }
    var isLimiting: Bool { get }
}

extension GitPreflightStatus: CoverageStatus {
    fileprivate var isUsable: Bool { self != .absent }
    fileprivate var isLimiting: Bool { self != .complete && self != .absent }
}

extension GitOperationStatus: CoverageStatus {
    fileprivate var isUsable: Bool { self != .absent }
    fileprivate var isLimiting: Bool { self != .complete && self != .absent }
}

extension LockfileCoverageStatus: CoverageStatus {
    fileprivate var isUsable: Bool { self != .absent }
    fileprivate var isLimiting: Bool { self != .complete && self != .absent }
}

extension CoordinateCoverageStatus: CoverageStatus {
    fileprivate var isUsable: Bool { self != .absent }
    fileprivate var isLimiting: Bool { self != .complete && self != .absent }
}

extension InstalledManifestAvailability: CoverageStatus {
    fileprivate var isUsable: Bool { self != .absent }
    fileprivate var isLimiting: Bool { self != .complete && self != .absent }
}

extension AdvisoryValidationState: CoverageStatus {
    fileprivate var isUsable: Bool { self != .absent }
    fileprivate var isLimiting: Bool { self != .complete && self != .absent }
}

private extension CompetingLockfileState {
    var count: UInt64? {
        switch self {
        case .absent, .unavailable:
            return nil
        case let .complete(count), let .partial(count, _):
            return count
        }
    }

    var isUsable: Bool { self != .absent }
    var isLimiting: Bool {
        switch self {
        case .partial, .unavailable:
            return true
        case .absent, .complete:
            return false
        }
    }
}

private extension ScanSessionCondition {
    var precedence: Int {
        switch self {
        case .globalLimit: return 0
        case .cancelled: return 1
        case .failed: return 2
        case .rootUnavailable: return 3
        }
    }

    var detectorTerminalState: DetectorTerminalState {
        switch self {
        case .globalLimit: return .partial
        case .cancelled: return .cancelled
        case .failed: return .failed
        case .rootUnavailable: return .unavailable
        }
    }

    var scanTerminalState: ScanTerminalState {
        switch self {
        case .globalLimit: return .partial
        case .cancelled: return .cancelled
        case .failed: return .failed
        case .rootUnavailable: return .unavailable
        }
    }

    var reasonCode: CoverageReasonCode? {
        switch self {
        case let .globalLimit(reason): return reason
        case .cancelled: return .cancelled
        case .failed: return nil
        case .rootUnavailable: return nil
        }
    }
}
