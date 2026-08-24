import Darwin
import Foundation
import XCTest
@testable import ProjectScannerCore

final class ProjectStateStoreTests: XCTestCase {
    func testRegistersMinimalProjectWithBookmarkAsOnlyPathBearingField() async throws {
        let fixture = try await StateStoreFixture.make(); defer { fixture.remove() }
        let registration = try await fixture.register(label: "User label")
        XCTAssertEqual(registration.projectID.rawValue, fixture.projectUUID)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.stateFile)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["schemaVersion","projectID","label","bookmark","keyGeneration","scannerSchemaVersion","advisoryCacheSchemaVersion","lastCompleteSummary","lastAttempt","limitOverrides","watchEnabled","suppressions"]))
        XCTAssertEqual(object["label"] as? String, "User label")
    }

    func testCompleteRunAtomicallyUpdatesCompleteSummaryAndAttempt() async throws {
        let fixture = try await StateStoreFixture.make(); defer { fixture.remove() }
        let registration = try await fixture.register()
        let metadata = try testAttemptMetadata()
        let commit = try await fixture.store.recordAttempt(projectID: registration.projectID, coverage: completeCoverage(), finishedAt: Date(timeIntervalSince1970: 1), metadata: metadata, lease: fixture.lease)
        XCTAssertEqual(commit, .committed)
        let loadedValue = try await fixture.store.loadSummary(projectID: registration.projectID)
        let loaded = try XCTUnwrap(loadedValue)
        XCTAssertEqual(loaded.lastCompleteSummary, loaded.lastAttempt)
        XCTAssertEqual(loaded.lastCompleteSummary?.terminalState, .complete)
    }

    func testPartialCancelledFailedAndUnavailableUpdateOnlyLastAttempt() async throws {
        for state in [ScanTerminalState.partial, .cancelled, .failed, .unavailable] {
            let fixture = try await StateStoreFixture.make(projectUUID: UUID()); defer { fixture.remove() }
            let registration = try await fixture.register()
            let metadata = try testAttemptMetadata()
            _ = try await fixture.store.recordAttempt(projectID: registration.projectID, coverage: completeCoverage(), finishedAt: Date(timeIntervalSince1970: 1), metadata: metadata, lease: fixture.lease)
            let complete = try await fixture.store.loadSummary(projectID: registration.projectID)?.lastCompleteSummary
            _ = try await fixture.store.recordAttempt(projectID: registration.projectID, coverage: nonCompleteCoverage(state), finishedAt: Date(timeIntervalSince1970: 2), metadata: try AttemptSummaryMetadata(advisoryCacheSchemaVersion: nil, advisory: nil), lease: fixture.lease)
            let loadedValue = try await fixture.store.loadSummary(projectID: registration.projectID)
            let loaded = try XCTUnwrap(loadedValue)
            XCTAssertEqual(loaded.lastCompleteSummary, complete)
            XCTAssertEqual(loaded.lastAttempt?.terminalState, state)
        }
    }

    func testPartialAttemptCannotCarryAnUnrelatedCompleteSummary() async throws {
        let fixture = try await StateStoreFixture.make(); defer { fixture.remove() }
        let registration = try await fixture.register()
        _ = try await fixture.store.recordAttempt(projectID: registration.projectID, coverage: nonCompleteCoverage(.partial), finishedAt: Date(timeIntervalSince1970: 3), metadata: try AttemptSummaryMetadata(advisoryCacheSchemaVersion: nil, advisory: nil), lease: fixture.lease)
        let loadedValue = try await fixture.store.loadSummary(projectID: registration.projectID)
        let loaded = try XCTUnwrap(loadedValue)
        XCTAssertNil(loaded.lastCompleteSummary)
        XCTAssertEqual(loaded.lastAttempt?.terminalState, .partial)
        let before = try Data(contentsOf: fixture.stateFile)
        let contradictory = AdvisoryCoverageMetadata(generation: UUID(), source: .osv, ageSeconds: 1, lastSuccessfulRefresh: Date(timeIntervalSince1970: 1), activatedAt: nil, validation: .complete)
        await XCTAssertThrowsProjectState(.invalidInput) {
            _ = try await fixture.store.recordAttempt(projectID: registration.projectID, coverage: completeCoverage(), finishedAt: Date(timeIntervalSince1970: 3), metadata: try AttemptSummaryMetadata(advisoryCacheSchemaVersion: 1, advisory: contradictory), lease: fixture.lease)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.stateFile), before)
        for details in [[], [testAdvisoryMetadata(), testAdvisoryMetadata()]] {
            await XCTAssertThrowsProjectState(.invalidInput) {
                _ = try await fixture.store.recordAttempt(projectID: registration.projectID, coverage: completeCoverageWithAdvisoryDetails(details), finishedAt: Date(timeIntervalSince1970: 3), metadata: try testAttemptMetadata(), lease: fixture.lease)
            }
            XCTAssertEqual(try Data(contentsOf: fixture.stateFile), before)
        }
        let incompleteAdvisories = [
            AdvisoryCoverageMetadata(
                generation: testAdvisoryMetadata().generation, source: .osv,
                ageSeconds: 1, lastSuccessfulRefresh: nil, activatedAt: nil,
                validation: .partial(.advisoryCacheMissing)
            ),
            AdvisoryCoverageMetadata(
                generation: testAdvisoryMetadata().generation, source: .osv,
                ageSeconds: 1, lastSuccessfulRefresh: nil, activatedAt: nil,
                validation: .unavailable(.advisoryCacheMissing)
            ),
        ]
        let absentMetadata = try AttemptSummaryMetadata(
            advisoryCacheSchemaVersion: nil, advisory: nil
        )
        await XCTAssertThrowsProjectState(.invalidInput) {
            _ = try await fixture.store.recordAttempt(
                projectID: registration.projectID,
                coverage: completeCoverageWithAdvisoryDetails([]),
                finishedAt: Date(timeIntervalSince1970: 3),
                metadata: absentMetadata, lease: fixture.lease
            )
        }
        for advisory in incompleteAdvisories {
            let metadata = try AttemptSummaryMetadata(
                advisoryCacheSchemaVersion: 1, advisory: advisory
            )
            await XCTAssertThrowsProjectState(.invalidInput) {
                _ = try await fixture.store.recordAttempt(
                    projectID: registration.projectID,
                    coverage: completeCoverage(advisory: advisory),
                    finishedAt: Date(timeIntervalSince1970: 3),
                    metadata: metadata, lease: fixture.lease
                )
            }
        }
        XCTAssertEqual(try Data(contentsOf: fixture.stateFile), before)
    }

    func testPartialAttemptNeverReappearsAsLastCompleteAfterReload() async throws {
        let fixture = try await StateStoreFixture.make(); defer { fixture.remove() }
        let registration = try await fixture.register()
        _ = try await fixture.store.recordAttempt(projectID: registration.projectID, coverage: nonCompleteCoverage(.cancelled), finishedAt: Date(timeIntervalSince1970: 4), metadata: try AttemptSummaryMetadata(advisoryCacheSchemaVersion: nil, advisory: nil), lease: fixture.lease)
        let reloaded = try await ProjectStateStore(parent: fixture.parent, keyCoordinator: fixture.coordinator, uuid: ScriptedUUID([UUID()]), operations: SystemStateFileSystemOperations(), backupOperations: SystemBackupExclusionOperations())
        let snapshot = try await reloaded.loadSummary(projectID: registration.projectID)
        XCTAssertNil(snapshot?.lastCompleteSummary)
        XCTAssertEqual(snapshot?.lastAttempt?.terminalState, .cancelled)
    }

    func testGenerationMismatchBeforeCommitLeavesPriorBytesUnchanged() async throws {
        let fixture = try await StateStoreFixture.make(); defer { fixture.remove() }
        let registration = try await fixture.register(); let original = try Data(contentsOf: fixture.stateFile)
        let wrong = try ProjectKeyMaterial(generation: UUID(), keyBytes: Data(repeating: 2, count: 32))
        await XCTAssertThrowsProjectState(.keyResetRequired) {
            _ = try await fixture.store.addSuppression(projectID: registration.projectID, record: try suppression(1), lease: .persistent(wrong))
        }
        XCTAssertEqual(try Data(contentsOf: fixture.stateFile), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.stateDirectory.path).contains(where: { $0.hasSuffix(".tmp") }))
    }

    func testTemporaryKeychainFailureLeavesPriorBytesUnchanged() async throws {
        let fixture = try await StateStoreFixture.make(); defer { fixture.remove() }
        let registration = try await fixture.register(); let original = try Data(contentsOf: fixture.stateFile)
        let unavailableCoordinator = ProjectKeyCoordinator(store: ScriptedKeyStore(reads: [.fixed(.unavailable(.interactionNotAllowed))]))
        let alternate = try await ProjectStateStore(parent: fixture.parent, keyCoordinator: unavailableCoordinator, uuid: ScriptedUUID([UUID()]), operations: SystemStateFileSystemOperations(), backupOperations: SystemBackupExclusionOperations())
        await XCTAssertThrowsProjectState(.ephemeralRun) { _ = try await alternate.addSuppression(projectID: registration.projectID, record: try suppression(2), lease: fixture.lease) }
        XCTAssertEqual(try Data(contentsOf: fixture.stateFile), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.stateDirectory.path).contains(where: { $0.hasSuffix(".tmp") }))
    }

    func testTwoIndependentStoresDoNotLoseConcurrentSuppressionsOrSummaryUpdates() async throws {
        let fixture = try await StateStoreFixture.make(); defer { fixture.remove() }
        let registration = try await fixture.register()
        let second = try await ProjectStateStore(parent: fixture.parent, keyCoordinator: fixture.coordinator, uuid: ScriptedUUID([UUID(), UUID()]), operations: SystemStateFileSystemOperations(), backupOperations: SystemBackupExclusionOperations())
        let first = fixture.store
        let lease = fixture.lease
        let projectID = registration.projectID
        let suppressionRecord = try suppression(3)
        let coverage = completeCoverage()
        let metadata = try testAttemptMetadata()
        async let suppressionCommit = first.addSuppression(projectID: projectID, record: suppressionRecord, lease: lease)
        async let summaryCommit = second.recordAttempt(projectID: projectID, coverage: coverage, finishedAt: Date(timeIntervalSince1970: 5), metadata: metadata, lease: lease)
        _ = try await (suppressionCommit, summaryCommit)
        let access = try await first.loadForScan(projectID: projectID)
        guard case .persistent(let snapshot, let records, _) = access else { return XCTFail("Expected persistent") }
        XCTAssertEqual(records.count, 1); XCTAssertNotNil(snapshot.lastCompleteSummary)
    }

    func testScriptedLockContentionIsBoundedAndCancellationAware() async throws {
        let operations = ScriptedStateFileSystemOperations(repeatedBusySite: .acquireTransactionLock, busyStartingOccurrence: 2)
        let fixture = try await StateStoreFixture.make(operations: operations); defer { fixture.remove() }
        let busyStart = ContinuousClock.now
        await XCTAssertThrowsProjectState(.transactionBusy) { _ = try await fixture.register() }
        let busyDuration = busyStart.duration(to: .now)
        XCTAssertGreaterThanOrEqual(busyDuration, .seconds(4)); XCTAssertLessThan(busyDuration, .seconds(6))

        let cancellationOperations = ScriptedStateFileSystemOperations(repeatedBusySite: .acquireTransactionLock, busyStartingOccurrence: 2)
        let cancellationFixture = try await StateStoreFixture.make(operations: cancellationOperations, projectUUID: UUID()); defer { cancellationFixture.remove() }
        let cancelStart = ContinuousClock.now
        let store = cancellationFixture.store; let bookmark = cancellationFixture.bookmark; let lease = cancellationFixture.lease
        let task = Task { try await store.register(label: nil, bookmark: bookmark, limitOverrides: .init(), lease: lease) }
        XCTAssertTrue(cancellationOperations.waitUntil(.acquireTransactionLock, count: 2, timeout: 1), "Transaction never reached real contention")
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled transaction ran") }
        catch { XCTAssertTrue(error is CancellationError || error as? ProjectStateError == .cancelled) }
        XCTAssertLessThan(cancelStart.duration(to: .now), .milliseconds(500))
        XCTAssertFalse(cancellationOperations.snapshot().contains(.renameStagingFile))

        let replacementOperations = ScriptedStateFileSystemOperations(
            exerciseLockReplacementRetryRace: true
        )
        let replacementFixture = try await StateStoreFixture.make(
            operations: replacementOperations, projectUUID: UUID()
        )
        defer { replacementFixture.remove() }
        await XCTAssertThrowsProjectState(.stateUnavailable) {
            _ = try await replacementFixture.register()
        }
        XCTAssertEqual(
            replacementOperations.snapshot().filter { $0 == .acquireTransactionLock }.count,
            2,
            "A retry must revalidate the entry before a third flock attempt"
        )
        XCTAssertFalse(replacementOperations.snapshot().contains(.renameStagingFile))
    }

    func testEachStateSyscallFailureIsInjectedAtTheNamedSite() async throws {
        for site in bootstrapStateSites {
            let operations = ScriptedStateFileSystemOperations(failingSite: site, failure: .failBefore(EIO))
            let root = try StateMatrixRoot(kind: bootstrapExistingLockSites.contains(site) ? .existingLock : .empty)
            defer { root.remove() }
            do {
                _ = try await root.makeStore(operations: operations)
                XCTFail("Bootstrap site \(site) was not exercised")
            } catch {
                assertInjectedFailureOrdering(site, events: operations.snapshot())
                XCTAssertNotNil(error as? ProjectStateError, "Public error was not closed")
                XCTAssertEqual(try Data(contentsOf: root.outside), root.outsideSnapshot)
            }
        }

        for site in stagingRecoverySites {
            let root = try StateMatrixRoot(kind: .staging); defer { root.remove() }
            let before = try FileManager.default.contentsOfDirectory(atPath: root.state.path).sorted()
            let operations = ScriptedStateFileSystemOperations(failingSite: site, failure: .failBefore(EIO))
            do { _ = try await root.makeStore(operations: operations); XCTFail("Recovery site \(site) ignored") }
            catch {
                assertInjectedFailureOrdering(site, events: operations.snapshot())
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.state.path).sorted(), before, "Failure partially cleaned staging")
                XCTAssertEqual(try Data(contentsOf: root.outside), root.outsideSnapshot)
            }
        }

        let baseline = try await StateStoreFixture.make(projectUUID: UUID()); defer { baseline.remove() }
        let registration = try await baseline.register(label: "prior")
        let priorBytes = try Data(contentsOf: baseline.stateFile)
        for site in readStateSites {
            let operations = ScriptedStateFileSystemOperations(failingSite: site, failure: .failBefore(EIO))
            let reader = try await ProjectStateStore(parent: baseline.parent, keyCoordinator: baseline.coordinator, uuid: ScriptedUUID([UUID()]), operations: operations, backupOperations: SystemBackupExclusionOperations())
            do { _ = try await reader.loadSummary(projectID: registration.projectID); XCTFail("Read site \(site) ignored") }
            catch {
                assertInjectedFailureOrdering(site, events: operations.snapshot())
                XCTAssertEqual(try Data(contentsOf: baseline.stateFile), priorBytes)
                XCTAssertEqual(try Data(contentsOf: baseline.outsideCanary), baseline.outsideSnapshot)
            }
        }

        for site in registrationWriteSites where site != .inspectRegistrationDestination && site != .renameStagingFile && site != .syncScannerAfterRename {
            let operations = ScriptedStateFileSystemOperations(failingSite: site, failure: .failBefore(EIO))
            let writer = try await ProjectStateStore(parent: baseline.parent, keyCoordinator: baseline.coordinator, uuid: ScriptedUUID([UUID(), UUID()]), operations: operations, backupOperations: SystemBackupExclusionOperations())
            do { _ = try await writer.recordAttempt(projectID: registration.projectID, coverage: nonCompleteCoverage(.partial), finishedAt: Date(timeIntervalSince1970: 4), metadata: try AttemptSummaryMetadata(advisoryCacheSchemaVersion: nil, advisory: nil), lease: baseline.lease); XCTFail("Write site \(site) ignored") }
            catch {
                assertInjectedFailureOrdering(site, events: operations.snapshot())
                XCTAssertEqual(try Data(contentsOf: baseline.stateFile), priorBytes)
                XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: baseline.stateDirectory.path).contains(where: { $0.hasSuffix(".tmp") }))
                XCTAssertEqual(try Data(contentsOf: baseline.outsideCanary), baseline.outsideSnapshot)
            }
        }

        let collisionInspection = ScriptedStateFileSystemOperations(failingSite: .inspectRegistrationDestination, failure: .failBefore(EIO))
        let registrationWriter = try await ProjectStateStore(parent: baseline.parent, keyCoordinator: baseline.coordinator, uuid: ScriptedUUID([UUID(), UUID()]), operations: collisionInspection, backupOperations: SystemBackupExclusionOperations())
        do { _ = try await registrationWriter.register(label: nil, bookmark: baseline.bookmark, limitOverrides: .init(), lease: baseline.lease); XCTFail("Registration destination inspection was skipped") }
        catch {
            assertInjectedFailureOrdering(.inspectRegistrationDestination, events: collisionInspection.snapshot())
            XCTAssertFalse(collisionInspection.snapshot().contains(.createStagingFile))
            XCTAssertEqual(try Data(contentsOf: baseline.stateFile), priorBytes)
            XCTAssertEqual(try Data(contentsOf: baseline.outsideCanary), baseline.outsideSnapshot)
        }

        let renameBefore = ScriptedStateFileSystemOperations(failingSite: .renameStagingFile, failure: .failBefore(EIO))
        let precommitWriter = try await ProjectStateStore(parent: baseline.parent, keyCoordinator: baseline.coordinator, uuid: ScriptedUUID([UUID()]), operations: renameBefore, backupOperations: SystemBackupExclusionOperations())
        await XCTAssertThrowsProjectState(.stateUnavailable) { _ = try await precommitWriter.recordAttempt(projectID: registration.projectID, coverage: nonCompleteCoverage(.partial), finishedAt: Date(timeIntervalSince1970: 4), metadata: try AttemptSummaryMetadata(advisoryCacheSchemaVersion: nil, advisory: nil), lease: baseline.lease) }
        assertInjectedFailureOrdering(.renameStagingFile, events: renameBefore.snapshot())
        XCTAssertEqual(try Data(contentsOf: baseline.stateFile), priorBytes)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: baseline.stateDirectory.path).contains(where: { $0.hasSuffix(".tmp") }))

        for (site, outcome) in [(StateSyscallSite.renameStagingFile, ScriptedStateFailure.failAfterSuccess(EIO)), (.syncScannerAfterRename, .failBefore(EIO)), (.syncScannerAfterRename, .failAfterSuccess(EIO))] {
            let operations = ScriptedStateFileSystemOperations(failingSite: site, failure: outcome)
            let writer = try await ProjectStateStore(parent: baseline.parent, keyCoordinator: baseline.coordinator, uuid: ScriptedUUID([UUID(), UUID()]), operations: operations, backupOperations: SystemBackupExclusionOperations())
            let commit = try await writer.recordAttempt(projectID: registration.projectID, coverage: nonCompleteCoverage(.failed), finishedAt: Date(timeIntervalSince1970: 5), metadata: try AttemptSummaryMetadata(advisoryCacheSchemaVersion: nil, advisory: nil), lease: baseline.lease)
            XCTAssertEqual(commit, .committedDurabilityUncertain)
            assertInjectedFailureOrdering(site, events: operations.snapshot())
            let visible = try await writer.loadSummary(projectID: registration.projectID)
            XCTAssertEqual(visible?.lastAttempt?.terminalState, .failed)
            XCTAssertEqual(try Data(contentsOf: baseline.outsideCanary), baseline.outsideSnapshot)
        }

        for (outcome, failUnlockCleanup) in [
            (ScriptedStateFailure.failAfterSuccess(EIO), true),
            (.stopAfterSuccess, false),
        ] {
            let acquiredThenFailed = ScriptedStateFileSystemOperations(
                failingSite: .acquireTransactionLock, failure: outcome,
                failureOccurrence: 2,
                failUnlockCleanupAfterAcquiredFailure: failUnlockCleanup
            )
            let lockWriter = try await ProjectStateStore(parent: baseline.parent, keyCoordinator: baseline.coordinator, uuid: ScriptedUUID([UUID()]), operations: acquiredThenFailed, backupOperations: SystemBackupExclusionOperations())
            await XCTAssertThrowsProjectState(.stateUnavailable) { _ = try await lockWriter.recordAttempt(projectID: registration.projectID, coverage: nonCompleteCoverage(.partial), finishedAt: Date(timeIntervalSince1970: 6), metadata: try AttemptSummaryMetadata(advisoryCacheSchemaVersion: nil, advisory: nil), lease: baseline.lease) }
            let lockFD = Darwin.open(baseline.stateDirectory.appendingPathComponent(".state.lock").path, O_RDWR | O_NONBLOCK)
            XCTAssertGreaterThanOrEqual(lockFD, 0)
            XCTAssertEqual(
                flock(lockFD, LOCK_EX | LOCK_NB), 0,
                "Post-success acquire or failed cleanup leaked flock ownership: \(outcome)"
            )
            _ = flock(lockFD, LOCK_UN)
            Darwin.close(lockFD)
            _ = lockWriter
        }

        let cleanupOps = ScriptedStateFileSystemOperations(failingSite: .syncStagingFile, failure: .failBefore(EIO))
        do {
            let cleanupWriter = try await ProjectStateStore(parent: baseline.parent, keyCoordinator: baseline.coordinator, uuid: ScriptedUUID([UUID()]), operations: cleanupOps, backupOperations: SystemBackupExclusionOperations())
            _ = try await cleanupWriter.recordAttempt(projectID: registration.projectID, coverage: nonCompleteCoverage(.failed), finishedAt: Date(timeIntervalSince1970: 7), metadata: try AttemptSummaryMetadata(advisoryCacheSchemaVersion: nil, advisory: nil), lease: baseline.lease)
            XCTFail("Staging failure ignored")
        } catch {
            XCTAssertTrue(cleanupOps.snapshot().contains(.unlinkStagingFileAfterFailure))
            XCTAssertTrue(cleanupOps.snapshot().contains(.closeStagingFileAfterFailure))
        }

        let operations = ScriptedStateFileSystemOperations(failingSite: .releaseTransactionLock, failure: .failAfterSuccess(EIO), failureOccurrence: 2)
            let writer = try await ProjectStateStore(parent: baseline.parent, keyCoordinator: baseline.coordinator, uuid: ScriptedUUID([UUID()]), operations: operations, backupOperations: SystemBackupExclusionOperations())
            let commit = try await writer.recordAttempt(projectID: registration.projectID, coverage: nonCompleteCoverage(.unavailable), finishedAt: Date(timeIntervalSince1970: 7), metadata: try AttemptSummaryMetadata(advisoryCacheSchemaVersion: nil, advisory: nil), lease: baseline.lease)
            XCTAssertEqual(commit, .committedDurabilityUncertain)
            XCTAssertTrue(operations.snapshot().contains(.closeLockFile), "Release failure did not retire the lock descriptor")
            await XCTAssertThrowsProjectState(.stateUnavailable) { _ = try await writer.recordAttempt(projectID: registration.projectID, coverage: nonCompleteCoverage(.partial), finishedAt: Date(timeIntervalSince1970: 8), metadata: try AttemptSummaryMetadata(advisoryCacheSchemaVersion: nil, advisory: nil), lease: baseline.lease) }

        try assertCleanupOnlySites()
        try assertProducerCleanupMappings()
        try assertKnownSuccessfulCloseIsNotRetried()
    }

    func testCorruptOversizedOrUnknownSchemaStateFailsClosed() async throws {
        let fixture = try await StateStoreFixture.make(); defer { fixture.remove() }
        let registration = try await fixture.register()
        _ = try await fixture.store.addSuppression(projectID: registration.projectID, record: try suppression(6), lease: fixture.lease)
        _ = try await fixture.store.recordAttempt(projectID: registration.projectID, coverage: completeCoverage(), finishedAt: Date(timeIntervalSince1970: 2), metadata: try testAttemptMetadata(), lease: fixture.lease)
        let baseline = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.stateFile)) as? [String: Any])
        var corruptions = [Data("{".utf8), Data(repeating: 0x41, count: 8 * 1024 * 1024 + 1)]
        let baselineJSON = try XCTUnwrap(String(data: Data(contentsOf: fixture.stateFile), encoding: .utf8))
        for replacement in ["\"finishedAt\":2000.0", "\"finishedAt\":2e3"] {
            let altered = baselineJSON.replacingOccurrences(of: "\"finishedAt\":2000", with: replacement)
            XCTAssertNotEqual(altered, baselineJSON)
            corruptions.append(Data(altered.utf8))
        }
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["schemaVersion"] = 0 }, { $0["schemaVersion"] = 99 },
            { $0["projectID"] = fixture.projectUUID.uuidString.uppercased() }, { $0["projectID"] = UUID().uuidString.lowercased() },
            { $0["scannerSchemaVersion"] = 0 }, { $0["scannerSchemaVersion"] = 2 },
            { $0["advisoryCacheSchemaVersion"] = 0 }, { $0["label"] = String(repeating: "x", count: 201) }, { $0["label"] = "bad\u{0001}label" }, { $0["label"] = "bad\u{202E}label" },
            { $0["bookmark"] = "%%%" }, { $0["bookmark"] = Data().base64EncodedString() }, { $0["bookmark"] = Data(repeating: 1, count: 1_048_577).base64EncodedString() }, { $0["keyGeneration"] = "not-a-uuid" },
            { var l = $0["limitOverrides"] as! [String: Any]; l["generalFiles"] = 0; $0["limitOverrides"] = l },
            { var s = $0["suppressions"] as! [[String: Any]]; s[0]["fingerprint"] = Data(repeating: 1, count: 31).base64EncodedString(); $0["suppressions"] = s },
            { var s = $0["suppressions"] as! [[String: Any]]; s.append(s[0]); $0["suppressions"] = s },
            { var s = $0["suppressions"] as! [[String: Any]]; s[0]["ruleVersion"] = 0; $0["suppressions"] = s },
            { var s = $0["suppressions"] as! [[String: Any]]; s[0]["ruleID"] = ""; $0["suppressions"] = s },
            { var s = $0["suppressions"] as! [[String: Any]]; s[0]["ruleID"] = "bad\u{0001}"; $0["suppressions"] = s },
            { var s = $0["suppressions"] as! [[String: Any]]; s[0]["createdAt"] = -1; $0["suppressions"] = s },
            { var a = $0["lastAttempt"] as! [String: Any]; a["finishedAt"] = -1; $0["lastAttempt"] = a },
            { var a = $0["lastAttempt"] as! [String: Any]; a["finishedAt"] = 1.5; $0["lastAttempt"] = a },
            { var a = $0["lastAttempt"] as! [String: Any]; a["finishedAt"] = Double.greatestFiniteMagnitude; $0["lastAttempt"] = a },
            { var a = $0["lastAttempt"] as! [String: Any]; a["finishedAt"] = 9_007_199_254_740_993 as Int64; $0["lastAttempt"] = a },
            { var a = $0["lastAttempt"] as! [String: Any]; var d = a["detectors"] as! [[String: Any]]; d[0]["scannedFiles"] = 2; d[0]["candidateFiles"] = 1; a["detectors"] = d; $0["lastAttempt"] = a },
            { var a = $0["lastAttempt"] as! [String: Any]; var d = a["detectors"] as! [[String: Any]]; d[0]["scannedBytes"] = 5; d[0]["candidateBytes"] = 4; a["detectors"] = d; $0["lastAttempt"] = a },
            { var c = $0["lastCompleteSummary"] as! [String: Any]; var m = c["metadata"] as! [String: Any]; m["advisoryCacheSchemaVersion"] = 0; c["metadata"] = m; $0["lastCompleteSummary"] = c },
            { for key in ["lastCompleteSummary", "lastAttempt"] { var a = $0[key] as! [String: Any]; var m = a["metadata"] as! [String: Any]; m["advisory"] = NSNull(); a["metadata"] = m; $0[key] = a } },
            { for key in ["lastCompleteSummary", "lastAttempt"] { var a = $0[key] as! [String: Any]; var m = a["metadata"] as! [String: Any]; var advisory = m["advisory"] as! [String: Any]; advisory["validation"] = ["state":"partial", "reason":"advisory_cache_missing"]; m["advisory"] = advisory; a["metadata"] = m; $0[key] = a } },
            { for key in ["lastCompleteSummary", "lastAttempt"] { var a = $0[key] as! [String: Any]; var m = a["metadata"] as! [String: Any]; var advisory = m["advisory"] as! [String: Any]; advisory["validation"] = ["state":"unavailable", "reason":"advisory_cache_missing"]; m["advisory"] = advisory; a["metadata"] = m; $0[key] = a } },
            { $0["lastAttempt"] = NSNull(); $0["advisoryCacheSchemaVersion"] = NSNull() },
            { for key in ["lastCompleteSummary", "lastAttempt"] { var a = $0[key] as! [String: Any]; var m = a["metadata"] as! [String: Any]; m["advisoryCacheSchemaVersion"] = NSNull(); a["metadata"] = m; $0[key] = a }; $0["advisoryCacheSchemaVersion"] = NSNull() },
            { var a = $0["lastAttempt"] as! [String: Any]; var d = a["detectors"] as! [[String: Any]]; d.removeLast(); a["detectors"] = d; $0["lastAttempt"] = a },
            { var a = $0["lastAttempt"] as! [String: Any]; var d = a["detectors"] as! [[String: Any]]; d.append(d[0]); a["detectors"] = d; $0["lastAttempt"] = a },
            { var c = $0["lastCompleteSummary"] as! [String: Any]; c["terminalState"] = "partial"; $0["lastCompleteSummary"] = c },
            { var c = $0["lastCompleteSummary"] as! [String: Any]; var d = c["detectors"] as! [[String: Any]]; d[0]["reasonCounts"] = [["reason":"global_byte_budget","count":1]]; c["detectors"] = d; $0["lastCompleteSummary"] = c },
            { for key in ["lastCompleteSummary", "lastAttempt"] { var a = $0[key] as! [String: Any]; var d = a["detectors"] as! [[String: Any]]; d[0]["scannedFiles"] = 0; d[0]["skippedFiles"] = 1; a["detectors"] = d; $0[key] = a } },
            { for key in ["lastCompleteSummary", "lastAttempt"] { var a = $0[key] as! [String: Any]; var d = a["detectors"] as! [[String: Any]]; d[0]["scannedBytes"] = 0; d[0]["failedBytes"] = 4; a["detectors"] = d; $0[key] = a } },
            { var a = $0["lastAttempt"] as! [String: Any]; var d = a["detectors"] as! [[String: Any]]; d[0]["reasonCounts"] = [["reason":"made_up","count":1]]; a["detectors"] = d; $0["lastAttempt"] = a },
            { var a = $0["lastAttempt"] as! [String: Any]; var d = a["detectors"] as! [[String: Any]]; let r = ["reason":"cancelled","count":1] as [String : Any]; d[0]["reasonCounts"] = [r,r]; a["detectors"] = d; $0["lastAttempt"] = a },
            { var a = $0["lastAttempt"] as! [String: Any]; var d = a["detectors"] as! [[String: Any]]; d[0]["reasonCounts"] = [["reason":"cancelled","count":0]]; a["detectors"] = d; $0["lastAttempt"] = a },
            { var a = $0["lastCompleteSummary"] as! [String: Any]; a["finishedAt"] = 3_000; $0["lastAttempt"] = a }
        ]
        for mutate in mutations { var object = baseline; mutate(&object); corruptions.append(try JSONSerialization.data(withJSONObject: object)) }
        for key in ["generalFiles","secretFileBytes","lockfileBytes","manifestBytes","installedManifests","directories","directoryEntries","dependencyNodesPerLockfile","dependencyNodesPerSession","inputBytes","wallTimeMilliseconds"] {
            var object = baseline; var limits = object["limitOverrides"] as! [String: Any]; limits[key] = 0; object["limitOverrides"] = limits
            corruptions.append(try JSONSerialization.data(withJSONObject: object))
        }
        var tooMany = baseline; let template = (tooMany["suppressions"] as! [[String: Any]])[0]
        let records = (0..<10_001).map { index -> [String: Any] in var record = template; var bytes = Data(repeating: 0, count: 32); withUnsafeBytes(of: UInt64(index).bigEndian) { bytes.replaceSubrange(24..<32, with: $0) }; record["fingerprint"] = bytes.base64EncodedString(); return record }
        tooMany["suppressions"] = records
        corruptions.append(try JSONSerialization.data(withJSONObject: tooMany))
        for (index, corruption) in corruptions.enumerated() {
            try corruption.write(to: fixture.stateFile)
            do {
                _ = try await fixture.store.loadSummary(projectID: registration.projectID)
                XCTFail("Accepted corruption matrix entry \(index)")
            } catch {
                XCTAssertEqual(error as? ProjectStateError, .invalidState, "Corruption matrix entry \(index)")
            }
        }

        try Data(baselineJSON.utf8).write(to: fixture.stateFile)
        _ = try await fixture.store.recordAttempt(
            projectID: registration.projectID,
            coverage: nonCompleteCoverage(.partial),
            finishedAt: Date(timeIntervalSince1970: 3),
            metadata: try AttemptSummaryMetadata(
                advisoryCacheSchemaVersion: nil, advisory: nil
            ),
            lease: fixture.lease
        )
        let priorCompleteBaseline = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.stateFile))
                as? [String: Any]
        )
        let priorCompleteMutations: [(inout [String: Any]) -> Void] = [
            { var complete = $0["lastCompleteSummary"] as! [String: Any]; var metadata = complete["metadata"] as! [String: Any]; metadata["advisory"] = NSNull(); complete["metadata"] = metadata; $0["lastCompleteSummary"] = complete },
            { var complete = $0["lastCompleteSummary"] as! [String: Any]; var metadata = complete["metadata"] as! [String: Any]; metadata["advisoryCacheSchemaVersion"] = NSNull(); metadata["advisory"] = NSNull(); complete["metadata"] = metadata; $0["lastCompleteSummary"] = complete },
            { var complete = $0["lastCompleteSummary"] as! [String: Any]; var metadata = complete["metadata"] as! [String: Any]; var advisory = metadata["advisory"] as! [String: Any]; advisory["validation"] = ["state":"partial", "reason":"advisory_cache_missing"]; metadata["advisory"] = advisory; complete["metadata"] = metadata; $0["lastCompleteSummary"] = complete },
            { var complete = $0["lastCompleteSummary"] as! [String: Any]; var metadata = complete["metadata"] as! [String: Any]; var advisory = metadata["advisory"] as! [String: Any]; advisory["validation"] = ["state":"unavailable", "reason":"advisory_cache_missing"]; metadata["advisory"] = advisory; complete["metadata"] = metadata; $0["lastCompleteSummary"] = complete },
        ]
        for (index, mutate) in priorCompleteMutations.enumerated() {
            var object = priorCompleteBaseline
            mutate(&object)
            try JSONSerialization.data(withJSONObject: object).write(to: fixture.stateFile)
            do {
                _ = try await fixture.store.loadSummary(projectID: registration.projectID)
                XCTFail("Accepted corrupt prior complete advisory entry \(index)")
            } catch {
                XCTAssertEqual(error as? ProjectStateError, .invalidState)
            }
        }
    }

    func testUnknownTopLevelAndNestedJSONKeysFailClosed() async throws {
        let fixture = try await StateStoreFixture.make(); defer { fixture.remove() }
        let registration = try await fixture.register()
        let registeredObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.stateFile)) as? [String: Any])
        for key in ["label", "advisoryCacheSchemaVersion", "lastCompleteSummary", "lastAttempt"] { XCTAssertTrue(registeredObject[key] is NSNull, "Optional \(key) must encode explicit null") }
        let registeredOverrides = try XCTUnwrap(registeredObject["limitOverrides"] as? [String: Any])
        XCTAssertTrue(registeredOverrides.values.allSatisfy { $0 is NSNull }, "Every optional override must encode explicit null")
        _ = try await fixture.store.addSuppression(projectID: registration.projectID, record: try suppression(7), lease: fixture.lease)
        let nullDateAdvisory = AdvisoryCoverageMetadata(generation: testAdvisoryMetadata().generation, source: .osv, ageSeconds: 60, lastSuccessfulRefresh: nil, activatedAt: nil, validation: .complete)
        _ = try await fixture.store.recordAttempt(projectID: registration.projectID, coverage: completeCoverage(advisory: nullDateAdvisory), finishedAt: Date(timeIntervalSince1970: 1), metadata: try AttemptSummaryMetadata(advisoryCacheSchemaVersion: 1, advisory: nullDateAdvisory), lease: fixture.lease)
        _ = try await fixture.store.recordAttempt(projectID: registration.projectID, coverage: nonCompleteCoverage(.partial), finishedAt: Date(timeIntervalSince1970: 2), metadata: try AttemptSummaryMetadata(advisoryCacheSchemaVersion: nil, advisory: nil), lease: fixture.lease)
        let baseline = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.stateFile)) as? [String: Any])
        XCTAssertTrue(baseline["advisoryCacheSchemaVersion"] is NSNull || baseline["advisoryCacheSchemaVersion"] is NSNumber)
        let overrideKeys = try XCTUnwrap(baseline["limitOverrides"] as? [String: Any]).keys
        XCTAssertEqual(Set(overrideKeys), Set(["generalFiles","secretFileBytes","lockfileBytes","manifestBytes","installedManifests","directories","directoryEntries","dependencyNodesPerLockfile","dependencyNodesPerSession","inputBytes","wallTimeMilliseconds"]))
        let attemptMetadata = try XCTUnwrap((baseline["lastAttempt"] as? [String: Any])?["metadata"] as? [String: Any])
        XCTAssertTrue(attemptMetadata["advisoryCacheSchemaVersion"] is NSNull); XCTAssertTrue(attemptMetadata["advisory"] is NSNull)
        let completeMetadata = try XCTUnwrap((baseline["lastCompleteSummary"] as? [String: Any])?["metadata"] as? [String: Any])
        let advisoryObject = try XCTUnwrap(completeMetadata["advisory"] as? [String: Any])
        XCTAssertTrue(advisoryObject["lastSuccessfulRefresh"] is NSNull); XCTAssertTrue(advisoryObject["activatedAt"] is NSNull)
        let mutations: [(String, (inout [String: Any]) -> Void)] = [
            ("top unknown", { $0["unknown"] = true }), ("top missing", { $0.removeValue(forKey: "watchEnabled") }),
            ("limits unknown", { var v = $0["limitOverrides"] as! [String: Any]; v["unknown"] = 1; $0["limitOverrides"] = v }),
            ("limits missing", { var v = $0["limitOverrides"] as! [String: Any]; v.removeValue(forKey: "generalFiles"); $0["limitOverrides"] = v }),
            ("attempt unknown", { var v = $0["lastAttempt"] as! [String: Any]; v["unknown"] = 1; $0["lastAttempt"] = v }),
            ("attempt missing", { var v = $0["lastAttempt"] as! [String: Any]; v.removeValue(forKey: "detectors"); $0["lastAttempt"] = v }),
            ("detector unknown", { var a = $0["lastAttempt"] as! [String: Any]; var d = a["detectors"] as! [[String: Any]]; d[0]["unknown"] = 1; a["detectors"] = d; $0["lastAttempt"] = a }),
            ("detector missing", { var a = $0["lastAttempt"] as! [String: Any]; var d = a["detectors"] as! [[String: Any]]; d[0].removeValue(forKey: "candidateFiles"); a["detectors"] = d; $0["lastAttempt"] = a }),
            ("metadata unknown", { var a = $0["lastAttempt"] as! [String: Any]; var m = a["metadata"] as! [String: Any]; m["unknown"] = 1; a["metadata"] = m; $0["lastAttempt"] = a }),
            ("metadata missing", { var a = $0["lastAttempt"] as! [String: Any]; var m = a["metadata"] as! [String: Any]; m.removeValue(forKey: "advisory"); a["metadata"] = m; $0["lastAttempt"] = a }),
            ("complete summary unknown", { var c = $0["lastCompleteSummary"] as! [String: Any]; c["unknown"] = 1; $0["lastCompleteSummary"] = c }),
            ("complete summary missing", { var c = $0["lastCompleteSummary"] as! [String: Any]; c.removeValue(forKey: "terminalState"); $0["lastCompleteSummary"] = c }),
            ("advisory unknown", { var c = $0["lastCompleteSummary"] as! [String: Any]; var m = c["metadata"] as! [String: Any]; var a = m["advisory"] as! [String: Any]; a["unknown"] = 1; m["advisory"] = a; c["metadata"] = m; $0["lastCompleteSummary"] = c }),
            ("advisory missing", { var c = $0["lastCompleteSummary"] as! [String: Any]; var m = c["metadata"] as! [String: Any]; var a = m["advisory"] as! [String: Any]; a.removeValue(forKey: "generation"); m["advisory"] = a; c["metadata"] = m; $0["lastCompleteSummary"] = c }),
            ("reason unknown", { var a = $0["lastAttempt"] as! [String: Any]; var d = a["detectors"] as! [[String: Any]]; var r = d[0]["reasonCounts"] as! [[String: Any]]; r[0]["unknown"] = 1; d[0]["reasonCounts"] = r; a["detectors"] = d; $0["lastAttempt"] = a }),
            ("reason missing", { var a = $0["lastAttempt"] as! [String: Any]; var d = a["detectors"] as! [[String: Any]]; var r = d[0]["reasonCounts"] as! [[String: Any]]; r[0].removeValue(forKey: "count"); d[0]["reasonCounts"] = r; a["detectors"] = d; $0["lastAttempt"] = a }),
            ("suppression unknown", { var s = $0["suppressions"] as! [[String: Any]]; s[0]["unknown"] = 1; $0["suppressions"] = s }),
            ("suppression missing", { var s = $0["suppressions"] as! [[String: Any]]; s[0].removeValue(forKey: "fingerprint"); $0["suppressions"] = s })
        ]
        for (name, mutate) in mutations {
            var object = baseline; mutate(&object)
            try JSONSerialization.data(withJSONObject: object).write(to: fixture.stateFile)
            do { _ = try await fixture.store.loadSummary(projectID: registration.projectID); XCTFail("Accepted \(name)") }
            catch { XCTAssertEqual(error as? ProjectStateError, .invalidState, name) }
        }
    }

    func testSuppressionRecordStoresOnlyFingerprintRuleVersionAndCreationTime() async throws {
        let fixture = try await StateStoreFixture.make(); defer { fixture.remove() }
        let registration = try await fixture.register(); _ = try await fixture.store.addSuppression(projectID: registration.projectID, record: try suppression(8), lease: fixture.lease)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.stateFile)) as? [String: Any])
        let records = try XCTUnwrap(object["suppressions"] as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(records.first).keys), Set(["fingerprint","ruleID","ruleVersion","createdAt"]))
        let oneRecordBytes = try Data(contentsOf: fixture.stateFile)
        await XCTAssertThrowsProjectState(.duplicateSuppression) { _ = try await fixture.store.addSuppression(projectID: registration.projectID, record: try suppression(8), lease: fixture.lease) }
        XCTAssertEqual(try Data(contentsOf: fixture.stateFile), oneRecordBytes)
        try seedUniqueSuppressions(in: fixture.stateFile, count: 10_000)
        let fullBytes = try Data(contentsOf: fixture.stateFile)
        await XCTAssertThrowsProjectState(.suppressionLimit) { _ = try await fixture.store.addSuppression(projectID: registration.projectID, record: try suppressionForIndex(10_001), lease: fixture.lease) }
        XCTAssertEqual(try Data(contentsOf: fixture.stateFile), fullBytes)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.stateDirectory.path).contains(where: { $0.hasSuffix(".tmp") }))
    }

    func testPersistentLoadExposesSuppressionsOnlyAfterGenerationMatch() async throws {
        let fixture = try await StateStoreFixture.make(); defer { fixture.remove() }
        let registration = try await fixture.register(); let record = try suppression(9)
        _ = try await fixture.store.addSuppression(projectID: registration.projectID, record: record, lease: fixture.lease)
        guard case .persistent(_, let suppressions, let lease) = try await fixture.store.loadForScan(projectID: registration.projectID) else { return XCTFail("Expected persistent") }
        XCTAssertEqual(suppressions, [record]); XCTAssertEqual(lease.persistence, .persistent(generation: fixture.generation))
    }

    func testEphemeralAndResetRequiredLoadsExposeNoApplicableSuppressions() async throws {
        let fixture = try await StateStoreFixture.make(); defer { fixture.remove() }
        let registration = try await fixture.register(); _ = try await fixture.store.addSuppression(projectID: registration.projectID, record: try suppression(10), lease: fixture.lease)
        let unavailable = ProjectKeyCoordinator(store: ScriptedKeyStore(reads: [
            .fixed(.unavailable(.interactionNotAllowed)),
            .fixed(.unavailable(.interactionNotAllowed)),
        ]))
        let ephemeralStore = try await ProjectStateStore(parent: fixture.parent, keyCoordinator: unavailable, uuid: ScriptedUUID([UUID()]), operations: SystemStateFileSystemOperations(), backupOperations: SystemBackupExclusionOperations())
        guard case .ephemeral = try await ephemeralStore.loadForScan(projectID: registration.projectID) else { return XCTFail("Expected ephemeral without suppression payload") }
        let prior = try Data(contentsOf: fixture.stateFile)
        await XCTAssertThrowsProjectState(.ephemeralRun) { _ = try await ephemeralStore.addSuppression(projectID: registration.projectID, record: try suppression(11), lease: fixture.lease) }
        XCTAssertEqual(try Data(contentsOf: fixture.stateFile), prior)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.stateDirectory.path).contains(where: { $0.hasSuffix(".tmp") }))
        let missing = ProjectKeyCoordinator(store: ScriptedKeyStore(reads: [.fixed(.missing)]))
        let resetStore = try await ProjectStateStore(parent: fixture.parent, keyCoordinator: missing, uuid: ScriptedUUID([UUID()]), operations: SystemStateFileSystemOperations(), backupOperations: SystemBackupExclusionOperations())
        guard case .resetRequired = try await resetStore.loadForScan(projectID: registration.projectID) else { return XCTFail("Expected reset-required without suppression payload") }
        await XCTAssertThrowsProjectState(.keyResetRequired) { _ = try await resetStore.addSuppression(projectID: registration.projectID, record: try suppression(12), lease: fixture.lease) }
        XCTAssertEqual(try Data(contentsOf: fixture.stateFile), prior)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.stateDirectory.path).contains(where: { $0.hasSuffix(".tmp") }))
    }

    func testRegistrationGeneratesItsOwnRandomProjectIdentifier() async throws {
        let expected = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
        let fixture = try await StateStoreFixture.make(projectUUID: expected); defer { fixture.remove() }
        let registration = try await fixture.register()
        XCTAssertEqual(registration.projectID.rawValue, expected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.stateDirectory.appendingPathComponent("project-\(expected.uuidString.lowercased()).json").path))
        let prior = try Data(contentsOf: fixture.stateFile)
        let collisionStore = try await ProjectStateStore(parent: fixture.parent, keyCoordinator: fixture.coordinator, uuid: ScriptedUUID([expected, UUID()]), operations: SystemStateFileSystemOperations(), backupOperations: SystemBackupExclusionOperations())
        await XCTAssertThrowsProjectState(.identifierCollision) { _ = try await collisionStore.register(label: nil, bookmark: fixture.bookmark, limitOverrides: .init(), lease: fixture.lease) }
        XCTAssertEqual(try Data(contentsOf: fixture.stateFile), prior)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.stateDirectory.path).contains(where: { $0.hasSuffix(".tmp") }))

        let symlinkID = UUID(uuidString: "abcdef01-2345-4678-8abc-def012345678")!
        let symlinkDestination = fixture.stateDirectory.appendingPathComponent("project-\(symlinkID.uuidString.lowercased()).json")
        try FileManager.default.createSymbolicLink(at: symlinkDestination, withDestinationURL: fixture.outsideCanary)
        let symlinkStore = try await ProjectStateStore(parent: fixture.parent, keyCoordinator: fixture.coordinator, uuid: ScriptedUUID([symlinkID, UUID()]), operations: SystemStateFileSystemOperations(), backupOperations: SystemBackupExclusionOperations())
        await XCTAssertThrowsProjectState(.identifierCollision) { _ = try await symlinkStore.register(label: nil, bookmark: fixture.bookmark, limitOverrides: .init(), lease: fixture.lease) }
        var status = stat()
        XCTAssertEqual(lstat(symlinkDestination.path, &status), 0)
        XCTAssertEqual(status.st_mode & S_IFMT, S_IFLNK)
        XCTAssertEqual(try Data(contentsOf: fixture.outsideCanary), fixture.outsideSnapshot)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.stateDirectory.path).contains(where: { $0.hasSuffix(".tmp") }))
    }
}

