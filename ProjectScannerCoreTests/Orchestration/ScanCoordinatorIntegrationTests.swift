import Foundation
import XCTest
@testable import ProjectScannerCore

final class ScanCoordinatorIntegrationTests: XCTestCase {
    func testMinimalRepoProducesWorkingTreeSecretFindings() async throws {
        let fixture = try copyMinimalRepoFixture()
        defer { fixture.remove() }
        try fixture.regularFile(
            named: "secrets.env",
            contents: Data("export TOKEN=\"\(githubToken())\"".utf8)
        )

        let result = try await runScan(
            on: fixture.url,
            feasibility: StubGitFeasibility(enabled: false)
        )

        XCTAssertFalse(result.findings.isEmpty)
        XCTAssertTrue(result.findings.contains { $0.header.kind == .probableSecret })
        XCTAssertTrue(result.findings.allSatisfy { $0.header.sourceView == .workingTree })
        XCTAssertNil(result.gitFacts)
        XCTAssertEqual(detector(.secret, in: result.coverage).terminalState, .complete)
        XCTAssertEqual(detector(.gitEvidence, in: result.coverage).terminalState, .unavailable)
    }

    func testGitCorrelationWhenFeasibilityEnabled() async throws {
        let fixture = try copyMinimalRepoFixture()
        defer { fixture.remove() }
        let secretPath = "secrets.env"
        let token = githubToken()
        try fixture.regularFile(
            named: secretPath,
            contents: Data("export TOKEN=\"\(token)\"".utf8)
        )

        let executor = StubGitExecutor(
            responses: [
                .success(GitEvidenceExecutionResponse(cachedPaths: [secretPath, "tracked.txt"])),
                .success(
                    GitEvidenceExecutionResponse(
                        headTreeEntries: [
                            GitHeadTreePathEntry(
                                path: secretPath,
                                objectID: GitObjectID(algorithm: .sha1, hex: String(repeating: "a", count: 40))!,
                                objectType: "blob"
                            ),
                        ]
                    )
                ),
                .success(
                    GitEvidenceExecutionResponse(
                        catFileBlobBytes: Data("export TOKEN=\"\(token)\"".utf8)
                    )
                ),
            ]
        )

        let result = try await runScan(
            on: fixture.url,
            feasibility: StubGitFeasibility(enabled: true),
            executor: executor
        )

        XCTAssertFalse(result.correlatedMatches.isEmpty)
        let exposure = try XCTUnwrap(result.correlatedMatches.first?.exposure)
        XCTAssertTrue(exposure.inWorkingTree)
        XCTAssertTrue(exposure.isTracked)
        XCTAssertTrue(exposure.inCurrentHead)
        XCTAssertNotNil(result.gitFacts)
        XCTAssertEqual(detector(.gitEvidence, in: result.coverage).terminalState, .complete)
    }

    func testPartialGitNeverReplacesLastCompleteSummary() async throws {
        let fixture = try await StateStoreFixture.make()
        defer { fixture.remove() }
        let registration = try await fixture.register()
        let completeMetadata = try testAttemptMetadata()
        _ = try await fixture.store.recordAttempt(
            projectID: registration.projectID,
            coverage: completeCoverage(),
            finishedAt: Date(timeIntervalSince1970: 1),
            metadata: completeMetadata,
            lease: fixture.lease
        )
        let priorComplete = try await fixture.store.loadSummary(projectID: registration.projectID)?
            .lastCompleteSummary

        let scanFixture = try copyMinimalRepoFixture()
        defer { scanFixture.remove() }
        let partialCoverage = try await runScan(
            on: scanFixture.url,
            feasibility: StubGitFeasibility(enabled: false)
        ).coverage

        _ = try await fixture.store.recordAttempt(
            projectID: registration.projectID,
            coverage: partialCoverage,
            finishedAt: Date(timeIntervalSince1970: 2),
            metadata: try AttemptSummaryMetadata(advisoryCacheSchemaVersion: nil, advisory: nil),
            lease: fixture.lease
        )

        let loadedValue = try await fixture.store.loadSummary(projectID: registration.projectID)
        let loaded = try XCTUnwrap(loadedValue)
        XCTAssertEqual(loaded.lastCompleteSummary, priorComplete)
        XCTAssertEqual(loaded.lastAttempt?.terminalState, partialCoverage.terminalState)
    }

    func testCancellationStopsWithinConfiguredLatency() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        for index in 0..<32 {
            _ = try fixture.regularFile(
                named: "file-\(index).env",
                contents: Data("export TOKEN=\"\(githubToken())\"".utf8)
            )
        }

        let limits = try ScanLimitOverrides(wallTimeMilliseconds: 1).applying(to: .defaults)
        let coordinator = ScanCoordinator(
            dependencies: ScanCoordinatorDependencies(
                feasibility: StubGitFeasibility(enabled: false),
                gitExecutor: StubGitExecutor()
            )
        )
        let capability = try RootCapability.open(selectedURL: fixture.url)
        let scanTask = Task {
            try await coordinator.scan(
                ScanCoordinatorRequest(
                    root: capability,
                    limits: limits,
                    identityKey: try SecretMatchIdentityKey.makeEphemeral()
                )
            )
        }
        let result = try await scanTask.value

