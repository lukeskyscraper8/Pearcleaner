import Foundation

public enum ScanCoordinatorError: Error, Sendable, Equatable {
    case scanAlreadyActive
}

public struct ScanCoordinatorDependencies: Sendable {
    public let feasibility: any GitFeasibilityProviding
    public let gitExecutor: any GitEvidenceExecuting
    public let sessionIDGenerator: any ScanSessionIDGenerating

    public init(
        feasibility: any GitFeasibilityProviding,
        gitExecutor: any GitEvidenceExecuting,
        sessionIDGenerator: any ScanSessionIDGenerating = SystemScanSessionIDGenerator()
    ) {
        self.feasibility = feasibility
        self.gitExecutor = gitExecutor
        self.sessionIDGenerator = sessionIDGenerator
    }
}

public struct ScanCoordinatorRequest: Sendable {
    public let root: RootCapability
    public let limits: ScanLimits
    public let identityKey: SecretMatchIdentityKey
    public let projectID: ProjectID?
    public let keyLease: ProjectKeyLease?
    public let suppressedFingerprints: Set<SuppressionFingerprint>

    public init(
        root: RootCapability,
        limits: ScanLimits = .defaults,
        identityKey: SecretMatchIdentityKey,
        projectID: ProjectID? = nil,
        keyLease: ProjectKeyLease? = nil,
        suppressedFingerprints: Set<SuppressionFingerprint> = []
    ) {
        self.root = root
        self.limits = limits
        self.identityKey = identityKey
        self.projectID = projectID
        self.keyLease = keyLease
        self.suppressedFingerprints = suppressedFingerprints
    }
}

public struct ScanCoordinatorResult: Sendable {
    public let coverage: ScanCoverageSnapshot
    public let findings: [SessionFinding]
    public let correlatedMatches: [CorrelatedSecretMatch]
    public let gitFacts: GitPathFacts?
}

