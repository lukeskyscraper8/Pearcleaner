import Foundation
import XCTest
@testable import ProjectScannerCore

final class SecretMatchCorrelatorTests: XCTestCase {
    func testSameIdentityAcrossWorkingTreeIndexAndHeadProducesUnifiedExposure() throws {
        let path = try verifiedPath("config.env")
        let identityKey = try SecretMatchIdentityKey.makeEphemeral()
        let token = "ghp_" + String(repeating: "a", count: 36)
        let data = Data("export const token = \"\(token)\";".utf8)
        let match = try XCTUnwrap(SecretDetector().scanData(data, identityKey: identityKey).first)
        let displayPath = try XCTUnwrap(path.escapedForDisplay())

        let observations = [
            SecretMatchObservation(path: path, sourceView: .workingTree, match: match, displayPath: displayPath),
            SecretMatchObservation(path: path, sourceView: .index, match: match, displayPath: displayPath),
            SecretMatchObservation(path: path, sourceView: .currentHead, match: match, displayPath: displayPath),
        ]
        let gitFacts = GitPathFacts(
            repositoryID: RepositoryCoverageID(),
            indexedPaths: [path],
            headPaths: [path],
            headObjectIDsByPath: [:],
            stagedPaths: [path],
            ignoredPaths: .available([]),
            workingTreePaths: [path]
        )

        let correlated = SecretMatchCorrelator().correlate(
            observations: observations,
            gitFacts: gitFacts
        )

        XCTAssertEqual(correlated.count, 1)
        let exposure = try XCTUnwrap(correlated.first?.exposure)
        XCTAssertTrue(exposure.inWorkingTree)
        XCTAssertTrue(exposure.inIndex)
        XCTAssertTrue(exposure.inCurrentHead)
        XCTAssertTrue(exposure.isTracked)
        XCTAssertTrue(exposure.isStaged)
        XCTAssertFalse(exposure.isUntracked)
        XCTAssertFalse(exposure.isIgnored)
        XCTAssertEqual(correlated.first?.observations.count, 3)
    }

    func testDistinctIdentitiesAtSamePathRemainSeparate() throws {
        let path = try verifiedPath("config.env")
        let identityKey = try SecretMatchIdentityKey.makeEphemeral()
        let firstMatch = try XCTUnwrap(
            SecretDetector().scanData(
                Data("ghp_\(String(repeating: "a", count: 36))".utf8),
                identityKey: identityKey
            ).first
        )
        let secondMatch = try XCTUnwrap(
            SecretDetector().scanData(
                Data("ghp_\(String(repeating: "b", count: 36))".utf8),
                identityKey: identityKey
            ).first
        )
        let displayPath = try XCTUnwrap(path.escapedForDisplay())
        let observations = [
            SecretMatchObservation(path: path, sourceView: .workingTree, match: firstMatch, displayPath: displayPath),
            SecretMatchObservation(path: path, sourceView: .workingTree, match: secondMatch, displayPath: displayPath),
        ]

        let correlated = SecretMatchCorrelator().correlate(observations: observations, gitFacts: nil)

        XCTAssertEqual(correlated.count, 2)
        XCTAssertNotEqual(correlated[0].identity, correlated[1].identity)
    }

    func testWorkingTreeOnlyExposureWithoutGitFacts() throws {
        let path = try verifiedPath("local.env")
        let observation = try makeObservation(path: path, sourceView: .workingTree)

        let correlated = SecretMatchCorrelator().correlate(
            observations: [observation],
            gitFacts: nil
        )
        let exposure = try XCTUnwrap(correlated.first?.exposure)

        XCTAssertTrue(exposure.inWorkingTree)
        XCTAssertFalse(exposure.inIndex)
        XCTAssertFalse(exposure.inCurrentHead)
        XCTAssertFalse(exposure.isTracked)
        XCTAssertFalse(exposure.isStaged)
        XCTAssertFalse(exposure.isUntracked)
        XCTAssertFalse(exposure.isIgnored)
    }

    func testUntrackedAndIgnoredPathsClassifyFromGitFacts() throws {
        let trackedPath = try verifiedPath("tracked.env")
        let untrackedPath = try verifiedPath("untracked.env")
        let ignoredPath = try verifiedPath("ignored.env")
        let gitFacts = GitPathFacts(
            repositoryID: RepositoryCoverageID(),
            indexedPaths: [trackedPath],
            headPaths: [trackedPath],
            headObjectIDsByPath: [:],
            stagedPaths: [],
            ignoredPaths: .available([ignoredPath]),
            workingTreePaths: [trackedPath, untrackedPath, ignoredPath]
        )
        let observations = [
            try makeObservation(path: trackedPath, sourceView: .workingTree),
            try makeObservation(path: untrackedPath, sourceView: .workingTree),
            try makeObservation(path: ignoredPath, sourceView: .workingTree),
        ]

        let correlated = SecretMatchCorrelator().correlate(
            observations: observations,
            gitFacts: gitFacts
        )
        let byPath = Dictionary(uniqueKeysWithValues: correlated.map { ($0.path, $0.exposure) })

        XCTAssertTrue(byPath[trackedPath]?.isTracked == true)
        XCTAssertFalse(byPath[trackedPath]?.isUntracked == true)
        XCTAssertTrue(byPath[untrackedPath]?.isUntracked == true)
        XCTAssertFalse(byPath[untrackedPath]?.isTracked == true)
        XCTAssertTrue(byPath[ignoredPath]?.isIgnored == true)
    }

