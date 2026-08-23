import Foundation
import XCTest
@testable import ProjectScannerCore

final class CoverageLedgerTests: XCTestCase {
    func testAllEnabledDetectorsCompleteProducesCompleteRun() async throws {
        let ledger = makeLedger()

        try await completeAllDetectors(in: ledger)
        let snapshot = try await ledger.finalize()

        XCTAssertEqual(snapshot.terminalState, .complete)
        XCTAssertEqual(snapshot.detectors.map(\.detector), DetectorID.allCases)
        XCTAssertTrue(snapshot.detectors.allSatisfy { $0.terminalState == .complete })
    }

    func testOpenEnabledTransactionPreventsFinalization() async throws {
        let ledger = makeLedger()
        _ = try await ledger.begin(.secret)

        await XCTAssertThrowsCoverageError(.unfinishedDetectors) {
            try await ledger.finalize()
        }
    }

    func testFinishDerivesCompleteFromReconciledFacts() async throws {
        let ledger = makeLedger()
        let transaction = try await ledger.begin(.secret)
        try await ledger.record(.candidate(files: 2, bytes: 30), in: transaction)
        try await ledger.record(.scanned(files: 2, bytes: 30), in: transaction)

        try await ledger.finish(transaction)
        try await completeAllDetectors(except: [.secret], in: ledger)
        let snapshot = try await ledger.finalize()

        XCTAssertEqual(detector(.secret, in: snapshot).terminalState, .complete)
    }

    func testFinishDerivesPartialFromAnySkipOrUnsupportedFact() async throws {
        let ledger = makeLedger()
        let secret = try await ledger.begin(.secret)
        try await ledger.record(.candidate(files: 2, bytes: 20), in: secret)
        try await ledger.record(.scanned(files: 1, bytes: 10), in: secret)
        try await ledger.record(.skipped(reason: .unreadable, files: 1, bytes: 10), in: secret)
        try await ledger.finish(secret)

        let lifecycle = try await ledger.begin(.lifecycle)
        try await ledger.record(.candidate(files: 1, bytes: 8), in: lifecycle)
        try await ledger.record(
            .unsupported(reason: .unsupportedCoordinate, files: 1, bytes: 8),
            in: lifecycle
        )
        try await ledger.record(.installedManifests(.complete, count: 0), in: lifecycle)
        try await ledger.finish(lifecycle)

        let advisory = try await ledger.begin(.advisory)
        try await ledger.record(.candidate(files: 0, bytes: 8), in: advisory)
        try await ledger.record(
            .unsupported(reason: .advisoryCacheMissing, files: 0, bytes: 8),
            in: advisory
        )
        try await ledger.record(.advisory(Self.completeAdvisory), in: advisory)
        try await ledger.finish(advisory)

        try await completeAllDetectors(except: [.secret, .advisory, .lifecycle], in: ledger)
        let snapshot = try await ledger.finalize()

        XCTAssertEqual(detector(.secret, in: snapshot).terminalState, .partial)
        XCTAssertEqual(detector(.advisory, in: snapshot).terminalState, .partial)
        XCTAssertEqual(detector(.lifecycle, in: snapshot).terminalState, .partial)
        XCTAssertEqual(snapshot.terminalState, .partial)
    }

    func testUnresolvedCandidateAccountingRejectsFinish() async throws {
        let ledger = makeLedger()
        let transaction = try await ledger.begin(.secret)
        try await ledger.record(.candidate(files: 2, bytes: 20), in: transaction)
        try await ledger.record(.scanned(files: 1, bytes: 10), in: transaction)

        await XCTAssertThrowsCoverageError(.unresolvedCandidates(.secret)) {
            try await ledger.finish(transaction)
        }
    }

    func testIncompleteTypedDetailRejectsFinish() async throws {
        let ledger = makeLedger()
        let transaction = try await ledger.begin(.nodeLockfile)
        try await ledger.record(.candidate(files: 0, bytes: 0), in: transaction)
        try await ledger.record(.scanned(files: 0, bytes: 0), in: transaction)
        try await ledger.record(.lockfile(format: .npmPackageLock, status: .complete), in: transaction)
        try await ledger.record(.coordinates(status: .complete, count: 0), in: transaction)

        await XCTAssertThrowsCoverageError(.incompleteDetail(.nodeLockfile)) {
            try await ledger.finish(transaction)
        }
        try await ledger.record(.competingLockfiles(.complete(count: 0)), in: transaction)
        try await ledger.record(.competingLockfiles(.absent), in: transaction)
        await XCTAssertThrowsCoverageError(.incompleteDetail(.nodeLockfile)) {
            try await ledger.finish(transaction)
        }
    }