public actor ScanCoordinator {
    private let dependencies: ScanCoordinatorDependencies
    private var activeScan: Task<ScanCoordinatorResult, Error>?

    public init(dependencies: ScanCoordinatorDependencies) {
        self.dependencies = dependencies
    }

    public init(
        feasibility: any GitFeasibilityProviding,
        gitExecutor: any GitEvidenceExecuting,
        sessionIDGenerator: any ScanSessionIDGenerating = SystemScanSessionIDGenerator()
    ) {
        self.init(
            dependencies: ScanCoordinatorDependencies(
                feasibility: feasibility,
                gitExecutor: gitExecutor,
                sessionIDGenerator: sessionIDGenerator
            )
        )
    }

    @discardableResult
    public func scan(_ request: ScanCoordinatorRequest) async throws -> ScanCoordinatorResult {
        guard activeScan == nil else {
            throw ScanCoordinatorError.scanAlreadyActive
        }

        let task = Task {
            try await self.runScan(request)
        }
        activeScan = task
        defer { activeScan = nil }
        return try await task.value
    }

    public func cancel() {
        activeScan?.cancel()
    }

    private func runScan(_ request: ScanCoordinatorRequest) async throws -> ScanCoordinatorResult {
        let sessionID = dependencies.sessionIDGenerator.makeScanSessionID()
        let ledger = CoverageLedger(sessionID: sessionID, limits: request.limits)
        let session = SessionStore(limits: request.limits)
        let secretDetector = SecretDetector(limits: request.limits)
        let correlator = SecretMatchCorrelator()
        let startedAt = ContinuousClock.now

        let broker: FileBroker
        do {
            broker = try request.root.makeFileBroker(limits: request.limits)
        } catch {
            return try await unavailableAuthorizationResult(ledger: ledger)
        }

        let secretTransaction = try await ledger.begin(.secret)
        let gitTransaction = try await ledger.begin(.gitEvidence)

        do {
            var observations: [SecretMatchObservation] = []
            var workingTreePaths = Set<VerifiedRelativePath>()
            var gitignorePaths = Set<VerifiedRelativePath>()
            var candidates: [FileCandidate] = []
            var skippedEvents: [(SkippedTraversalLocation, CoverageReasonCode)] = []

            let traversal = try await broker.makeTraversal()
            while let event = try await traversal.next() {
                try Task.checkCancellation()
                try await enforceWallTimeBudget(since: startedAt, limits: request.limits, ledger: ledger)

                switch event {
                case let .candidate(candidate):
                    candidates.append(candidate)
                    workingTreePaths.insert(candidate.logicalPath)
                    if isGitignorePath(candidate.logicalPath) {
                        gitignorePaths.insert(candidate.logicalPath)
                    }
                case let .skipped(location, reason):
                    skippedEvents.append((location, reason))
                }
            }

            candidates.sort { lhs, rhs in
                let leftPriority = scanPriority(for: lhs.logicalPath)
                let rightPriority = scanPriority(for: rhs.logicalPath)
                if leftPriority != rightPriority {
                    return leftPriority < rightPriority
                }
                if lhs.logicalPath.rawByteCount != rhs.logicalPath.rawByteCount {
                    return lhs.logicalPath.rawByteCount < rhs.logicalPath.rawByteCount
                }
                return lhs.logicalPath.components.count < rhs.logicalPath.components.count
            }

            let contentBroker = broker.makeContentBroker()
            for candidate in candidates {
                try Task.checkCancellation()
                try await enforceWallTimeBudget(since: startedAt, limits: request.limits, ledger: ledger)

                try await ledger.record(
                    .candidate(files: 1, bytes: candidate.byteCount),
                    in: secretTransaction
                )

                let admission = await contentBroker.read(candidate, for: .secretInspection)
                switch admission {
                case let .skipped(reason, bytes):
                    try await ledger.record(
                        .skipped(reason: reason, files: 1, bytes: bytes),
                        in: secretTransaction
                    )
                case let .admitted(lease):
                    let data = try lease.withBytes(for: .secretInspection) { Data($0) }
                    let matches = secretDetector.scanData(data, identityKey: request.identityKey)
                    try await ledger.record(
                        .scanned(files: 1, bytes: candidate.byteCount),
                        in: secretTransaction
                    )
                    let displayPath = candidate.logicalPath.escapedForDisplay()
                    for match in matches.prefix(Int(request.limits.findingsPerFile)) {
                        observations.append(
                            SecretMatchObservation(
                                path: candidate.logicalPath,
                                sourceView: .workingTree,
                                match: match,
                                displayPath: displayPath,
                                evidence: match.evidence
                            )
                        )
                    }
                }
            }

            for (_, reason) in skippedEvents {
                try await ledger.record(.candidate(files: 1, bytes: 0), in: secretTransaction)
                try await ledger.record(
                    .skipped(reason: reason, files: 1, bytes: 0),
                    in: secretTransaction
                )
            }

            try await ledger.finish(secretTransaction)

            let observationCollector = ObservationCollector()
            let blobCollector = GitSecretBlobCollector(
                detector: secretDetector,
                identityKey: request.identityKey,
                limits: request.limits,
                collector: observationCollector
            )

            let gitCandidateBytes: UInt64 = 0
            try await ledger.record(
                .candidate(files: 1, bytes: gitCandidateBytes),
                in: gitTransaction
            )
            let gitProvider = GitEvidenceProvider(
                feasibility: dependencies.feasibility,
                executor: dependencies.gitExecutor,
                limits: request.limits
            )
            let gitOutcome = await gitProvider.collect(
                broker: broker,
                ledger: ledger,
                transaction: gitTransaction,
                request: GitEvidenceCollectionRequest(
                    workingTreePaths: workingTreePaths,
                    gitignoreFilePaths: gitignorePaths
                ),
                blobConsumer: blobCollector
            )
            observations.append(contentsOf: observationCollector.values)

            let gitFacts: GitPathFacts?
            switch gitOutcome {
            case let .complete(facts), let .partial(facts, _):
                gitFacts = facts
                try await ledger.record(
                    .scanned(files: 1, bytes: gitCandidateBytes),
                    in: gitTransaction
                )
                try await ledger.finish(gitTransaction)
            case .unavailable:
                gitFacts = nil
                try await ledger.interrupt(
                    gitTransaction,
                    because: .unavailable(.gitPreflightRejected)
                )
            }

            try await closeUnavailableDetectors(in: ledger)

            let correlated = correlator.correlate(observations: observations, gitFacts: gitFacts)
            try await appendFindings(
                correlated: correlated,
                observations: observations,
                correlator: correlator,
                secretTransaction: secretTransaction,
                request: request,
                session: session
            )

            let coverage = try await ledger.finalize()
            return ScanCoordinatorResult(
                coverage: coverage,
                findings: await session.snapshot(),
                correlatedMatches: correlated,
                gitFacts: gitFacts
            )
        } catch is CancellationError {
            try await interruptOpenDetectors(
                secretTransaction: secretTransaction,
                gitTransaction: gitTransaction,
                ledger: ledger
            )
            try await ledger.record(.cancelled)
            let coverage = try await ledger.finalize()
            return ScanCoordinatorResult(
                coverage: coverage,
                findings: await session.snapshot(),
                correlatedMatches: [],
                gitFacts: nil
            )
        }
    }

    private func appendFindings(
        correlated: [CorrelatedSecretMatch],
        observations: [SecretMatchObservation],
        correlator: SecretMatchCorrelator,
        secretTransaction: CoverageTransactionID,
        request: ScanCoordinatorRequest,
        session: SessionStore
    ) async throws {
        if let projectID = request.projectID, let keyLease = request.keyLease {
            for match in correlated {
                let findings = try correlator.makeSessionFindings(
                    from: match,
                    transaction: secretTransaction,
                    projectID: projectID,
                    keyLease: keyLease,
                    suppressedFingerprints: request.suppressedFingerprints
                )
                for finding in findings {
                    _ = await session.append(finding)
                }
            }
            return
        }

        for observation in observations {
            let finding = SessionFinding(
                header: SessionFindingHeader(
                    kind: .probableSecret,
                    ruleID: observation.match.ruleID,
                    ruleVersion: observation.match.ruleVersion,
                    sourceView: observation.sourceView,
                    detectorID: .secret,
                    coverageTransactionID: secretTransaction,
                    assessment: .confidence(observation.match.confidence),
                    provenance: .secretRule,
                    suppressionEligibility: .ineligible(.ephemeralKeyState),
                    suppressionState: .unavailableEphemeral
                ),
                location: observation.path,
                displayPath: observation.displayPath,
                line: observation.match.line,
                evidence: observation.evidence ?? observation.match.evidence
            )
            _ = await session.append(finding)
        }
    }

    private func unavailableAuthorizationResult(ledger: CoverageLedger) async throws -> ScanCoordinatorResult {
        try await ledger.record(.rootUnavailable)
        let coverage = try await ledger.finalize()
        return ScanCoordinatorResult(
            coverage: coverage,
            findings: [],
            correlatedMatches: [],
            gitFacts: nil
        )
    }

    private func interruptOpenDetectors(
        secretTransaction: CoverageTransactionID,
        gitTransaction: CoverageTransactionID,
        ledger: CoverageLedger
    ) async throws {
        for transaction in [secretTransaction, gitTransaction] {
            do {
                try await ledger.interrupt(transaction, because: .cancelled)
            } catch {
                continue
            }
        }
    }

    private func closeUnavailableDetectors(in ledger: CoverageLedger) async throws {
        for detector in [DetectorID.nodeLockfile, .advisory, .lifecycle] {
            let transaction = try await ledger.begin(detector)
            switch detector {
            case .nodeLockfile, .lifecycle:
                try await ledger.interrupt(transaction, because: .unavailable(.unreadable))
            case .advisory:
                try await ledger.interrupt(transaction, because: .unavailable(.advisoryCacheMissing))
            case .secret, .gitEvidence:
                preconditionFailure("Unexpected detector")
            }
        }
    }

    private func enforceWallTimeBudget(
        since startedAt: ContinuousClock.Instant,
        limits: ScanLimits,
        ledger: CoverageLedger
    ) async throws {
        let elapsed = startedAt.duration(to: .now)
        let limit = Duration.milliseconds(Int(limits.wallTimeMilliseconds))
        guard elapsed < limit else {
            try await ledger.record(.globalLimit(.wallTimeBudget))
            throw CancellationError()
        }
    }
}