    func testSessionFindingPreservesSourceViewPerObservation() throws {
        let path = try verifiedPath("config.env")
        let identityKey = try SecretMatchIdentityKey.makeEphemeral()
        let match = try XCTUnwrap(
            SecretDetector().scanData(
                Data("ghp_\(String(repeating: "c", count: 36))".utf8),
                identityKey: identityKey
            ).first
        )
        let displayPath = try XCTUnwrap(path.escapedForDisplay())
        let correlator = SecretMatchCorrelator()
        let correlated = correlator.correlate(
            observations: [
                SecretMatchObservation(path: path, sourceView: .workingTree, match: match, displayPath: displayPath),
                SecretMatchObservation(path: path, sourceView: .index, match: match, displayPath: displayPath),
            ],
            gitFacts: nil
        )
        let keyLease = try persistentLease()
        let transaction = CoverageTransactionID(
            rawValue: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        )
        let projectID = ProjectID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)

        let findings = try correlator.makeSessionFindings(
            from: try XCTUnwrap(correlated.first),
            transaction: transaction,
            projectID: projectID,
            keyLease: keyLease
        )

        XCTAssertEqual(findings.map(\.header.sourceView), [.workingTree, .index])
        XCTAssertEqual(findings.map(\.header.kind), [.probableSecret, .probableSecret])
        XCTAssertEqual(findings.first?.location, path)
        XCTAssertEqual(findings.first?.displayPath?.text, displayPath.text)
    }

    func testPersistentSuppressionFingerprintMatchesEncoder() throws {
        let observation = try makeObservation(path: try verifiedPath("config.env"), sourceView: .workingTree)
        let projectID = ProjectID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        let keyLease = try persistentLease()
        let correlator = SecretMatchCorrelator()

        let fromCorrelator = try correlator.suppressionFingerprint(
            observation: observation,
            projectID: projectID,
            keyMaterial: keyLease.material
        )
        let fromEncoder = try SecretSuppressionFingerprintEncoder.fingerprint(
            projectID: projectID,
            path: observation.path,
            ruleID: observation.match.ruleID,
            ruleVersion: observation.match.ruleVersion,
            matchIdentity: observation.match.identity,
            keyMaterial: keyLease.material
        )

        XCTAssertEqual(fromCorrelator, fromEncoder)
    }

    func testSuppressedFingerprintMarksFindingSuppressed() throws {
        let observation = try makeObservation(path: try verifiedPath("config.env"), sourceView: .workingTree)
        let projectID = ProjectID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        let keyLease = try persistentLease()
        let correlator = SecretMatchCorrelator()
        let fingerprint = try correlator.suppressionFingerprint(
            observation: observation,
            projectID: projectID,
            keyMaterial: keyLease.material
        )

        let finding = try correlator.makeSessionFinding(
            observation: observation,
            transaction: CoverageTransactionID(rawValue: UUID()),
            projectID: projectID,
            keyLease: keyLease,
            suppressedFingerprints: [fingerprint]
        )

        XCTAssertEqual(finding.header.suppressionEligibility, .eligible)
        XCTAssertEqual(finding.header.suppressionState, .suppressed)
    }

    func testEphemeralKeyLeaseMarksSuppressionUnavailable() throws {
        let observation = try makeObservation(path: try verifiedPath("config.env"), sourceView: .workingTree)
        let ephemeralLease = try ProjectKeyLease.ephemeral(
            ProjectKeyMaterial(
                generation: UUID(),
                keyBytes: Data(0..<32)
            )
        )

        let finding = try SecretMatchCorrelator().makeSessionFinding(
            observation: observation,
            transaction: CoverageTransactionID(rawValue: UUID()),
            projectID: ProjectID(rawValue: UUID()),
            keyLease: ephemeralLease
        )

        XCTAssertEqual(finding.header.suppressionEligibility, .ineligible(.ephemeralKeyState))
        XCTAssertEqual(finding.header.suppressionState, .unavailableEphemeral)
    }
}

private func makeObservation(
    path: VerifiedRelativePath,
    sourceView: SourceView
) throws -> SecretMatchObservation {
    let identityKey = try SecretMatchIdentityKey.makeEphemeral()
    let match = try XCTUnwrap(
        SecretDetector().scanData(
            Data("ghp_\(String(repeating: "d", count: 36))".utf8),
            identityKey: identityKey
        ).first
    )
    return SecretMatchObservation(
        path: path,
        sourceView: sourceView,
        match: match,
        displayPath: try XCTUnwrap(path.escapedForDisplay())
    )
}

private func verifiedPath(_ name: String) throws -> VerifiedRelativePath {
    try VerifiedRelativePath(components: [
        VerifiedPathComponent(bytes: Data(name.utf8)),
    ])
}

private func persistentLease() throws -> ProjectKeyLease {
    ProjectKeyLease.persistent(
        try ProjectKeyMaterial(
            generation: UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!,
            keyBytes: Data(0..<32)
        )
    )
}