    func testCallerCannotSubmitCompleteOrPartialTerminalState() async throws {
        let ledger = makeLedger()
        let secret = try await ledger.begin(.secret)
        let advisory = try await ledger.begin(.advisory)
        let lifecycle = try await ledger.begin(.lifecycle)

        try await ledger.interrupt(secret, because: .cancelled)
        try await ledger.interrupt(advisory, because: .failed(.advisoryCacheMissing))
        try await ledger.interrupt(lifecycle, because: .unavailable(.unreadable))
        try await completeAllDetectors(except: [.secret, .advisory, .lifecycle], in: ledger)
        let snapshot = try await ledger.finalize()

        XCTAssertEqual(detector(.secret, in: snapshot).terminalState, .cancelled)
        XCTAssertEqual(detector(.advisory, in: snapshot).terminalState, .failed)
        XCTAssertEqual(detector(.lifecycle, in: snapshot).terminalState, .unavailable)
    }

    func testAllKnownDetectorsArePlannedAndCannotBeOmitted() async throws {
        let ledger = makeLedger()

        try await ledger.record(.rootUnavailable)
        let snapshot = try await ledger.finalize()

        XCTAssertEqual(snapshot.detectors.map(\.detector), DetectorID.allCases)
        XCTAssertEqual(Set(snapshot.detectors.map(\.transactionID)).count, DetectorID.allCases.count)
    }

    func testCancellationWinsOverCompletedDetectorWork() async throws {
        let ledger = makeLedger()
        try await completeAllDetectors(in: ledger)

        try await ledger.record(.cancelled)
        let snapshot = try await ledger.finalize()

        XCTAssertEqual(snapshot.terminalState, .cancelled)
        XCTAssertTrue(snapshot.detectors.allSatisfy { $0.terminalState == .complete })
    }

    func testRootAuthorizationFailureProducesUnavailable() async throws {
        let ledger = makeLedger()

        try await ledger.record(.rootUnavailable)
        let snapshot = try await ledger.finalize()

        XCTAssertEqual(snapshot.terminalState, .unavailable)
        XCTAssertTrue(snapshot.detectors.allSatisfy { $0.terminalState == .unavailable })
    }

    func testDetectorTransactionFinishesOrInterruptsExactlyOnce() async throws {
        let ledger = makeLedger()
        let secret = try await completeDetector(.secret, in: ledger)
        let advisory = try await ledger.begin(.advisory)
        try await ledger.interrupt(advisory, because: .unavailable(.advisoryCacheMissing))

        await XCTAssertThrowsCoverageError(.transactionNotOpen(secret)) {
            try await ledger.finish(secret)
        }
        await XCTAssertThrowsCoverageError(.transactionNotOpen(advisory)) {
            try await ledger.interrupt(advisory, because: .cancelled)
        }
    }

    func testClosedTransactionRejectsFurtherCounters() async throws {
        let ledger = makeLedger()
        let transaction = try await completeDetector(.secret, in: ledger)

        await XCTAssertThrowsCoverageError(.transactionNotOpen(transaction)) {
            try await ledger.record(.candidate(files: 1, bytes: 1), in: transaction)
        }
    }