private func suppression(_ byte: UInt8) throws -> SuppressionRecord {
    try SuppressionRecord(fingerprint: SuppressionFingerprintPersistence.decode(Data(repeating: byte, count: 32)), ruleID: RuleID(rawValue: "rule-\(byte)")!, ruleVersion: 1, createdAt: Date(timeIntervalSince1970: 1))
}

private func suppressionForIndex(_ index: Int) throws -> SuppressionRecord {
    var bytes = Data(repeating: 0, count: 32)
    withUnsafeBytes(of: UInt64(index).bigEndian) { bytes.replaceSubrange(24..<32, with: $0) }
    return try SuppressionRecord(fingerprint: SuppressionFingerprintPersistence.decode(bytes), ruleID: RuleID(rawValue: "rule-index")!, ruleVersion: 1, createdAt: Date(timeIntervalSince1970: 1))
}

private let cleanupOnlySites: Set<StateSyscallSite> = [.closeScannerDirectory, .closeLockFile, .unlinkStagingFileAfterFailure, .closeStagingFileAfterFailure]
private let bootstrapStateSites = Array(StateSyscallSite.allCases[0..<40]).filter { !cleanupOnlySites.contains($0) }
private let bootstrapExistingLockSites: Set<StateSyscallSite> = [
    .inspectExistingLockFile, .openExistingLockFile, .statExistingLockFile,
    .inspectLockBeforeAcquire, .statLockBeforeAcquire, .acquireTransactionLock,
    .inspectLockAfterAcquire, .statLockAfterAcquire, .releaseTransactionLock, .closeLockFile,
]
private let stagingRecoverySites = Array(StateSyscallSite.allCases[40..<50])
private let readStateSites = Array(StateSyscallSite.allCases[50..<55])
private let registrationWriteSites = Array(StateSyscallSite.allCases[55..<66]).filter { !cleanupOnlySites.contains($0) }
private let allowedFailureCleanupSuffix: Set<StateSyscallSite> = [
    .closeParentDirectory, .closeSharedDirectory, .closeScannerDirectory,
    .closeInitialBackupReference, .closeFinalBackupReference,
    .releaseTransactionLock, .closeLockFile,
    .closeStagingDirectoryStream, .closeRecoveredStagingEntry,
    .closeStateFileAfterRead, .unlinkStagingFileAfterFailure,
    .closeStagingFileAfterFailure,
]
private let postFailureNormalMutationSites: Set<StateSyscallSite> = [
    .createSharedDirectory, .chmodNewSharedDirectory, .createScannerDirectory,
    .chmodNewScannerDirectory, .createLockFile, .chmodNewLockFile,
    .unlinkRecoveredStagingEntry, .createStagingFile, .chmodStagingFile,
    .writeStagingFile, .syncStagingFile, .closeStagingFileBeforeRename,
    .renameStagingFile, .syncScannerAfterRename,
]

