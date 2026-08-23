import Foundation
import XCTest
@testable import ProjectScannerCore

final class SessionStorePrivacyTests: XCTestCase {
    func testSessionStoreAcceptsRedactedEvidenceAndRelativeLocation() async throws {
        let finding = try makeFinding(
            path: PrivacyCanaries.path,
            evidenceSource: "prefix \(PrivacyCanaries.secret) suffix"
        )
        let store = SessionStore(limits: .defaults)

        let result = await store.append(finding)
        let snapshot = await store.snapshot()

        XCTAssertEqual(result, .appended)
        XCTAssertEqual(snapshot, [finding])
        XCTAssertEqual(snapshot.first?.location, finding.location)
        XCTAssertEqual(snapshot.first?.displayPath?.text, PrivacyCanaries.path)
        XCTAssertEqual(snapshot.first?.evidence?.text, "prefix [REDACTED] suffix")
    }

    func testSessionSnapshotContainsOnlyTypedRedactedEvidence() async throws {
        let store = SessionStore(limits: .defaults)
        let finding = try makeFinding(evidenceSource: PrivacyCanaries.secret)
        let appendResult = await store.append(finding)
        XCTAssertEqual(appendResult, .appended)

        let snapshot = await store.snapshot()

        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot[0].evidence?.text, "[REDACTED]")
        XCTAssertFalse(snapshot[0].evidence?.text.contains(PrivacyCanaries.secret) == true)
        XCTAssertFalse(isCodable(SessionFinding.self))
        XCTAssertFalse(isCodable(SessionStore.self))
    }

    func testSessionStoreAcceptsExactFindingAndModelBudgetBoundary() async throws {
        let findingBoundaryStore = SessionStore(limits: .defaults)
        let smallFinding = try makeFinding(evidenceSource: PrivacyCanaries.secret)

        for _ in 0..<10_000 {
            let result = await findingBoundaryStore.append(smallFinding)
            XCTAssertEqual(result, .appended)
        }
        let findingBoundarySnapshot = await findingBoundaryStore.snapshot()
        XCTAssertEqual(findingBoundarySnapshot.count, 10_000)

        let modelBoundaryStore = SessionStore(limits: .defaults)
        let exactBudgetFinding = try makeExactModelBudgetFinding()
        let asciiSeverity = try XCTUnwrap(UpstreamSeverity(scheme: "S", value: "A"))
        let emojiSeverity = try XCTUnwrap(UpstreamSeverity(scheme: "S", value: "🙂"))
        let asciiFinding = SessionFinding(
            header: makeHeader(assessment: .upstreamSeverity([asciiSeverity])),
            location: nil,
            displayPath: nil,
            line: nil,
            evidence: nil
        )
        let emojiFinding = SessionFinding(
            header: makeHeader(assessment: .upstreamSeverity([emojiSeverity])),
            location: nil,
            displayPath: nil,
            line: nil,
            evidence: nil
        )
        XCTAssertEqual(
            SessionStore.estimatedModelBytes(for: exactBudgetFinding),
            128 * 1_024 * 1_024
        )
        XCTAssertEqual(
            SessionStore.estimatedModelBytes(for: emojiFinding)! - SessionStore.estimatedModelBytes(for: asciiFinding)!,
            3
        )
        let modelBoundaryResult = await modelBoundaryStore.append(exactBudgetFinding)
        let modelBoundarySnapshot = await modelBoundaryStore.snapshot()
        XCTAssertEqual(modelBoundaryResult, .appended)
        XCTAssertEqual(modelBoundarySnapshot.count, 1)
    }

    func testSessionStoreRejectsOneFindingOrByteOverBudgetBeforeRetention() async throws {
        let countStore = SessionStore(limits: .defaults)
        let smallFinding = try makeFinding(evidenceSource: PrivacyCanaries.secret)
        for _ in 0..<10_000 {
            let result = await countStore.append(smallFinding)
            XCTAssertEqual(result, .appended)
        }

        let countLimitResult = await countStore.append(smallFinding)
        let countSnapshot = await countStore.snapshot()
        XCTAssertEqual(countLimitResult, .limitReached)
        XCTAssertEqual(countSnapshot.count, 10_000)

        let byteStore = SessionStore(limits: .defaults)
        let exactBudgetFinding = try makeExactModelBudgetFinding()
        let exactResult = await byteStore.append(exactBudgetFinding)
        let byteLimitResult = await byteStore.append(smallFinding)
        let byteSnapshot = await byteStore.snapshot()
        XCTAssertEqual(exactResult, .appended)
        XCTAssertEqual(byteLimitResult, .limitReached)
        XCTAssertEqual(byteSnapshot, [exactBudgetFinding])
    }

    func testConcurrentSessionAppendsNeverExceedFindingOrModelByteLimits() async throws {
        let store = SessionStore(limits: .defaults)
        let finding = try makeFinding(evidenceSource: PrivacyCanaries.secret)

        let results = await withTaskGroup(of: SessionAppendResult.self) { group in
            for _ in 0..<12_000 {
                group.addTask { await store.append(finding) }
            }
            return await group.reduce(into: [SessionAppendResult]()) { $0.append($1) }
        }
        let snapshot = await store.snapshot()
        let retainedBytes = snapshot.reduce(UInt64(0)) {
            $0 + SessionStore.estimatedModelBytes(for: $1)!
        }

        XCTAssertEqual(results.filter { $0 == .appended }.count, 10_000)
        XCTAssertEqual(results.filter { $0 == .limitReached }.count, 2_000)
        XCTAssertEqual(snapshot.count, 10_000)
        XCTAssertLessThanOrEqual(retainedBytes, 128 * 1_024 * 1_024)

        let byteStore = SessionStore(limits: .defaults)
        let exactBudgetFinding = try makeExactModelBudgetFinding()
        let byteResults = await withTaskGroup(of: SessionAppendResult.self) { group in
            for _ in 0..<2 {
                group.addTask { await byteStore.append(exactBudgetFinding) }
            }
            return await group.reduce(into: [SessionAppendResult]()) { $0.append($1) }
        }
        let byteSnapshot = await byteStore.snapshot()
        XCTAssertEqual(byteResults.filter { $0 == .appended }.count, 1)
        XCTAssertEqual(byteResults.filter { $0 == .limitReached }.count, 1)
        XCTAssertEqual(byteSnapshot.count, 1)
    }

    func testClearingSessionReleasesAllDetailedFindings() async throws {
        let store = SessionStore(limits: .defaults)
        let exactBudgetFinding = try makeExactModelBudgetFinding()
        let firstResult = await store.append(exactBudgetFinding)
        XCTAssertEqual(firstResult, .appended)

        await store.clear()

        let emptySnapshot = await store.snapshot()
        let secondResult = await store.append(exactBudgetFinding)
        let secondSnapshot = await store.snapshot()
        XCTAssertTrue(emptySnapshot.isEmpty)
        XCTAssertEqual(secondResult, .appended)
        XCTAssertEqual(secondSnapshot, [exactBudgetFinding])
    }

    func testDiagnosticEventContainsOnlyClosedCodesAndNumbers() throws {
        let event = makeDiagnosticEvent()
        let fieldNames = Set(Mirror(reflecting: event).children.compactMap(\.label))

        XCTAssertEqual(
            fieldNames,
            [
                "sessionID", "detector", "code", "reason", "count", "bytes",
                "durationMilliseconds", "systemCategory"
            ]
        )
        XCTAssertEqual(event.detector, .secret)
        XCTAssertEqual(event.code, .coverageLimited)
        XCTAssertEqual(event.reason, .globalByteBudget)
        XCTAssertEqual(event.count, 2)
        XCTAssertEqual(event.bytes, 4_096)
        XCTAssertEqual(event.durationMilliseconds, 25)
        XCTAssertEqual(event.systemCategory, .resourceLimit)
    }

    func testSecretCanaryNeverAppearsInEvidenceOrRecordedDiagnosticFields() async throws {
        XCTAssertEqual(PrivacyCanaries.all.count, Set(PrivacyCanaries.all).count)
        XCTAssertTrue(PrivacyCanaries.all.allSatisfy { $0.utf8.count == 48 && $0.allSatisfy(\.isASCII) })
        let store = SessionStore(limits: .defaults)
        let advisorySeverity = try XCTUnwrap(
            UpstreamSeverity(scheme: "OSV", value: PrivacyCanaries.advisory)
        )
        let success = try makeFinding(
            path: PrivacyCanaries.path,
            evidenceSource: "\(PrivacyCanaries.package) \(PrivacyCanaries.secret) \(PrivacyCanaries.script)",
            assessment: .upstreamSeverity([advisorySeverity])
        )
        let successResult = await store.append(success)
        XCTAssertEqual(successResult, .appended)

        let exactBudgetFinding = try makeExactModelBudgetFinding()
        let budgetStore = SessionStore(limits: .defaults)
        let exactResult = await budgetStore.append(exactBudgetFinding)
        let limitResult = await budgetStore.append(success)
        XCTAssertEqual(exactResult, .appended)
        XCTAssertEqual(limitResult, .limitReached)

        let sink = RecordingDiagnosticSink()
        await sink.record(makeDiagnosticEvent())
        let events = await sink.snapshot()
        let successSnapshot = await store.snapshot()
        let evidenceStrings = successSnapshot.compactMap { $0.evidence?.text }
        let diagnosticStrings = events.flatMap(allDiagnosticStrings)

        XCTAssertEqual(successSnapshot.first?.displayPath?.text, PrivacyCanaries.path)
        XCTAssertTrue(evidenceStrings.contains { $0.contains(PrivacyCanaries.package) })
        XCTAssertTrue(evidenceStrings.contains { $0.contains(PrivacyCanaries.script) })
        guard case let .upstreamSeverity(severities)? = successSnapshot.first?.header.assessment else {
            return XCTFail("Expected the advisory canary in session-only severity data.")
        }
        XCTAssertTrue(severities.contains { $0.value == PrivacyCanaries.advisory })
        XCTAssertFalse(evidenceStrings.contains { $0.contains(PrivacyCanaries.secret) })
        for canary in PrivacyCanaries.all {
            XCTAssertFalse(diagnosticStrings.contains { $0.contains(canary) })
        }
    }

    private func makeFinding(
        path: String? = nil,
        evidenceSource: String,
        assessment: FindingAssessment = .confidence(.high)
    ) throws -> SessionFinding {
        let location: VerifiedRelativePath?
        let displayPath: EscapedDisplayPath?
        if let path {
            let component = try VerifiedPathComponent(bytes: Data(path.utf8))
            let verified = try VerifiedRelativePath(components: [component])
            location = verified
            displayPath = verified.escapedForDisplay()
        } else {
            location = nil
            displayPath = nil
        }

        return SessionFinding(
            header: makeHeader(assessment: assessment),
            location: location,
            displayPath: displayPath,
            line: 42,
            evidence: try makeEvidence(from: evidenceSource)
        )
    }

    private func makeHeader(assessment: FindingAssessment) -> SessionFindingHeader {
        SessionFindingHeader(
            kind: .probableSecret,
            ruleID: RuleID(rawValue: "secret.primary")!,
            ruleVersion: 1,
            sourceView: .workingTree,
            detectorID: .secret,
            coverageTransactionID: CoverageTransactionID(
                rawValue: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
            ),
            assessment: assessment,
            provenance: .secretRule,
            suppressionEligibility: .eligible,
            suppressionState: .notSuppressed
        )
    }

    private func makeEvidence(from source: String) throws -> RedactedSourceField {
        let primaryRule = RuleID(rawValue: "secret.primary")!
        let secondaryRule = RuleID(rawValue: "secret.secondary")!
        var redactor = try XCTUnwrap(
            PrivacyRedactor(expectedRuleIDs: [primaryRule, secondaryRule])
        )
        let bytes = Array(source.utf8)
        let secretBytes = Array(PrivacyCanaries.secret.utf8)
        let span = try XCTUnwrap(bytes.range(of: secretBytes))
        let result = bytes.withUnsafeBytes {
            redactor.redact(
                utf8: $0,
                ruleResults: [
                    .complete(
                        ruleID: primaryRule,
                        spans: [RedactionSpan(utf8Range: span)]
                    ),
                    .complete(ruleID: secondaryRule, spans: [])
                ]
            )
        }
        guard case let .redacted(field) = result else {
            throw PrivacyTestError.redactionFailed
        }
        return field
    }

    private func makeExactModelBudgetFinding() throws -> SessionFinding {
        let budget = UInt64(128 * 1_024 * 1_024)
        let seed = try XCTUnwrap(UpstreamSeverity(scheme: "S", value: "V"))
        let base = SessionFinding(
            header: makeHeader(assessment: .upstreamSeverity([])),
            location: nil,
            displayPath: nil,
            line: nil,
            evidence: nil
        )
        let withOne = SessionFinding(
            header: makeHeader(assessment: .upstreamSeverity([seed])),
            location: nil,
            displayPath: nil,
            line: nil,
            evidence: nil
        )
        let baseBytes = try XCTUnwrap(SessionStore.estimatedModelBytes(for: base))
        let oneBytes = try XCTUnwrap(SessionStore.estimatedModelBytes(for: withOne))
        guard oneBytes > baseBytes else { throw PrivacyTestError.cannotReachExactBudget }
        let minimumSeverityBytes = oneBytes - baseBytes
        let maximumSeverity = try XCTUnwrap(
            UpstreamSeverity(
                scheme: String(repeating: "S", count: 256),
                value: String(repeating: "V", count: 256)
            )
        )
        let withMaximum = SessionFinding(
            header: makeHeader(assessment: .upstreamSeverity([maximumSeverity])),
            location: nil,
            displayPath: nil,
            line: nil,
            evidence: nil
        )
        let maximumFindingBytes = try XCTUnwrap(SessionStore.estimatedModelBytes(for: withMaximum))
        guard maximumFindingBytes > baseBytes else {
            throw PrivacyTestError.cannotReachExactBudget
        }
        let maximumSeverityBytes = maximumFindingBytes - baseBytes
        let maximumCount = Int((budget - baseBytes) / maximumSeverityBytes)
        var severities = Array(repeating: maximumSeverity, count: maximumCount)
        var retained = baseBytes + UInt64(maximumCount) * maximumSeverityBytes
        while retained < budget {
            let remaining = budget - retained
            if remaining >= minimumSeverityBytes {
                let dynamicBytes = Int(min(remaining - (minimumSeverityBytes - 2), 512))
                let schemeBytes = min(dynamicBytes - 1, 256)
                let valueBytes = dynamicBytes - schemeBytes
                let severity = try XCTUnwrap(
                    UpstreamSeverity(
                        scheme: String(repeating: "S", count: schemeBytes),
                        value: String(repeating: "V", count: valueBytes)
                    )
                )
                severities.append(severity)
                retained += try XCTUnwrap(
                    SessionStore.estimatedModelBytes(
                        for: SessionFinding(
                            header: makeHeader(assessment: .upstreamSeverity([severity])),
                            location: nil,
                            displayPath: nil,
                            line: nil,
                            evidence: nil
                        )
                    )
                ) - baseBytes
            } else {
                throw PrivacyTestError.cannotReachExactBudget
            }
        }
        let finding = SessionFinding(
            header: makeHeader(assessment: .upstreamSeverity(severities)),
            location: nil,
            displayPath: nil,
            line: nil,
            evidence: nil
        )
        guard SessionStore.estimatedModelBytes(for: finding) == budget else {
            throw PrivacyTestError.cannotReachExactBudget
        }
        return finding
    }

    private func makeDiagnosticEvent() -> ScannerDiagnosticEvent {
        ScannerDiagnosticEvent(
            sessionID: ScanSessionID(
                rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
            ),
            detector: .secret,
            code: .coverageLimited,
            reason: .globalByteBudget,
            count: 2,
            bytes: 4_096,
            durationMilliseconds: 25,
            systemCategory: .resourceLimit
        )
    }

    private func allDiagnosticStrings(_ event: ScannerDiagnosticEvent) -> [String] {
        [
            event.sessionID.rawValue.uuidString,
            event.detector?.rawValue,
            event.code.rawValue,
            event.reason?.rawValue,
            event.systemCategory?.rawValue
        ].compactMap { $0 }
    }

    private func isCodable<T>(_ type: T.Type) -> Bool {
        type is any Codable.Type
    }
}

private actor RecordingDiagnosticSink: ScannerDiagnosticSinking {
    private var events: [ScannerDiagnosticEvent] = []

    func record(_ event: ScannerDiagnosticEvent) async {
        events.append(event)
    }

    func snapshot() -> [ScannerDiagnosticEvent] {
        events
    }
}

private enum PrivacyTestError: Error {
    case redactionFailed
    case cannotReachExactBudget
}

private extension Array where Element == UInt8 {
    func range(of needle: [UInt8]) -> Range<Int>? {
        guard !needle.isEmpty, needle.count <= count else { return nil }
        for start in 0...count - needle.count where self[start..<start + needle.count].elementsEqual(needle) {
            return start..<start + needle.count
        }
        return nil
    }
}
