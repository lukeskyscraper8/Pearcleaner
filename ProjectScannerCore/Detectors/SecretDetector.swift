import Foundation

public struct SecretMatch: Sendable, Equatable {
    public let ruleID: RuleID
    public let ruleVersion: UInt32
    public let confidence: FindingConfidence
    public let identity: SecretMatchIdentity
    public let utf8Range: Range<Int>
    public let line: UInt64
    public let evidence: RedactedSourceField?

    public init(
        ruleID: RuleID,
        ruleVersion: UInt32,
        confidence: FindingConfidence,
        identity: SecretMatchIdentity,
        utf8Range: Range<Int>,
        line: UInt64,
        evidence: RedactedSourceField?
    ) {
        self.ruleID = ruleID
        self.ruleVersion = ruleVersion
        self.confidence = confidence
        self.identity = identity
        self.utf8Range = utf8Range
        self.line = line
        self.evidence = evidence
    }
}

public enum SecretDetectorScanResult: Sendable, Equatable {
    case scanned(matches: UInt64)
    case skipped(reason: CoverageReasonCode, bytes: UInt64)
}

public struct SecretDetector: Sendable {
    private static let chunkSize = 64 * 1_024
    private static let contextByteRadius = 512

    private let rulePack: SecretRulePack
    private let limits: ScanLimits

    public init(rulePack: SecretRulePack = .current, limits: ScanLimits = .defaults) {
        self.rulePack = rulePack
        self.limits = limits
    }

    func inspectAdmission(
        _ admission: ContentAdmission,
        candidate: FileCandidate,
        sourceView: SourceView,
        transaction: CoverageTransactionID,
        ledger: CoverageLedger,
        session: SessionStore,
        identityKey: SecretMatchIdentityKey
    ) async -> SecretDetectorScanResult {
        switch admission {
        case let .skipped(reason, bytes):
            do {
                try await ledger.record(.skipped(reason: reason, files: 1, bytes: bytes), in: transaction)
            } catch {
                return .skipped(reason: reason, bytes: bytes)
            }
            return .skipped(reason: reason, bytes: bytes)
        case let .admitted(lease):
            let matchCount = await inspectLease(
                lease,
                candidate: candidate,
                sourceView: sourceView,
                transaction: transaction,
                session: session,
                identityKey: identityKey
            )
            do {
                try await ledger.record(
                    .scanned(files: 1, bytes: candidate.byteCount),
                    in: transaction
                )
            } catch {
                return .skipped(reason: .unreadable, bytes: candidate.byteCount)
            }
            return .scanned(matches: matchCount)
        }
    }

    func inspectLease(
        _ lease: ContentLease,
        candidate: FileCandidate,
        sourceView: SourceView,
        transaction: CoverageTransactionID,
        session: SessionStore,
        identityKey: SecretMatchIdentityKey
    ) async -> UInt64 {
        do {
            let data = try lease.withBytes(for: .secretInspection) { Data($0) }
            let matches = scanData(data, identityKey: identityKey)
            var appended: UInt64 = 0
            for match in matches.prefix(Int(limits.findingsPerFile)) {
                let finding = SessionFinding(
                    header: SessionFindingHeader(
                        kind: .probableSecret,
                        ruleID: match.ruleID,
                        ruleVersion: match.ruleVersion,
                        sourceView: sourceView,
                        detectorID: .secret,
                        coverageTransactionID: transaction,
                        assessment: .confidence(match.confidence),
                        provenance: .secretRule,
                        suppressionEligibility: .eligible,
                        suppressionState: .notSuppressed
                    ),
                    location: candidate.logicalPath,
                    displayPath: candidate.logicalPath.escapedForDisplay(),
                    line: match.line,
                    evidence: match.evidence
                )
                if await session.append(finding) == .appended {
                    appended += 1
                }
            }
            return appended
        } catch {
            return 0
        }
    }