private func assertInjectedFailureOrdering(
    _ site: StateSyscallSite,
    events: [StateSyscallSite],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let matchingIndices = events.indices.filter { events[$0] == site }
    XCTAssertEqual(matchingIndices.count, 1, "Injected site must be reached exactly once: \(events)", file: file, line: line)
    guard let injectedIndex = matchingIndices.first else { return }
    let suffix = Array(events.dropFirst(injectedIndex + 1))
    XCTAssertTrue(
        suffix.allSatisfy(allowedFailureCleanupSuffix.contains),
        "Only the frozen cleanup suffix may follow \(site): \(suffix)",
        file: file,
        line: line
    )
    XCTAssertFalse(
        suffix.contains(where: postFailureNormalMutationSites.contains),
        "Normal mutation continued after precommit failure at \(site): \(suffix)",
        file: file,
        line: line
    )
}

private func assertCleanupOnlySites() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-sites-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
    for site in [StateSyscallSite.closeScannerDirectory, .closeLockFile, .closeStagingFileAfterFailure] {
        for failure in [ScriptedStateFailure.failBefore(EIO), .failAfterSuccess(EIO)] {
            let file = root.appendingPathComponent("fd-\(UUID())")
            FileManager.default.createFile(atPath: file.path, contents: Data())
            let descriptor = Darwin.open(file.path, O_RDONLY | O_CLOEXEC)
            let operations = ScriptedStateFileSystemOperations(failingSite: site, failure: failure)
            XCTAssertThrowsError(try operations.close(descriptor: descriptor, site: site))
            var status = stat(); let stillOpen = fstat(descriptor, &status) == 0
            if case .failBefore = failure { XCTAssertTrue(stillOpen); try? SystemStateFileSystemOperations().close(descriptor: descriptor, site: site) }
            else { XCTAssertFalse(stillOpen) }
            assertInjectedFailureOrdering(site, events: operations.snapshot())
        }
    }
    for failure in [ScriptedStateFailure.failBefore(EIO), .failAfterSuccess(EIO)] {
        let name = "staging-\(UUID())"; let file = root.appendingPathComponent(name); FileManager.default.createFile(atPath: file.path, contents: Data())
        let directory = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC); defer { Darwin.close(directory) }
        let operations = ScriptedStateFileSystemOperations(failingSite: .unlinkStagingFileAfterFailure, failure: failure)
        XCTAssertThrowsError(try operations.unlink(directory: directory, name: name, site: .unlinkStagingFileAfterFailure))
        if case .failBefore = failure { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path)) }
        else { XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)) }
        assertInjectedFailureOrdering(.unlinkStagingFileAfterFailure, events: operations.snapshot())
    }
}

