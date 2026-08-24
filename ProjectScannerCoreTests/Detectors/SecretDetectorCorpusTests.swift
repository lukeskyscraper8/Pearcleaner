import Foundation
import XCTest
@testable import ProjectScannerCore

final class SecretDetectorCorpusTests: XCTestCase {
    private struct CorpusManifest: Decodable {
        struct PositiveEntry: Decodable {
            let file: String
            let rule_id: String
            let category: String
        }

        struct FileEntry: Decodable {
            let file: String
        }

        let positives: [PositiveEntry]
        let negatives: [FileEntry]
        let entropy_only: [FileEntry]
    }

    func testHoldoutCorpusMeetsQualityGates() throws {
        let manifest = try loadManifest()
        let identityKey = try SecretMatchIdentityKey.makeEphemeral()
        let detector = SecretDetector()

        var truePositives = 0
        for entry in manifest.positives {
            let data = try loadFixture(entry.file)
            let matches = detector.scanData(data, identityKey: identityKey)
            let expectedRule = RuleID(rawValue: entry.rule_id)
            XCTAssertNotNil(expectedRule, "Invalid rule id \(entry.rule_id)")
            let detected = matches.contains { $0.ruleID == expectedRule }
            if detected {
                truePositives += 1
            } else {
                XCTFail("Missed positive \(entry.file) for rule \(entry.rule_id)")
            }
        }

        var falsePositives = 0
        for entry in manifest.negatives {
            let data = try loadFixture(entry.file)
            let matches = detector.scanData(data, identityKey: identityKey)
            if !matches.isEmpty {
                falsePositives += 1
                XCTFail("False positive in \(entry.file): \(matches.map(\.ruleID.rawValue))")
            }
        }

        XCTAssertEqual(truePositives, manifest.positives.count)
        let evaluated = truePositives + falsePositives
        let precision = evaluated == 0 ? 0 : Double(truePositives) / Double(evaluated)
        let wilsonLowerBound = wilsonScoreLowerBound(
            positive: truePositives,
            total: evaluated
        )
        XCTAssertGreaterThanOrEqual(precision, 0.95)
        XCTAssertGreaterThanOrEqual(wilsonLowerBound, 0.90)
    }

    func testEntropyOnlySamplesProduceZeroFindings() throws {
        let manifest = try loadManifest()
        let identityKey = try SecretMatchIdentityKey.makeEphemeral()
        let detector = SecretDetector()

        for entry in manifest.entropy_only {
            let data = try loadFixture(entry.file)
            let matches = detector.scanData(data, identityKey: identityKey)
            XCTAssertTrue(matches.isEmpty, "Entropy-only fixture \(entry.file) produced findings")
        }
    }

    func testBoundaryMatchAcrossSixtyFourKiBChunkIsDetected() throws {
        let identityKey = try SecretMatchIdentityKey.makeEphemeral()
        let detector = SecretDetector()
        let token = "AKIA" + String(repeating: "A", count: 16)
        let padding = Data(repeating: 0x61, count: 64 * 1_024 - 4)
        let data = padding + Data(token.utf8)

        let matches = detector.scanData(data, identityKey: identityKey)
        XCTAssertFalse(matches.isEmpty, "Expected boundary-spanning AWS key detection")
        XCTAssertTrue(matches.contains { $0.ruleID.rawValue == "secret.aws.access_key_id" })
    }

    func testOversizedAdmissionRecordsOrdinaryFileTooLarge() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let limits = try ScanLimitOverrides(secretFileBytes: 8).applying(to: .defaults)
        let oversized = Data("prefix AKIA0123456789ABCDEF".utf8)
        _ = try fixture.regularFile(named: "oversized.env", contents: oversized)

        let capability = try RootCapability.open(selectedURL: fixture.url)
        let broker = try capability.makeFileBroker(limits: limits)
        let traversal = try await broker.makeTraversal()
        var candidate: FileCandidate?
        while let event = try await traversal.next() {
            if case let .candidate(value) = event {
                candidate = value
            }
        }
        let resolvedCandidate = try XCTUnwrap(candidate)

        let ledger = CoverageLedger(sessionID: ScanSessionID(rawValue: UUID()))
        let transaction = try await ledger.begin(.secret)
        try await ledger.record(.candidate(files: 1, bytes: resolvedCandidate.byteCount), in: transaction)

        let admission = await broker.makeContentBroker().read(
            resolvedCandidate,
            for: .secretInspection
        )
        let session = SessionStore(limits: limits)
        let identityKey = try SecretMatchIdentityKey.makeEphemeral()
        let result = await SecretDetector(limits: limits).inspectAdmission(
            admission,
            candidate: resolvedCandidate,
            sourceView: .workingTree,
            transaction: transaction,
            ledger: ledger,
            session: session,
            identityKey: identityKey
        )

        guard case let .skipped(reason, _) = result else {
            return XCTFail("Expected oversized skip, got \(result)")
        }
        XCTAssertEqual(reason, .ordinaryFileTooLarge)
        try await ledger.finish(transaction)
    }

    func testMaskedEvidenceNeverContainsRawMatchBytes() throws {
        let identityKey = try SecretMatchIdentityKey.makeEphemeral()
        let token = "ghp_" + String(repeating: "a", count: 36)
        let data = Data("export const token = \"\(token)\";".utf8)
        let matches = SecretDetector().scanData(data, identityKey: identityKey)
        let match = try XCTUnwrap(matches.first)
        guard let evidence = match.evidence else {
            return XCTFail("Expected redacted evidence")
        }
        XCTAssertFalse(evidence.text.contains(token))
        XCTAssertTrue(evidence.text.contains("[REDACTED]"))
    }

    private func loadManifest() throws -> CorpusManifest {
        let url = corpusRoot().appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CorpusManifest.self, from: data)
    }

    private func loadFixture(_ relativePath: String) throws -> Data {
        let url = corpusRoot().appendingPathComponent(relativePath)
        return try Data(contentsOf: url)
    }

    private func corpusRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("script/fixtures/secret_detector_corpus", isDirectory: true)
    }

    private func wilsonScoreLowerBound(positive: Int, total: Int, z: Double = 1.96) -> Double {
        guard total > 0 else { return 0 }
        let n = Double(total)
        let p = Double(positive) / n
        let z2 = z * z
        let numerator = p + z2 / (2 * n) - z * sqrt((p * (1 - p) + z2 / (4 * n)) / n)
        let denominator = 1 + z2 / n
        return numerator / denominator
    }
}