private final class ObservationCollector: @unchecked Sendable {
    private(set) var values: [SecretMatchObservation] = []

    func append(_ observation: SecretMatchObservation) {
        values.append(observation)
    }
}

private struct GitSecretBlobCollector: GitIndexHeadBlobConsuming {
    let detector: SecretDetector
    let identityKey: SecretMatchIdentityKey
    let limits: ScanLimits
    let collector: ObservationCollector

    func consumeBlob(
        objectID: GitObjectID,
        path: VerifiedRelativePath,
        bytes: Data
    ) async {
        _ = objectID
        let displayPath = path.escapedForDisplay()
        let matches = detector.scanData(bytes, identityKey: identityKey)
        for match in matches.prefix(Int(limits.findingsPerFile)) {
            collector.append(
                SecretMatchObservation(
                    path: path,
                    sourceView: .currentHead,
                    match: match,
                    displayPath: displayPath,
                    evidence: match.evidence
                )
            )
        }
    }
}

private func scanPriority(for path: VerifiedRelativePath) -> Int {
    let components = path.components.compactMap { String(data: $0.bytes, encoding: .utf8) }
    if components.contains("node_modules") {
        return 2
    }
    if let last = components.last,
       last == "package.json" || last.hasSuffix(".lock") || last.hasSuffix("lock.json") {
        return 1
    }
    return 0
}

private func isGitignorePath(_ path: VerifiedRelativePath) -> Bool {
    guard let last = path.components.last else { return false }
    return last.bytes == Data(".gitignore".utf8)
}