private func assertProducerCleanupMappings() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("producer-cleanup-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    for directoryName in ["shared", "scanner"] {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(directoryName), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    for fileName in ["existing-lock", "staging-entry", "state-read"] {
        XCTAssertTrue(FileManager.default.createFile(atPath: root.appendingPathComponent(fileName).path, contents: Data("fixture".utf8), attributes: [.posixPermissions: 0o600]))
    }

    let capability = try PrivateStateParentCapability.open(applicationSupportURL: root)
    defer { capability.close() }
    let directory = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    XCTAssertGreaterThanOrEqual(directory, 0)
    guard directory >= 0 else { return }
    defer { Darwin.close(directory) }

    let mappings: [(StateSyscallSite, StateSyscallSite)] = [
        (.duplicatePrivateStateParent, .closeParentDirectory),
        (.openSharedDirectory, .closeSharedDirectory),
        (.openScannerDirectory, .closeScannerDirectory),
        (.createLockFile, .closeLockFile),
        (.openExistingLockFile, .closeLockFile),
        (.duplicateScannerForEnumeration, .closeScannerDirectory),
        (.openStagingDirectoryStream, .closeStagingDirectoryStream),
        (.openStagingEntry, .closeRecoveredStagingEntry),
        (.openStateFileForRead, .closeStateFileAfterRead),
        (.createStagingFile, .closeStagingFileAfterFailure),
    ]

    for failure in [ScriptedStateFailure.failAfterSuccess(EIO), .stopAfterSuccess] {
        for (producer, cleanup) in mappings {
            let operations = ScriptedStateFileSystemOperations(failingSite: producer, failure: failure)
            let descriptorsBefore = openDescriptorCount()
            do {
                try exerciseProducingSite(producer, operations: operations, capability: capability, directory: directory)
                XCTFail("Post-success outcome did not interrupt producer \(producer)")
            } catch StateOperationError.failedAfterSuccess(let reached, _) {
                guard case .failAfterSuccess = failure else { return XCTFail("Unexpected fail-after outcome for \(producer)") }
                XCTAssertEqual(reached, producer)
            } catch StateOperationError.stoppedAfterSuccess(let reached) {
                guard case .stopAfterSuccess = failure else { return XCTFail("Unexpected stop-after outcome for \(producer)") }
                XCTAssertEqual(reached, producer)
            } catch {
                XCTFail("Wrong post-success error for \(producer): \(error)")
            }
            XCTAssertEqual(
                operations.cleanupSnapshot(),
                [.init(producer: producer, cleanup: cleanup)],
                "Producer cleanup mapping drifted for \(producer)"
            )
            XCTAssertEqual(operations.snapshot(), [producer, cleanup], "Cleanup must immediately follow its producer")
            XCTAssertEqual(openDescriptorCount(), descriptorsBefore, "Producer leaked a descriptor or directory stream: \(producer)")
        }
    }
}

