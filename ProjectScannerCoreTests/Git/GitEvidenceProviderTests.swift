import Foundation
import XCTest
@testable import ProjectScannerCore

final class GitEvidenceProviderTests: XCTestCase {
    func testUnavailableWhenFeasibilityDisabled() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        try initializeGitRepository(in: fixture.url)

        let provider = GitEvidenceProvider(
            feasibility: StubGitFeasibility(enabled: false),
            executor: StubGitExecutor()
        )
        let outcome = try await collect(
            provider: provider,
            fixtureURL: fixture.url,
            request: GitEvidenceCollectionRequest(workingTreePaths: [])
        )

        guard case let .unavailable(reason) = outcome else {
            return XCTFail("Expected unavailable, got \(outcome)")
        }
        XCTAssertEqual(reason, .gitPreflightRejected)
    }

    func testRevalidationDiscardsOutputOnIdentityDrift() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        try initializeGitRepository(in: fixture.url)

        let provider = GitEvidenceProvider(
            feasibility: StubGitFeasibility(enabled: true),
            executor: MutatingIndexGitExecutor(indexURL: fixture.url.appendingPathComponent(".git/index"))
        )
        let outcome = try await collect(
            provider: provider,
            fixtureURL: fixture.url,
            request: GitEvidenceCollectionRequest(workingTreePaths: [])
        )

        guard case let .unavailable(reason) = outcome else {
            return XCTFail("Expected unavailable after identity drift, got \(outcome)")
        }
        XCTAssertEqual(reason, .identityChanged)
    }

    func testDescriptorBudgetMarksPartialCoverage() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        try initializeGitRepository(in: fixture.url)

        let executor = StubGitExecutor(
            responses: [
                .success(GitEvidenceExecutionResponse(cachedPaths: ["tracked.txt"])),
                .failure(.descriptorRejected),
            ]
        )
        let provider = GitEvidenceProvider(
            feasibility: StubGitFeasibility(enabled: true),
            executor: executor
        )
        let outcome = try await collect(
            provider: provider,
            fixtureURL: fixture.url,
            request: GitEvidenceCollectionRequest(workingTreePaths: [])
        )

        guard case let .partial(_, reason) = outcome else {
            return XCTFail("Expected partial outcome, got \(outcome)")
        }
        XCTAssertEqual(reason, .gitDescriptorBudget)
    }

    func testTimeoutFailureSurfacesGitTimeoutReason() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        try initializeGitRepository(in: fixture.url)

        let provider = GitEvidenceProvider(
            feasibility: StubGitFeasibility(enabled: true),
            executor: StubGitExecutor(responses: [.failure(.timedOut)])
        )
        let outcome = try await collect(
            provider: provider,
            fixtureURL: fixture.url,
            request: GitEvidenceCollectionRequest(workingTreePaths: [])
        )

        guard case let .unavailable(reason) = outcome else {
            return XCTFail("Expected unavailable, got \(outcome)")
        }
        XCTAssertEqual(reason, .gitTimeout)
    }

    private func collect(
        provider: GitEvidenceProvider,
        fixtureURL: URL,
        limits: ScanLimits = .defaults,
        request: GitEvidenceCollectionRequest
    ) async throws -> GitEvidenceCollectionOutcome {
        let capability = try RootCapability.open(selectedURL: fixtureURL)
        let broker = try capability.makeFileBroker(limits: limits)
        let ledger = CoverageLedger(sessionID: ScanSessionID(rawValue: UUID()))
        let transaction = try await ledger.begin(.gitEvidence)
        try await ledger.record(.candidate(files: 1, bytes: 1), in: transaction)
        try await ledger.record(.scanned(files: 1, bytes: 1), in: transaction)
        return await provider.collect(
            broker: broker,
            ledger: ledger,
            transaction: transaction,
            request: request
        )
    }

    private func initializeGitRepository(in root: URL) throws {
        let process = Process()
        process.currentDirectoryURL = root
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init", "-q"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        _ = try Data("tracked\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        try runGit(["add", "tracked.txt"], in: root)
        try runGit(
            ["-c", "user.email=test@example.com", "-c", "user.name=Test", "commit", "-qm", "init"],
            in: root
        )
    }

    private func runGit(_ arguments: [String], in root: URL) throws {
        let process = Process()
        process.currentDirectoryURL = root
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
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

private final class MutatingIndexGitExecutor: GitEvidenceExecuting, @unchecked Sendable {
    private let indexURL: URL

    init(indexURL: URL) {
        self.indexURL = indexURL
    }

    func execute(
        _ request: GitEvidenceExecutionRequest
    ) async -> Result<GitEvidenceExecutionResponse, GitEvidenceExecutionFailure> {
        if let handle = try? FileHandle(forWritingTo: indexURL) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data([0x00]))
            try? handle.close()
        }
        return .success(GitEvidenceExecutionResponse(cachedPaths: ["tracked.txt"]))
    }
}
