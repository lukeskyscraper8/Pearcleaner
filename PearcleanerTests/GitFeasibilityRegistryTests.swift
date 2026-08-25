import Foundation
import XCTest
@testable import Pearcleaner
@testable import ProjectScannerCore

final class GitFeasibilityRegistryTests: XCTestCase {
    func testMissingManifestDisablesGitEvidence() throws {
        let evidenceRoot = try makeTemporaryEvidenceRoot()
        let registry = GitFeasibilityRegistry(
            evidenceRoot: evidenceRoot,
            hostProbe: FixedGitFeasibilityHostProbe(metadata: sampleHostMetadata())
        )

        let snapshot = registry.currentSnapshot()

        XCTAssertFalse(snapshot.isEnabled)
        XCTAssertEqual(
            snapshot.availability,
            .unavailable(reason: .gitTupleNotAllowlisted)
        )
    }

    func testMatchingTupleEnablesGitEvidence() throws {
        let host = sampleHostMetadata()
        let evidenceRoot = try makeTemporaryEvidenceRoot()
        try writeManifest(
            at: evidenceRoot,
            host: host,
            runnerVersion: host.runnerVersion,
            overallStatus: "passed"
        )

        let registry = GitFeasibilityRegistry(
            evidenceRoot: evidenceRoot,
            hostProbe: FixedGitFeasibilityHostProbe(metadata: host)
        )

        let snapshot = registry.currentSnapshot()

        XCTAssertTrue(snapshot.isEnabled)
        guard case let .enabled(metadata) = snapshot.availability else {
            return XCTFail("Expected enabled snapshot")
        }
        XCTAssertEqual(metadata.osBuildFamily, host.osBuildFamily)
        XCTAssertEqual(metadata.architecture, host.architecture)
        XCTAssertEqual(metadata.pearcleanerVersion, host.pearcleanerVersion)
        XCTAssertEqual(metadata.runnerVersion, host.runnerVersion)
        XCTAssertEqual(metadata.appleGitVersion, host.appleGitVersion)
        XCTAssertEqual(metadata.harnessVersion, host.pearcleanerVersion)
    }

    func testStaleRunnerVersionDisablesGitEvidence() throws {
        let host = sampleHostMetadata()
        let evidenceRoot = try makeTemporaryEvidenceRoot()
        try writeManifest(
            at: evidenceRoot,
            host: host,
            runnerVersion: "9.9.9-stale",
            overallStatus: "passed"
        )

        let registry = GitFeasibilityRegistry(
            evidenceRoot: evidenceRoot,
            hostProbe: FixedGitFeasibilityHostProbe(metadata: host)
        )

        let snapshot = registry.currentSnapshot()

        XCTAssertFalse(snapshot.isEnabled)
        XCTAssertEqual(
            snapshot.availability,
            .unavailable(reason: .gitTupleNotAllowlisted)
        )
    }

    private func sampleHostMetadata() -> GitFeasibilityHostMetadata {
        GitFeasibilityHostMetadata(
            osBuildFamily: "macOS-14.5-23F79",
            architecture: "arm64",
            pearcleanerVersion: "1.0.0",
            runnerVersion: "0.0.0-not-implemented",
            appleGitVersion: "git version 2.39.5 (Apple Git-154)"
        )
    }

    private func makeTemporaryEvidenceRoot() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func writeManifest(
        at evidenceRoot: URL,
        host: GitFeasibilityHostMetadata,
        runnerVersion: String,
        overallStatus: String
    ) throws {
        let tupleDirectory = evidenceRoot.appendingPathComponent(
            GitFeasibilityTupleNaming.directoryName(
                osBuildFamily: host.osBuildFamily,
                architecture: host.architecture
            ),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tupleDirectory, withIntermediateDirectories: true)

        let manifest: [String: Any] = [
            "schemaVersion": 1,
            "pearcleanerVersion": host.pearcleanerVersion,
            "harnessVersion": host.pearcleanerVersion,
            "runnerVersion": runnerVersion,
            "appleGitVersion": host.appleGitVersion,
            "osBuildFamily": host.osBuildFamily,
            "architecture": host.architecture,
            "testTimestamp": "2023-11-14T22:13:20Z",
            "overallStatus": overallStatus,
            "scenarios": [
                [
                    "id": "descriptor_transfer",
                    "status": "passed",
                    "passed": true,
                    "sandboxLogPath": NSNull(),
                    "filesystemSnapshotPath": NSNull(),
                    "details": [:] as [String: String],
                ],
            ],
        ]

        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        let manifestURL = tupleDirectory.appendingPathComponent("manifest.json", isDirectory: false)
        try data.write(to: manifestURL, options: .atomic)
    }
}

private struct FixedGitFeasibilityHostProbe: GitFeasibilityHostProbing {
    let metadata: GitFeasibilityHostMetadata

    func currentHostMetadata() -> GitFeasibilityHostMetadata {
        metadata
    }
}