private func assertKnownSuccessfulCloseIsNotRetried() throws {
    let atomicRoot = FileManager.default.temporaryDirectory.appendingPathComponent("close-aba-atomic-\(UUID())")
    try FileManager.default.createDirectory(at: atomicRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: atomicRoot) }
    let atomicParent = try PrivateStateParentCapability.open(applicationSupportURL: atomicRoot)
    defer { atomicParent.close() }
    for outcome in [ScriptedStateFailure.failAfterSuccess(EIO), .stopAfterSuccess] {
        let operations = ScriptedStateFileSystemOperations(
            failingSite: .closeScannerDirectory, failure: outcome,
            recycleClosedDescriptor: true
        )
        let atomic = try AtomicStateFile.open(
            parent: atomicParent, operations: operations,
            backupOperations: SystemBackupExclusionOperations()
        )
        atomic.close()
        XCTAssertTrue(
            operations.consumeRecycledDescriptorsWereOpen(),
            "Atomic close retried a descriptor already closed by \(outcome)"
        )
    }

    for outcome in [ScriptedStateFailure.failAfterSuccess(EIO), .stopAfterSuccess] {
        let operations = ScriptedStateFileSystemOperations(
            failingSite: .closeStateFileAfterRead, failure: outcome,
            recycleClosedDescriptor: true
        )
        let atomic = try AtomicStateFile.open(
            parent: atomicParent, operations: operations,
            backupOperations: SystemBackupExclusionOperations()
        )
        let invalidState = atomicRoot
            .appendingPathComponent("Pearcleaner/ProjectScanner/invalid-close.json")
        try? FileManager.default.removeItem(at: invalidState)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: invalidState.path, contents: Data("invalid".utf8),
            attributes: [.posixPermissions: 0o644]
        ))
        XCTAssertThrowsError(try atomic.read(name: invalidState.lastPathComponent))
        XCTAssertTrue(
            operations.consumeRecycledDescriptorsWereOpen(),
            "Read-failure cleanup retried a descriptor already closed by \(outcome)"
        )
        atomic.close()
    }

    for outcome in [ScriptedStateFailure.failAfterSuccess(EIO), .stopAfterSuccess] {
        let lockRoot = FileManager.default.temporaryDirectory.appendingPathComponent("close-aba-lock-\(UUID())")
        try FileManager.default.createDirectory(at: lockRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: lockRoot) }
        let directory = Darwin.open(lockRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(directory, 0)
        guard directory >= 0 else { continue }
        defer { Darwin.close(directory) }

        let operations = ScriptedStateFileSystemOperations(
            failingSite: .closeLockFile, failure: outcome,
            recycleClosedDescriptor: true
        )
        let transactionLock = try ProjectStateTransactionLock.open(
            directoryDescriptor: directory, operations: operations
        )
        transactionLock.close()
        XCTAssertTrue(
            operations.consumeRecycledDescriptorsWereOpen(),
            "Lock retirement retried a descriptor already closed by \(outcome)"
        )
    }

    for outcome in [ScriptedStateFailure.failAfterSuccess(EIO), .stopAfterSuccess] {
        let invalidRoot = FileManager.default.temporaryDirectory.appendingPathComponent("close-aba-invalid-lock-\(UUID())")
        try FileManager.default.createDirectory(at: invalidRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: invalidRoot) }
        XCTAssertTrue(FileManager.default.createFile(
            atPath: invalidRoot.appendingPathComponent(".state.lock").path,
            contents: Data(), attributes: [.posixPermissions: 0o644]
        ))
        let directory = Darwin.open(invalidRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(directory, 0)
        guard directory >= 0 else { continue }
        defer { Darwin.close(directory) }
        let operations = ScriptedStateFileSystemOperations(
            failingSite: .closeLockFile, failure: outcome,
            recycleClosedDescriptor: true
        )
        XCTAssertThrowsError(try ProjectStateTransactionLock.open(
            directoryDescriptor: directory, operations: operations
        ))
        XCTAssertTrue(
            operations.consumeRecycledDescriptorsWereOpen(),
            "Invalid-lock cleanup retried a descriptor already closed by \(outcome)"
        )
    }
}

