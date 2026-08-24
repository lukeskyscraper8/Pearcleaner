import Foundation

public struct SecretMatchObservation: Sendable, Equatable {
    public let path: VerifiedRelativePath
    public let sourceView: SourceView
    public let match: SecretMatch
    public let displayPath: EscapedDisplayPath
    public let evidence: RedactedSourceField?

    public init(
        path: VerifiedRelativePath,
        sourceView: SourceView,
        match: SecretMatch,
        displayPath: EscapedDisplayPath,
        evidence: RedactedSourceField? = nil
    ) {
        self.path = path
        self.sourceView = sourceView
        self.match = match
        self.displayPath = displayPath
        self.evidence = evidence
    }
}

public struct SecretGitExposure: Sendable, Equatable {
    public let inWorkingTree: Bool
    public let inIndex: Bool
    public let inCurrentHead: Bool
    public let isTracked: Bool
    public let isStaged: Bool
    public let isUntracked: Bool
    public let isIgnored: Bool

    public init(
        inWorkingTree: Bool,
        inIndex: Bool,
        inCurrentHead: Bool,
        isTracked: Bool,
        isStaged: Bool,
        isUntracked: Bool,
        isIgnored: Bool
    ) {
        self.inWorkingTree = inWorkingTree
        self.inIndex = inIndex
        self.inCurrentHead = inCurrentHead
        self.isTracked = isTracked
        self.isStaged = isStaged
        self.isUntracked = isUntracked
        self.isIgnored = isIgnored
    }
}

public struct CorrelatedSecretMatch: Sendable, Equatable {
    public let identity: SecretMatchIdentity
    public let path: VerifiedRelativePath
    public let exposure: SecretGitExposure
    public let observations: [SecretMatchObservation]

    public init(
        identity: SecretMatchIdentity,
        path: VerifiedRelativePath,
        exposure: SecretGitExposure,
        observations: [SecretMatchObservation]
    ) {
        self.identity = identity
        self.path = path
        self.exposure = exposure
        self.observations = observations
    }
}

public struct SecretMatchCorrelator: Sendable {
    public init() {}

    public func correlate(
        observations: [SecretMatchObservation],
        gitFacts: GitPathFacts?
    ) -> [CorrelatedSecretMatch] {
        var groups: [CorrelationGroupKey: [SecretMatchObservation]] = [:]
        for observation in observations {
            let key = CorrelationGroupKey(
                path: observation.path,
                identity: observation.match.identity
            )
            groups[key, default: []].append(observation)
        }

        return groups.map { key, groupedObservations in
            CorrelatedSecretMatch(
                identity: key.identity,
                path: key.path,
                exposure: exposure(
                    for: key.path,
                    observations: groupedObservations,
                    gitFacts: gitFacts
                ),
                observations: groupedObservations.sorted { lhs, rhs in
                    sourceViewOrder(lhs.sourceView) < sourceViewOrder(rhs.sourceView)
                }
            )
        }.sorted { lhs, rhs in
            if lhs.path.rawByteCount != rhs.path.rawByteCount {
                return lhs.path.rawByteCount < rhs.path.rawByteCount
            }
            return lhs.path.components.count < rhs.path.components.count
        }
    }

    public func makeSessionFinding(
        observation: SecretMatchObservation,
        transaction: CoverageTransactionID,
        projectID: ProjectID,
        keyLease: ProjectKeyLease,
        suppressedFingerprints: Set<SuppressionFingerprint> = []
    ) throws -> SessionFinding {
        let (eligibility, state) = try suppressionState(
            observation: observation,
            projectID: projectID,
            keyLease: keyLease,
            suppressedFingerprints: suppressedFingerprints
        )

        return SessionFinding(
            header: SessionFindingHeader(
                kind: .probableSecret,
                ruleID: observation.match.ruleID,
                ruleVersion: observation.match.ruleVersion,
                sourceView: observation.sourceView,
                detectorID: .secret,
                coverageTransactionID: transaction,
                assessment: .confidence(observation.match.confidence),
                provenance: .secretRule,
                suppressionEligibility: eligibility,
                suppressionState: state
            ),
            location: observation.path,
            displayPath: observation.displayPath,
            line: observation.match.line,
            evidence: observation.evidence ?? observation.match.evidence
        )
    }

    public func makeSessionFindings(
        from correlated: CorrelatedSecretMatch,
        transaction: CoverageTransactionID,
        projectID: ProjectID,
        keyLease: ProjectKeyLease,
        suppressedFingerprints: Set<SuppressionFingerprint> = []
    ) throws -> [SessionFinding] {
        try correlated.observations.map {
            try makeSessionFinding(
                observation: $0,
                transaction: transaction,
                projectID: projectID,
                keyLease: keyLease,
                suppressedFingerprints: suppressedFingerprints
            )
        }
    }

    public func suppressionFingerprint(
        observation: SecretMatchObservation,
        projectID: ProjectID,
        keyMaterial: ProjectKeyMaterial
    ) throws -> SuppressionFingerprint {
        try SecretSuppressionFingerprintEncoder.fingerprint(
            projectID: projectID,
            path: observation.path,
            ruleID: observation.match.ruleID,
            ruleVersion: observation.match.ruleVersion,
            matchIdentity: observation.match.identity,
            keyMaterial: keyMaterial
        )
    }

    private func exposure(
        for path: VerifiedRelativePath,
        observations: [SecretMatchObservation],
        gitFacts: GitPathFacts?
    ) -> SecretGitExposure {
        let inWorkingTree = observations.contains { $0.sourceView == .workingTree }
        let inIndex = observations.contains { $0.sourceView == .index }
        let inCurrentHead = observations.contains { $0.sourceView == .currentHead }

        guard let gitFacts else {
            return SecretGitExposure(
                inWorkingTree: inWorkingTree,
                inIndex: inIndex,
                inCurrentHead: inCurrentHead,
                isTracked: false,
                isStaged: false,
                isUntracked: false,
                isIgnored: false
            )
        }

        let isIgnored: Bool
        switch gitFacts.ignoredPaths {
        case let .available(paths):
            isIgnored = paths.contains(path)
        case .unavailable:
            isIgnored = false
        }

        return SecretGitExposure(
            inWorkingTree: inWorkingTree,
            inIndex: inIndex,
            inCurrentHead: inCurrentHead,
            isTracked: gitFacts.indexedPaths.contains(path),
            isStaged: gitFacts.stagedPaths.contains(path),
            isUntracked: gitFacts.untrackedPaths.contains(path),
            isIgnored: isIgnored
        )
    }

    private func suppressionState(
        observation: SecretMatchObservation,
        projectID: ProjectID,
        keyLease: ProjectKeyLease,
        suppressedFingerprints: Set<SuppressionFingerprint>
    ) throws -> (SuppressionEligibility, SessionSuppressionState) {
        guard keyLease.permitsPersistentSuppression else {
            return (.ineligible(.ephemeralKeyState), .unavailableEphemeral)
        }

        let fingerprint = try suppressionFingerprint(
            observation: observation,
            projectID: projectID,
            keyMaterial: keyLease.material
        )
        if suppressedFingerprints.contains(fingerprint) {
            return (.eligible, .suppressed)
        }
        return (.eligible, .notSuppressed)
    }

    private func sourceViewOrder(_ sourceView: SourceView) -> Int {
        switch sourceView {
        case .workingTree: 0
        case .index: 1
        case .currentHead: 2
        }
    }
}

private struct CorrelationGroupKey: Hashable {
    let path: VerifiedRelativePath
    let identity: SecretMatchIdentity
}
