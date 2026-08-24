import Foundation
import XCTest
@testable import ProjectScannerCore

final class ScannerTypesTests: XCTestCase {
    func testSessionAndProjectIdentifiersAreIndependent() {
        let projectUUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let sessionUUID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let project = ProjectID(rawValue: projectUUID)
        let session = ScanSessionID(rawValue: sessionUUID)

        XCTAssertNotEqual(ObjectIdentifier(ProjectID.self), ObjectIdentifier(ScanSessionID.self))
        XCTAssertNotEqual(project.rawValue, session.rawValue)
        XCTAssertEqual(project.rawValue, projectUUID)
        XCTAssertEqual(session.rawValue, sessionUUID)
    }

    func testClosedEnumsExposeStablePersistenceCodes() {
        XCTAssertEqual(DetectorID.secret.rawValue, "secret")
        XCTAssertEqual(DetectorID.nodeLockfile.rawValue, "node_lockfile")
        XCTAssertEqual(DetectorID.advisory.rawValue, "advisory")
        XCTAssertEqual(DetectorTerminalState.unavailable.rawValue, "unavailable")
        XCTAssertEqual(ScanTerminalState.cancelled.rawValue, "cancelled")
        XCTAssertEqual(CoverageReasonCode.identityChanged.rawValue, "identity_changed")
    }

    func testFindingHeaderKeepsAssessmentProvenanceAndSuppressionIndependent() throws {
        let ruleID = try XCTUnwrap(RuleID(rawValue: "secret.github-token"))
        let coverageTransaction = CoverageTransactionID(
            rawValue: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        )
        let advisoryGeneration = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let header = SessionFindingHeader(
            kind: .vulnerability,
            ruleID: ruleID,
            ruleVersion: 7,
            sourceView: .index,
            detectorID: .advisory,
            coverageTransactionID: coverageTransaction,
            assessment: .confidence(.reviewSuggested),
            provenance: .advisory(source: .osv, generation: advisoryGeneration),
            suppressionEligibility: .ineligible(.unstableIdentity),
            suppressionState: .keyResetRequired
        )

        XCTAssertEqual(header.assessment, .confidence(.reviewSuggested))
        XCTAssertEqual(header.provenance, .advisory(source: .osv, generation: advisoryGeneration))
        XCTAssertEqual(header.suppressionEligibility, .ineligible(.unstableIdentity))
        XCTAssertEqual(header.suppressionState, .keyResetRequired)
        XCTAssertEqual(header.coverageTransactionID, coverageTransaction)
    }

    func testMaliciousPackageClassificationIsNotUpstreamSeverity() {
        let assessment = FindingAssessment.sourceClassifiedMaliciousPackage(.osv)

        XCTAssertEqual(assessment, .sourceClassifiedMaliciousPackage(.osv))
    }

    func testMissingUpstreamSeverityRemainsEmptyRatherThanInvented() {
        let assessment = FindingAssessment.upstreamSeverity([])

        XCTAssertEqual(assessment, .upstreamSeverity([]))
    }

    func testRuleIDRejectsEmptyControlAndBidirectionalValues() {
        XCTAssertNil(RuleID(rawValue: ""))
        XCTAssertNil(RuleID(rawValue: "secret\nrule"))
        XCTAssertNil(RuleID(rawValue: "secret\u{202E}rule"))
        XCTAssertNotNil(RuleID(rawValue: "secret.github-token"))
    }

    func testUpstreamSeverityRejectsControlBidirectionalAndOversizedValues() {
        XCTAssertNil(UpstreamSeverity(scheme: "CVSS", value: "high\ncritical"))
        XCTAssertNil(UpstreamSeverity(scheme: "CVSS", value: "high\u{202E}critical"))
        XCTAssertNil(UpstreamSeverity(scheme: "CVSS", value: String(repeating: "a", count: 257)))
        XCTAssertNotNil(UpstreamSeverity(scheme: "CVSS", value: "HIGH"))
    }

    func testCoverageTransactionIdentifierIsSessionOnly() {
        let rawValue = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let identifier = CoverageTransactionID(rawValue: rawValue)

        XCTAssertEqual(identifier.rawValue, rawValue)
        XCTAssertFalse(isCodable(CoverageTransactionID.self))
    }

    func testSessionOnlyFindingTypesAreNotCodable() {
        XCTAssertFalse(isCodable(UpstreamSeverity.self))
        XCTAssertFalse(isCodable(FindingAssessment.self))
        XCTAssertFalse(isCodable(FindingProvenance.self))
        XCTAssertFalse(isCodable(SuppressionEligibility.self))
        XCTAssertFalse(isCodable(SessionSuppressionState.self))
        XCTAssertFalse(isCodable(SessionFindingHeader.self))
    }

    private func isCodable<T>(_ type: T.Type) -> Bool {
        type is any Codable.Type
    }
}