        XCTAssertEqual(result.coverage.terminalState, .cancelled)
    }

    func testSecondConcurrentScanIsRejected() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        for index in 0..<256 {
            _ = try fixture.regularFile(
                named: "file-\(index).env",
                contents: Data("export TOKEN=\"\(githubToken())\"".utf8)
            )
        }

        let coordinator = ScanCoordinator(
            dependencies: ScanCoordinatorDependencies(
                feasibility: StubGitFeasibility(enabled: false),
                gitExecutor: StubGitExecutor()
            )
        )
        let capability = try RootCapability.open(selectedURL: fixture.url)
        let identityKey = try SecretMatchIdentityKey.makeEphemeral()
        let request = ScanCoordinatorRequest(root: capability, identityKey: identityKey)

        let first = Task { try await coordinator.scan(request) }
        for _ in 0..<50 {
            await Task.yield()
        }
        do {
            _ = try await coordinator.scan(request)
            XCTFail("Expected scanAlreadyActive")
        } catch ScanCoordinatorError.scanAlreadyActive {
        }
        _ = try await first.value
    }

    private func runScan(
        on root: URL,
        feasibility: StubGitFeasibility,
        executor: StubGitExecutor = StubGitExecutor(),
        limits: ScanLimits = .defaults
    ) async throws -> ScanCoordinatorResult {
        let coordinator = ScanCoordinator(
            dependencies: ScanCoordinatorDependencies(
                feasibility: feasibility,
                gitExecutor: executor
            )
        )
        let capability = try RootCapability.open(selectedURL: root)
        return try await coordinator.scan(
            ScanCoordinatorRequest(
                root: capability,
                limits: limits,
                identityKey: try SecretMatchIdentityKey.makeEphemeral()
            )
        )
    }

    private func copyMinimalRepoFixture() throws -> TemporaryProjectFixture {
        let source = minimalRepoFixtureURL()
        let fixture = try TemporaryProjectFixture()
        try copyGitEvidenceFixtureContents(from: source, to: fixture.url)
        return fixture
    }

    private func copyGitEvidenceFixtureContents(from source: URL, to destination: URL) throws {
        let contents = try FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for item in contents {
            let name = item.lastPathComponent
            if name == "dot-git" {
                try copyGitEvidenceFixtureDirectory(
                    from: item,
                    to: destination.appendingPathComponent(".git")
                )
            } else {
                try FileManager.default.copyItem(
                    at: item,
                    to: destination.appendingPathComponent(name)
                )
            }
        }
        let hidden = try FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: []
        )
        for item in hidden where item.lastPathComponent.hasPrefix(".") {
            let name = item.lastPathComponent
            if name == ".git",
               !FileManager.default.fileExists(atPath: destination.appendingPathComponent(".git").path) {
                try FileManager.default.copyItem(
                    at: item,
                    to: destination.appendingPathComponent(name)
                )
            }
        }
    }

    private func copyGitEvidenceFixtureDirectory(from source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let contents = try FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        for item in contents {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            if (try item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                try copyGitEvidenceFixtureDirectory(from: item, to: target)
            } else {
                try FileManager.default.copyItem(at: item, to: target)
            }
        }
    }

    private func minimalRepoFixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("script/fixtures/git_evidence/minimal-repo", isDirectory: true)
    }

    private func githubToken() -> String {
        "ghp_" + String(repeating: "a", count: 36)
    }

    private func detector(
        _ detector: DetectorID,
        in snapshot: ScanCoverageSnapshot
    ) -> DetectorCoverageSnapshot {
        guard let coverage = snapshot.detectors.first(where: { $0.detector == detector }) else {
            XCTFail("Missing detector snapshot for \(detector)")
            fatalError("Missing detector snapshot")
        }
        return coverage
    }
}

private struct StubGitFeasibility: GitFeasibilityProviding {
    let enabled: Bool

    func currentSnapshot() -> GitFeasibilitySnapshot {
        guard enabled else { return .unavailable() }
        return GitFeasibilitySnapshot(
            availability: .enabled(
                GitFeasibilityTupleMetadata(
                    osBuildFamily: "test",
                    architecture: "arm64",
                    pearcleanerVersion: "test",
                    runnerVersion: "test",
                    appleGitVersion: "test",
                    harnessVersion: "test",
                    testTimestamp: Date()
                )
            )
        )
    }
}

private final class StubGitExecutor: GitEvidenceExecuting, @unchecked Sendable {
    private let responses: [Result<GitEvidenceExecutionResponse, GitEvidenceExecutionFailure>]
    private var callCount = 0

    init(responses: [Result<GitEvidenceExecutionResponse, GitEvidenceExecutionFailure>] = []) {
        self.responses = responses
    }

    func execute(
        _ request: GitEvidenceExecutionRequest
    ) async -> Result<GitEvidenceExecutionResponse, GitEvidenceExecutionFailure> {
        let index = min(callCount, max(responses.count - 1, 0))
        callCount += 1
        if responses.isEmpty {
            return .success(GitEvidenceExecutionResponse())
        }
        return responses[index]
    }
}

private func verifiedPath(_ rawValue: String) throws -> VerifiedRelativePath {
    let components = try rawValue.split(separator: "/").map {
        try VerifiedPathComponent(bytes: Data($0.utf8))
    }
    return try VerifiedRelativePath(components: components)
}