private func exerciseProducingSite(
    _ site: StateSyscallSite,
    operations: ScriptedStateFileSystemOperations,
    capability: PrivateStateParentCapability,
    directory: Int32
) throws {
    switch site {
    case .duplicatePrivateStateParent:
        let descriptor = try operations.duplicateParent(capability, site: site)
        try SystemStateFileSystemOperations().close(descriptor: descriptor, site: .closeParentDirectory)
    case .openSharedDirectory, .openScannerDirectory:
        let name = site == .openSharedDirectory ? "shared" : "scanner"
        let descriptor = try operations.open(directory: directory, name: name, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC, mode: 0, site: site)
        try SystemStateFileSystemOperations().close(descriptor: descriptor, site: site == .openSharedDirectory ? .closeSharedDirectory : .closeScannerDirectory)
    case .createLockFile, .createStagingFile:
        let name = "created-\(site.rawValue)-\(UUID())"
        let descriptor = try operations.open(directory: directory, name: name, flags: O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode: 0o600, site: site)
        try SystemStateFileSystemOperations().close(descriptor: descriptor, site: site == .createLockFile ? .closeLockFile : .closeStagingFileAfterFailure)
    case .openExistingLockFile, .openStagingEntry, .openStateFileForRead:
        let name: String
        let cleanup: StateSyscallSite
        switch site {
        case .openExistingLockFile: name = "existing-lock"; cleanup = .closeLockFile
        case .openStagingEntry: name = "staging-entry"; cleanup = .closeRecoveredStagingEntry
        default: name = "state-read"; cleanup = .closeStateFileAfterRead
        }
        let descriptor = try operations.open(directory: directory, name: name, flags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC, mode: 0, site: site)
        try SystemStateFileSystemOperations().close(descriptor: descriptor, site: cleanup)
    case .duplicateScannerForEnumeration:
        let descriptor = try operations.duplicate(descriptor: directory, site: site)
        try SystemStateFileSystemOperations().close(descriptor: descriptor, site: .closeScannerDirectory)
    case .openStagingDirectoryStream:
        let duplicated = fcntl(directory, F_DUPFD_CLOEXEC, 0)
        guard duplicated >= 0 else { throw ProjectStateError.stateUnavailable }
        let stream = try operations.openDirectoryStream(descriptor: duplicated, site: site)
        try SystemStateFileSystemOperations().closeDirectoryStream(stream, site: .closeStagingDirectoryStream)
    default:
        XCTFail("Non-producing site passed to producer proof: \(site)")
    }
}

