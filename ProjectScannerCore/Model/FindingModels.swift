public struct SessionFindingHeader: Sendable, Equatable {
    public let kind: FindingKind
    public let ruleID: RuleID
    public let ruleVersion: UInt32
    public let sourceView: SourceView
    public let detectorID: DetectorID
    public let coverageTransactionID: CoverageTransactionID
    public let assessment: FindingAssessment
    public let provenance: FindingProvenance
    public let suppressionEligibility: SuppressionEligibility
    public let suppressionState: SessionSuppressionState

    public init(
        kind: FindingKind,
        ruleID: RuleID,
        ruleVersion: UInt32,
        sourceView: SourceView,
        detectorID: DetectorID,
        coverageTransactionID: CoverageTransactionID,
        assessment: FindingAssessment,
        provenance: FindingProvenance,
        suppressionEligibility: SuppressionEligibility,
        suppressionState: SessionSuppressionState
    ) {
        self.kind = kind
        self.ruleID = ruleID
        self.ruleVersion = ruleVersion
        self.sourceView = sourceView
        self.detectorID = detectorID
        self.coverageTransactionID = coverageTransactionID
        self.assessment = assessment
        self.provenance = provenance
        self.suppressionEligibility = suppressionEligibility
        self.suppressionState = suppressionState
    }
}

public struct SessionFinding: Sendable, Equatable {
    public let header: SessionFindingHeader
    public let location: VerifiedRelativePath?
    public let displayPath: EscapedDisplayPath?
    public let line: UInt64?
    public let evidence: RedactedSourceField?
}

public enum SessionAppendResult: Sendable, Equatable {
    case appended
    case limitReached
}