    func testConcurrentCounterUpdatesLoseNoEvents() async throws {
        let ledger = makeLedger()
        let transaction = try await ledger.begin(.secret)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    try await ledger.record(.candidate(files: 1, bytes: 10), in: transaction)
                }
            }
            try await group.waitForAll()
        }
        try await ledger.record(.scanned(files: 100, bytes: 1_000), in: transaction)
        try await ledger.finish(transaction)
        try await completeAllDetectors(except: [.secret], in: ledger)
        let snapshot = try await ledger.finalize()
        let coverage = detector(.secret, in: snapshot)

        XCTAssertEqual(coverage.candidateFiles, 100)
        XCTAssertEqual(coverage.candidateBytes, 1_000)
    }

    func testReasonAndByteCountsAreCopiedIntoImmutableSnapshots() async throws {
        let ledger = makeLedger()
        let transaction = try await ledger.begin(.secret)
        try await ledger.record(.candidate(files: 3, bytes: 60), in: transaction)
        try await ledger.record(.scanned(files: 1, bytes: 20), in: transaction)
        try await ledger.record(.skipped(reason: .unreadable, files: 2, bytes: 40), in: transaction)
        try await ledger.finish(transaction)
        try await completeAllDetectors(except: [.secret], in: ledger)
        let snapshot = try await ledger.finalize()
        let coverage = detector(.secret, in: snapshot)

        XCTAssertEqual(coverage.candidateBytes, 60)
        XCTAssertEqual(coverage.scannedBytes, 20)
        XCTAssertEqual(coverage.skippedBytes, 40)
        XCTAssertEqual(coverage.reasonCounts, [.unreadable: 2])
    }

    func testDetectorLimitAffectsOnlyItsDetector() async throws {
        let limits = try ScanLimitOverrides(dependencyNodesPerSession: 1).applying(to: .defaults)
        let ledger = makeLedger(limits: limits)
        let transaction = try await ledger.begin(.nodeLockfile)
        try await ledger.record(.candidate(files: 0, bytes: 0), in: transaction)
        try await ledger.record(.scanned(files: 0, bytes: 0), in: transaction)
        try await ledger.record(.lockfile(format: .npmPackageLock, status: .complete), in: transaction)

        await XCTAssertThrowsCoverageError(.detailLimitExceeded(.nodeLockfile)) {
            try await ledger.record(.coordinates(status: .complete, count: 2), in: transaction)
        }
        try await ledger.record(
            .coordinates(status: .partial(.entryBudget), count: 1),
            in: transaction
        )
        try await ledger.record(.competingLockfiles(.complete(count: 0)), in: transaction)
        try await ledger.finish(transaction)
        try await completeAllDetectors(except: [.nodeLockfile], in: ledger)
        let snapshot = try await ledger.finalize()

        XCTAssertEqual(detector(.nodeLockfile, in: snapshot).terminalState, .partial)
        XCTAssertTrue(
            snapshot.detectors
                .filter { $0.detector != .nodeLockfile }
                .allSatisfy { $0.terminalState == .complete }
        )
    }

    func testGlobalLimitMakesTheWholeRunPartial() async throws {
        let ledger = makeLedger()
        _ = try await completeDetector(.secret, in: ledger)

        try await ledger.record(.globalLimit(.globalByteBudget))
        let snapshot = try await ledger.finalize()

        XCTAssertEqual(snapshot.terminalState, .partial)
        XCTAssertEqual(detector(.secret, in: snapshot).terminalState, .complete)
        XCTAssertTrue(
            snapshot.detectors
                .filter { $0.detector != .secret }
                .allSatisfy { $0.terminalState == .partial }
        )
    }

    func testRecordedLimitCannotBeClearedOrFinalizedAsNormal() async throws {
        let ledger = makeLedger()
        let transaction = try await ledger.begin(.secret)
        try await ledger.record(.candidate(files: 1, bytes: 10), in: transaction)
        try await ledger.record(
            .skipped(reason: .ordinaryFileTooLarge, files: 1, bytes: 10),
            in: transaction
        )
        try await ledger.finish(transaction)
        try await completeAllDetectors(except: [.secret], in: ledger)

        let snapshot = try await ledger.finalize()

        XCTAssertEqual(detector(.secret, in: snapshot).terminalState, .partial)
        XCTAssertEqual(snapshot.terminalState, .partial)
    }

    func testCounterOverflowFailsTheTransaction() async throws {
        let ledger = makeLedger()
        let transaction = try await ledger.begin(.secret)
        try await ledger.record(.candidate(files: .max, bytes: 0), in: transaction)

        await XCTAssertThrowsCoverageError(.counterOverflow(.secret)) {
            try await ledger.record(.candidate(files: 1, bytes: 0), in: transaction)
        }
        try await completeAllDetectors(except: [.secret], in: ledger)
        let snapshot = try await ledger.finalize()

        XCTAssertEqual(detector(.secret, in: snapshot).terminalState, .failed)
    }

    func testOverflowingMultiFieldDeltaAppliesNoPartialCounterChange() async throws {
        let ledger = makeLedger()
        let transaction = try await ledger.begin(.secret)
        try await ledger.record(.candidate(files: 4, bytes: .max), in: transaction)

        await XCTAssertThrowsCoverageError(.counterOverflow(.secret)) {
            try await ledger.record(.candidate(files: 1, bytes: 1), in: transaction)
        }
        try await completeAllDetectors(except: [.secret], in: ledger)
        let snapshot = try await ledger.finalize()
        let coverage = detector(.secret, in: snapshot)

        XCTAssertEqual(coverage.candidateFiles, 4)
        XCTAssertEqual(coverage.candidateBytes, .max)
        XCTAssertEqual(coverage.terminalState, .failed)
    }

    func testFindingCoverageTransactionResolvesToExactlyOneSnapshot() async throws {
        let ledger = makeLedger()
        let transaction = try await completeDetector(.secret, in: ledger)
        try await completeAllDetectors(except: [.secret], in: ledger)
        let snapshot = try await ledger.finalize()
        let header = SessionFindingHeader(
            kind: .probableSecret,
            ruleID: try XCTUnwrap(RuleID(rawValue: "secret.example")),
            ruleVersion: 1,
            sourceView: .workingTree,
            detectorID: .secret,
            coverageTransactionID: transaction,
            assessment: .confidence(.high),
            provenance: .secretRule,
            suppressionEligibility: .eligible,
            suppressionState: .notSuppressed
        )

        let matches = snapshot.detectors.filter {
            $0.transactionID == header.coverageTransactionID && $0.detector == header.detectorID
        }
        XCTAssertEqual(matches.count, 1)
    }

    func testFinalizedLedgerRejectsEveryFurtherMutation() async throws {
        let ledger = makeLedger()
        let transaction = try await completeDetector(.secret, in: ledger)
        try await completeAllDetectors(except: [.secret], in: ledger)
        _ = try await ledger.finalize()

        await XCTAssertThrowsCoverageError(.alreadyFinalized) { _ = try await ledger.begin(.secret) }
        await XCTAssertThrowsCoverageError(.alreadyFinalized) {
            try await ledger.record(.candidate(files: 1, bytes: 1), in: transaction)
        }
        await XCTAssertThrowsCoverageError(.alreadyFinalized) {
            try await ledger.record(.advisory(Self.completeAdvisory), in: transaction)
        }
        await XCTAssertThrowsCoverageError(.alreadyFinalized) { try await ledger.finish(transaction) }
        await XCTAssertThrowsCoverageError(.alreadyFinalized) {
            try await ledger.interrupt(transaction, because: .cancelled)
        }
        await XCTAssertThrowsCoverageError(.alreadyFinalized) { try await ledger.record(.cancelled) }
        await XCTAssertThrowsCoverageError(.alreadyFinalized) { _ = try await ledger.finalize() }
    }

    func testLockfileCoverageCanCompleteWhileAdvisoryCoverageIsUnavailable() async throws {
        let ledger = makeLedger()
        _ = try await completeDetector(.nodeLockfile, in: ledger)
        let advisory = try await ledger.begin(.advisory)
        try await ledger.interrupt(advisory, because: .unavailable(.advisoryCacheMissing))
        try await completeAllDetectors(except: [.nodeLockfile, .advisory], in: ledger)

        let snapshot = try await ledger.finalize()

        XCTAssertEqual(detector(.nodeLockfile, in: snapshot).terminalState, .complete)
        XCTAssertEqual(detector(.advisory, in: snapshot).terminalState, .unavailable)
        XCTAssertEqual(snapshot.terminalState, .partial)
    }

    func testGitStatusIsRecordedPerSessionRepositoryIdentity() async throws {
        let ledger = makeLedger()
        let transaction = try await ledger.begin(.gitEvidence)
        let firstRepository = RepositoryCoverageID()
        let secondRepository = RepositoryCoverageID()
        try await ledger.record(.candidate(files: 0, bytes: 0), in: transaction)
        try await ledger.record(.scanned(files: 0, bytes: 0), in: transaction)
        try await ledger.record(
            .gitRepository(firstRepository, preflight: .complete, operation: .complete),
            in: transaction
        )
        try await ledger.record(
            .gitRepository(secondRepository, preflight: .complete, operation: .complete),
            in: transaction
        )
        try await ledger.finish(transaction)
        try await completeAllDetectors(except: [.gitEvidence], in: ledger)

        let snapshot = try await ledger.finalize()
        let details = detector(.gitEvidence, in: snapshot).details

        XCTAssertNotEqual(firstRepository, secondRepository)
        XCTAssertTrue(details.contains(.gitRepository(firstRepository, preflight: .complete, operation: .complete)))
        XCTAssertTrue(details.contains(.gitRepository(secondRepository, preflight: .complete, operation: .complete)))
        XCTAssertFalse(isCodable(RepositoryCoverageID.self))
    }

    func testLockfileFormatCoordinateAndInstalledManifestDetailsAreImmutable() async throws {
        let ledger = makeLedger()
        _ = try await completeDetector(.nodeLockfile, in: ledger)
        _ = try await completeDetector(.lifecycle, in: ledger)
        try await completeAllDetectors(except: [.nodeLockfile, .lifecycle], in: ledger)

        let snapshot = try await ledger.finalize()

        XCTAssertEqual(
            detector(.nodeLockfile, in: snapshot).details,
            [
                .lockfile(format: .npmPackageLock, status: .complete),
                .coordinates(status: .complete, count: 0),
                .competingLockfiles(.complete(count: 0)),
            ]
        )
        XCTAssertEqual(
            detector(.lifecycle, in: snapshot).details,
            [.installedManifests(.complete, count: 0)]
        )
        XCTAssertFalse(isCodable(DetectorCoverageSnapshot.self))
        XCTAssertFalse(isCodable(ScanCoverageSnapshot.self))
    }

    func testAdvisoryGenerationProvenanceAgeAndValidationRemainSeparate() async throws {
        let ledger = makeLedger()
        let transaction = try await ledger.begin(.advisory)
        let generation = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let refresh = Date(timeIntervalSince1970: 1_700_000_000)
        let activation = Date(timeIntervalSince1970: 1_700_000_300)
        let metadata = AdvisoryCoverageMetadata(
            generation: generation,
            source: .osv,
            ageSeconds: 86_400,
            lastSuccessfulRefresh: refresh,
            activatedAt: activation,
            validation: .complete
        )
        try await ledger.record(.candidate(files: 0, bytes: 0), in: transaction)
        try await ledger.record(.scanned(files: 0, bytes: 0), in: transaction)
        try await ledger.record(.advisory(metadata), in: transaction)
        try await ledger.finish(transaction)
        try await completeAllDetectors(except: [.advisory], in: ledger)

        let snapshot = try await ledger.finalize()

        XCTAssertEqual(detector(.advisory, in: snapshot).details, [.advisory(metadata)])
        XCTAssertEqual(metadata.generation, generation)
        XCTAssertEqual(metadata.source, .osv)
        XCTAssertEqual(metadata.ageSeconds, 86_400)
        XCTAssertEqual(metadata.lastSuccessfulRefresh, refresh)
        XCTAssertEqual(metadata.activatedAt, activation)
        XCTAssertEqual(metadata.validation, .complete)
    }

    private static let completeAdvisory = AdvisoryCoverageMetadata(
        generation: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
        source: .osv,
        ageSeconds: 0,
        lastSuccessfulRefresh: Date(timeIntervalSince1970: 1_700_000_000),
        activatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        validation: .complete
    )

    private func makeLedger(limits: ScanLimits = .defaults) -> CoverageLedger {
        CoverageLedger(
            sessionID: ScanSessionID(rawValue: UUID()),
            limits: limits
        )
    }

    @discardableResult
    private func completeDetector(
        _ detector: DetectorID,
        in ledger: CoverageLedger
    ) async throws -> CoverageTransactionID {
        let transaction = try await ledger.begin(detector)
        try await ledger.record(.candidate(files: 0, bytes: 0), in: transaction)
        try await ledger.record(.scanned(files: 0, bytes: 0), in: transaction)

        switch detector {
        case .secret:
            break
        case .nodeLockfile:
            try await ledger.record(
                .lockfile(format: .npmPackageLock, status: .complete),
                in: transaction
            )
            try await ledger.record(.coordinates(status: .complete, count: 0), in: transaction)
            try await ledger.record(.competingLockfiles(.complete(count: 0)), in: transaction)
        case .advisory:
            try await ledger.record(.advisory(Self.completeAdvisory), in: transaction)
        case .lifecycle:
            try await ledger.record(.installedManifests(.complete, count: 0), in: transaction)
        case .gitEvidence:
            try await ledger.record(
                .gitRepository(RepositoryCoverageID(), preflight: .complete, operation: .complete),
                in: transaction
            )
        }

        try await ledger.finish(transaction)
        return transaction
    }

    private func completeAllDetectors(
        except excluded: Set<DetectorID> = [],
        in ledger: CoverageLedger
    ) async throws {
        for detector in DetectorID.allCases where !excluded.contains(detector) {
            try await completeDetector(detector, in: ledger)
        }
    }

    private func detector(
        _ detector: DetectorID,
        in snapshot: ScanCoverageSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> DetectorCoverageSnapshot {
        guard let coverage = snapshot.detectors.first(where: { $0.detector == detector }) else {
            XCTFail("Missing detector snapshot for \(detector)", file: file, line: line)
            fatalError("Missing detector snapshot")
        }
        return coverage
    }

    private func isCodable<T>(_ type: T.Type) -> Bool {
        type is any Codable.Type
    }

    private func XCTAssertThrowsCoverageError<T>(
        _ expected: CoverageLedgerError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> T
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? CoverageLedgerError, expected, file: file, line: line)
        }
    }
}