private func openDescriptorCount() -> Int {
    (0..<getdtablesize()).reduce(into: 0) { count, descriptor in
        errno = 0
        if fcntl(descriptor, F_GETFD) != -1 || errno != EBADF { count += 1 }
    }
}

private final class StateMatrixRoot {
    enum Kind { case empty, existingLock, staging }
    let root: URL; let state: URL; let outside: URL; let outsideSnapshot: Data
    let parent: PrivateStateParentCapability

    init(kind: Kind) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("state-matrix-\(UUID())")
        state = root.appendingPathComponent("Pearcleaner/ProjectScanner")
        outside = root.deletingLastPathComponent().appendingPathComponent("state-matrix-outside-\(UUID())")
        outsideSnapshot = Data("outside-matrix-unchanged".utf8)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try outsideSnapshot.write(to: outside)
        if kind != .empty {
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            FileManager.default.createFile(atPath: state.appendingPathComponent(".state.lock").path, contents: Data(), attributes: [.posixPermissions: 0o600])
        }
        if kind == .staging {
            FileManager.default.createFile(atPath: state.appendingPathComponent(".state-55555555-5555-4555-8555-555555555555.tmp").path, contents: Data("recover".utf8), attributes: [.posixPermissions: 0o600])
        }
        parent = try PrivateStateParentCapability.open(applicationSupportURL: root)
    }

    func makeStore(operations: any StateFileSystemOperations) async throws -> ProjectStateStore {
        try await ProjectStateStore(parent: parent, keyCoordinator: ProjectKeyCoordinator(store: ScriptedKeyStore()), uuid: ScriptedUUID([UUID()]), operations: operations, backupOperations: SystemBackupExclusionOperations())
    }
    func remove() { parent.close(); try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
}