    public func scanData(
        _ data: Data,
        identityKey: SecretMatchIdentityKey
    ) -> [SecretMatch] {
        guard var redactor = PrivacyRedactor(expectedRuleIDs: rulePack.ruleIDs) else {
            return []
        }
        var matches: [SecretMatch] = []
        var reportedStarts: Set<Int> = []
        let overlap = rulePack.maximumMatchBytes

        data.withUnsafeBytes { bytes in
            let allLineStarts = allLineStarts(in: bytes)
            var chunkStart = 0
            while chunkStart < bytes.count {
                let chunkEnd = min(chunkStart + Self.chunkSize, bytes.count)
                let scanStart = chunkStart == 0 ? 0 : max(0, chunkStart - overlap + 1)

                for rule in rulePack.rules {
                    var searchIndex = scanStart
                    while searchIndex < chunkEnd {
                        guard let prefixIndex = rulePack.findPrefix(
                            rule.prefix,
                            in: bytes,
                            startingAt: searchIndex,
                            upperBound: chunkEnd
                        ) else {
                            break
                        }
                        guard let matchLength = rule.matchLength(
                            in: bytes,
                            startingAt: prefixIndex,
                            upperBound: bytes.count
                        ) else {
                            searchIndex = prefixIndex + 1
                            continue
                        }

                        let matchRange = prefixIndex..<(prefixIndex + matchLength)
                        guard reportedStarts.insert(matchRange.lowerBound).inserted else {
                            searchIndex = prefixIndex + 1
                            continue
                        }

                        guard let baseAddress = bytes.baseAddress else {
                            searchIndex = prefixIndex + 1
                            continue
                        }
                        let matchBytes = UnsafeRawBufferPointer(
                            start: baseAddress.advanced(by: matchRange.lowerBound),
                            count: matchRange.count
                        )
                        let identity = SecretMatchIdentityEncoder.identity(
                            matchBytes: matchBytes,
                            ruleID: rule.id,
                            ruleVersion: rule.version,
                            key: identityKey
                        )
                        let line = lineNumber(for: matchRange.lowerBound, lineStarts: allLineStarts)
                        let evidence = redactEvidence(
                            bytes: bytes,
                            matchRange: matchRange,
                            ruleID: rule.id,
                            redactor: &redactor
                        )
                        let confidence: FindingConfidence = rule.confidence == .high ? .high : .reviewSuggested
                        matches.append(
                            SecretMatch(
                                ruleID: rule.id,
                                ruleVersion: rule.version,
                                confidence: confidence,
                                identity: identity,
                                utf8Range: matchRange,
                                line: line,
                                evidence: evidence
                            )
                        )
                        searchIndex = prefixIndex + 1
                    }
                }
                chunkStart = chunkEnd
            }
        }
        return matches
    }

    private func redactEvidence(
        bytes: UnsafeRawBufferPointer,
        matchRange: Range<Int>,
        ruleID: RuleID,
        redactor: inout PrivacyRedactor
    ) -> RedactedSourceField? {
        let contextStart = max(0, matchRange.lowerBound - Self.contextByteRadius)
        let contextEnd = min(bytes.count, matchRange.upperBound + Self.contextByteRadius)
        guard contextStart < contextEnd, let baseAddress = bytes.baseAddress else { return nil }

        let context = UnsafeRawBufferPointer(
            start: baseAddress.advanced(by: contextStart),
            count: contextEnd - contextStart
        )
        let localMatchRange = (matchRange.lowerBound - contextStart)..<(matchRange.upperBound - contextStart)
        let ruleResults = rulePack.rules.map { rule in
            if rule.id == ruleID {
                MaskingRuleResult.complete(
                    ruleID: rule.id,
                    spans: [RedactionSpan(utf8Range: localMatchRange)]
                )
            } else {
                MaskingRuleResult.complete(ruleID: rule.id, spans: [])
            }
        }
        let result = redactor.redact(utf8: context, ruleResults: ruleResults)
        switch result {
        case let .redacted(field):
            return field
        case .metadataOnly:
            return nil
        }
    }

    private func allLineStarts(in bytes: UnsafeRawBufferPointer) -> [Int] {
        var starts = [0]
        for index in 0..<bytes.count where bytes[index] == 0x0A {
            let next = index + 1
            if next < bytes.count {
                starts.append(next)
            }
        }
        return starts
    }

    private func lineNumber(for offset: Int, lineStarts: [Int]) -> UInt64 {
        var line: UInt64 = 1
        for start in lineStarts where start < offset {
            line += 1
        }
        return line
    }
}
