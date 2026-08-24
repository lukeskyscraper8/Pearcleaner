import Foundation
import XCTest
@testable import ProjectScannerCore

final class ProjectKeyCoordinatorTests: XCTestCase {
    func testFirstUseCreatesOnePersistentKeyAndGeneration() async throws {
        let generation = uuid(1)
        let store = ScriptedKeyStore()
        let coordinator = makeCoordinator(
            store: store,
            randomBytes: [keyBytes(0x10)],
            uuids: [generation]
        )
        let result = try await coordinator.access(for: .none)
        let lease = try readyLease(result)
        let snapshot = await store.snapshot()

        XCTAssertEqual(lease.persistence, .persistent(generation: generation))
        XCTAssertTrue(lease.permitsPersistentState)
        XCTAssertTrue(lease.permitsPersistentSuppression)
        XCTAssertEqual(keyBytes(from: lease.material), keyBytes(0x10))
        XCTAssertEqual(snapshot.calls, [.read, .create(generation: generation)])
        XCTAssertEqual(snapshot.stored?.generation, generation)
        XCTAssertEqual(snapshot.stored?.secureStorageRecord(), lease.material.secureStorageRecord())
    }

    func testConcurrentFirstUseCreatesAtMostOnePersistentKeyAndGeneration() async throws {
        let store = ScriptedKeyStore(pauseFirstRead: true)
        let coordinator = makeCoordinator(store: store, randomBytes: [keyBytes(0x11), keyBytes(0x22)])
        let first = Task { try await coordinator.access(for: .none) }
        guard await store.waitUntilFirstReadPaused(timeoutNanoseconds: 1_000_000_000) else {
            await store.resumeFirstRead()
            _ = try await first.value
            XCTFail("Timed out waiting for first read pause")
            return
        }
        let started = AsyncStartMarker()
        let second = Task {
            await started.markStarted()
            return try await coordinator.access(for: .none)
        }
        await started.waitUntilStarted()
        await Task.yield()
        await store.resumeFirstRead()

        let firstLease = try readyLease(try await first.value)
        let secondLease = try readyLease(try await second.value)
        let snapshot = await store.snapshot()
        XCTAssertEqual(
            snapshot.calls,
            [.read, .create(generation: firstLease.material.generation), .read]
        )
        XCTAssertEqual(snapshot.maximumConcurrent, 1)
        let createCallCount = await store.createCallCount()
        XCTAssertEqual(createCallCount, 1)
        XCTAssertEqual(firstLease.material.generation, secondLease.material.generation)
        XCTAssertEqual(
            firstLease.material.secureStorageRecord(),
            secondLease.material.secureStorageRecord()
        )

        let cancellationStore = ScriptedKeyStore(pauseFirstRead: true)
        let cancellationCoordinator = makeCoordinator(
            store: cancellationStore,
            randomBytes: [keyBytes(0x71), keyBytes(0x72)],
            uuids: [uuid(71), uuid(72)]
        )
        let holder = Task { try await cancellationCoordinator.access(for: .none) }
        guard await cancellationStore.waitUntilFirstReadPaused(timeoutNanoseconds: 1_000_000_000) else {
            await cancellationStore.resumeFirstRead()
            _ = try await holder.value
            XCTFail("Timed out waiting for cancellation holder read pause")
            return
        }
        let cancellationStarted = AsyncStartMarker()
        let cancelled = Task {
            await cancellationStarted.markStarted()
            return try await cancellationCoordinator.access(for: .none)
        }
        await cancellationStarted.waitUntilStarted()
        await Task.yield()
        cancelled.cancel()
        await Task.yield()
        await cancellationStore.resumeFirstRead()

        let holderLease = try readyLease(try await holder.value)
        await XCTAssertThrowsCancellation(try await cancelled.value)
        let cancellationSnapshot = await cancellationStore.snapshot()
        XCTAssertEqual(
            cancellationSnapshot.calls,
            [.read, .create(generation: holderLease.material.generation)]
        )
        let cancellationCreateCount = await cancellationStore.createCallCount()
        XCTAssertEqual(cancellationCreateCount, 1)
        XCTAssertEqual(cancellationSnapshot.stored?.secureStorageRecord(), holderLease.material.secureStorageRecord())

        let postCreateStore = ScriptedKeyStore(pauseFirstCreate: true)
        let postCreateCoordinator = makeCoordinator(
            store: postCreateStore,
            randomBytes: [keyBytes(0x81), keyBytes(0x82)],
            uuids: [uuid(81), uuid(82)]
        )
        let creating = Task { try await postCreateCoordinator.access(for: .none) }
        guard await postCreateStore.waitUntilFirstCreatePaused(timeoutNanoseconds: 1_000_000_000) else {
            await postCreateStore.resumeFirstCreate()
            _ = try await creating.value
            XCTFail("Timed out waiting for post-create cancellation pause")
            return
        }
        creating.cancel()
        await Task.yield()
        await postCreateStore.resumeFirstCreate()

        await XCTAssertThrowsCancellation(try await creating.value)
        let reusedLease = try readyLease(try await postCreateCoordinator.access(for: .none))
        let expectedCommittedMaterial = try material(generation: uuid(81), bytes: keyBytes(0x81))
        let postCreateSnapshot = await postCreateStore.snapshot()
        XCTAssertEqual(
            postCreateSnapshot.calls,
            [.read, .create(generation: uuid(81)), .read]
        )
        let postCreateCount = await postCreateStore.createCallCount()
        XCTAssertEqual(postCreateCount, 1)
        XCTAssertEqual(
            postCreateSnapshot.stored?.secureStorageRecord(),
            expectedCommittedMaterial.secureStorageRecord()
        )
        XCTAssertEqual(reusedLease.material.secureStorageRecord(), expectedCommittedMaterial.secureStorageRecord())
    }

    func testExistingKeyWithoutProjectStateCanBeReused() async throws {
        let material = try material(generation: uuid(1), bytes: keyBytes(0x31))
        let coordinator = makeCoordinator(store: ScriptedKeyStore(stored: material))

        let lease = try readyLease(try await coordinator.access(for: .none))

        XCTAssertTrue(lease.permitsPersistentState)
        XCTAssertEqual(lease.material.generation, material.generation)
    }

    func testMatchingStoredAndKeychainGenerationsPermitPersistence() async throws {
        let material = try material(generation: uuid(2), bytes: keyBytes(0x32))
        let coordinator = makeCoordinator(store: ScriptedKeyStore(stored: material))

        let lease = try readyLease(try await coordinator.access(for: .generation(material.generation)))

        XCTAssertEqual(lease.persistence, .persistent(generation: material.generation))
    }

    func testTemporaryKeychainUnavailabilityReturnsEphemeralLease() async throws {
        let store = ScriptedKeyStore(reads: [.fixed(.unavailable(.interactionNotAllowed))])
        let coordinator = makeCoordinator(store: store, randomBytes: [keyBytes(0x41)])

        let lease = try readyLease(try await coordinator.access(for: .none))

        XCTAssertEqual(lease.persistence, .ephemeral)
        XCTAssertFalse(lease.permitsPersistentState)

        let createUnavailable = ScriptedKeyStore(creates: [.fixed(.unavailable(.systemFailure))])
        let createCoordinator = makeCoordinator(
            store: createUnavailable,
            randomBytes: [keyBytes(0x43)],
            uuids: [uuid(43)]
        )
        let proposalLease = try readyLease(try await createCoordinator.access(for: .none))
        let createSnapshot = await createUnavailable.snapshot()
        XCTAssertEqual(proposalLease.persistence, .ephemeral)
        XCTAssertEqual(proposalLease.material.generation, uuid(43))
        XCTAssertEqual(keyBytes(from: proposalLease.material), keyBytes(0x43))
        XCTAssertEqual(createSnapshot.calls, [.read, .create(generation: uuid(43))])
    }

    func testEphemeralLeaseCanFingerprintButReportsNoPersistentSuppressionAuthority() async throws {
        let store = ScriptedKeyStore(reads: [.fixed(.unavailable(.systemFailure))])
        let coordinator = makeCoordinator(store: store, randomBytes: [keyBytes(0x42)])
        let lease = try readyLease(try await coordinator.access(for: .none))

        XCTAssertNoThrow(try scannerFingerprint(keyMaterial: lease.material))
        XCTAssertFalse(lease.permitsPersistentSuppression)
    }

    func testMissingKeyForExistingKeyedStateRequiresReset() async throws {
        let store = ScriptedKeyStore()
        let coordinator = makeCoordinator(store: store)

        let result = try await coordinator.access(for: .generation(uuid(3)))

        XCTAssertTrue(isResetRequired(result))
    }

    func testInvalidKeychainRecordRequiresResetAndNeverCreatesOrOverwrites() async throws {
        let store = ScriptedKeyStore(reads: [.fixed(.invalidRecord)])
        let coordinator = makeCoordinator(store: store)

        let result = try await coordinator.access(for: .none)
        let snapshot = await store.snapshot()

        XCTAssertTrue(isResetRequired(result))
        XCTAssertEqual(snapshot.calls, [.read])

        let createInvalidStore = ScriptedKeyStore(creates: [.fixed(.invalidRecord)])
        let createInvalidCoordinator = makeCoordinator(store: createInvalidStore)
        let createInvalid = try await createInvalidCoordinator.access(for: .none)
        let createInvalidSnapshot = await createInvalidStore.snapshot()
        XCTAssertTrue(isResetRequired(createInvalid))
        XCTAssertEqual(
            createInvalidSnapshot.calls,
            [.read, .create(generation: uuid(100))]
        )
    }

    func testGenerationMismatchRequiresReset() async throws {
        let material = try material(generation: uuid(4), bytes: keyBytes(0x44))
        let coordinator = makeCoordinator(store: ScriptedKeyStore(stored: material))

        let result = try await coordinator.access(for: .generation(uuid(5)))

        XCTAssertTrue(isResetRequired(result))
    }

    func testMissingKeyForExistingStateNeverCallsCreate() async throws {
        let store = ScriptedKeyStore()
        let coordinator = makeCoordinator(store: store)

        _ = try await coordinator.access(for: .generation(uuid(6)))
        let snapshot = await store.snapshot()

        XCTAssertEqual(snapshot.calls, [.read])
    }

    func testDuplicateCreateLoadsAndUsesTheWinningExistingKey() async throws {
        let proposal = try material(generation: uuid(7), bytes: keyBytes(0x47))
        let winner = try material(generation: uuid(8), bytes: keyBytes(0x48))
        let store = ScriptedKeyStore(creates: [.fixed(.existing(winner))])
        let coordinator = makeCoordinator(
            store: store,
            randomBytes: [keyBytes(0x47)],
            uuids: [proposal.generation]
        )

        let lease = try readyLease(try await coordinator.access(for: .none))

        XCTAssertEqual(lease.material.generation, winner.generation)
        let returnedFingerprint = try scannerFingerprint(keyMaterial: lease.material)
        XCTAssertEqual(returnedFingerprint, try scannerFingerprint(keyMaterial: winner))
        XCTAssertNotEqual(returnedFingerprint, try scannerFingerprint(keyMaterial: proposal))
    }

    func testRevalidationImmediatelyBeforeCommitDetectsGenerationChange() async throws {
        let initial = try material(generation: uuid(9), bytes: keyBytes(0x49))
        let changed = try material(generation: uuid(10), bytes: keyBytes(0x4A))
        let store = ScriptedKeyStore(stored: initial, reads: [.current, .fixed(.found(changed))])
        let coordinator = makeCoordinator(store: store)
        let lease = try readyLease(try await coordinator.access(for: .none))

        let matchingStore = ScriptedKeyStore(stored: initial, reads: [.current, .current])
        let matchingCoordinator = makeCoordinator(store: matchingStore)
        let matchingLease = try readyLease(try await matchingCoordinator.access(for: .none))
        let matchingRevalidation = await matchingCoordinator.revalidate(matchingLease)
        XCTAssertEqual(matchingRevalidation, .valid)

        let revalidation = await coordinator.revalidate(lease)

        XCTAssertEqual(revalidation, .resetRequired)

        for read in [StoredKeyRead.missing, .invalidRecord] {
            let replacementStore = ScriptedKeyStore(stored: initial, reads: [.current, .fixed(read)])
            let replacementCoordinator = makeCoordinator(store: replacementStore)
            let replacementLease = try readyLease(
                try await replacementCoordinator.access(for: .none)
            )
            let replacementRevalidation = await replacementCoordinator.revalidate(replacementLease)
            XCTAssertEqual(replacementRevalidation, .resetRequired)
        }
    }

    func testRevalidationUnavailabilityAbortsPersistenceWithoutRequiringReset() async throws {
        let initial = try material(generation: uuid(11), bytes: keyBytes(0x4B))
        let store = ScriptedKeyStore(stored: initial, reads: [.current, .fixed(.unavailable(.interactionNotAllowed))])
        let coordinator = makeCoordinator(store: store)
        let lease = try readyLease(try await coordinator.access(for: .none))

        let revalidation = await coordinator.revalidate(lease)

        XCTAssertEqual(revalidation, .ephemeralOnly)

        let ephemeralStore = ScriptedKeyStore(reads: [.fixed(.unavailable(.systemFailure))])
        let ephemeralCoordinator = makeCoordinator(store: ephemeralStore, randomBytes: [keyBytes(0x5B)])
        let ephemeralLease = try readyLease(try await ephemeralCoordinator.access(for: .none))
        let before = await ephemeralStore.snapshot()
        let ephemeralRevalidation = await ephemeralCoordinator.revalidate(ephemeralLease)
        let after = await ephemeralStore.snapshot()
        XCTAssertEqual(ephemeralRevalidation, .ephemeralOnly)
        XCTAssertEqual(after.calls, before.calls)
    }

    func testGeneratedKeysAreExactlyThirtyTwoRandomBytes() async throws {
        for randomStep in [
            ScriptedRandomStep.failure,
            .bytes(Data(repeating: 0x51, count: 31)),
            .bytes(Data(repeating: 0x52, count: 33)),
        ] {
            let store = ScriptedKeyStore()
            let random = ScriptedRandom([randomStep])
            let uuidSource = ScriptedUUID([uuid(99)])
            let coordinator = ProjectKeyCoordinator(store: store, random: random, uuid: uuidSource)
            await XCTAssertThrowsErrorAsync(try await coordinator.access(for: .none)) { error in
                XCTAssertEqual(error as? ProjectKeyCoordinatorError, .keyGenerationFailed)
            }
            let snapshot = await store.snapshot()
            XCTAssertEqual(snapshot.calls, [.read])
            XCTAssertEqual(random.snapshotRequestedCounts(), [32])
            XCTAssertEqual(uuidSource.snapshotCallCount(), 0)
        }
        let store = ScriptedKeyStore(reads: [.fixed(.unavailable(.systemFailure))])
        let random = ScriptedRandom([.bytes(keyBytes(0x53))])
        let uuidSource = ScriptedUUID([uuid(53)])
        let coordinator = ProjectKeyCoordinator(store: store, random: random, uuid: uuidSource)
        let lease = try readyLease(try await coordinator.access(for: .none))
        XCTAssertEqual(keyBytes(from: lease.material), keyBytes(0x53))
        XCTAssertEqual(lease.material.generation, uuid(53))
        XCTAssertEqual(random.snapshotRequestedCounts(), [32])
        XCTAssertEqual(uuidSource.snapshotCallCount(), 1)
    }

    private func makeCoordinator(
        store: ScriptedKeyStore,
        randomBytes: [Data] = [keyBytes(0xA5)],
        randomSteps: [ScriptedRandomStep]? = nil,
        uuids: [UUID] = [uuid(100), uuid(101), uuid(102)]
    ) -> ProjectKeyCoordinator {
        ProjectKeyCoordinator(
            store: store,
            random: ScriptedRandom(randomSteps ?? randomBytes.map(ScriptedRandomStep.bytes)),
            uuid: ScriptedUUID(uuids)
        )
    }
}

private func readyLease(
    _ access: ProjectKeyAccess,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> ProjectKeyLease {
    guard case .ready(let lease) = access else {
        XCTFail("Expected a ready key lease", file: file, line: line)
        throw CoordinatorTestFailure()
    }
    return lease
}

private func isResetRequired(_ access: ProjectKeyAccess) -> Bool {
    if case .resetRequired = access { return true }
    return false
}

private func material(generation: UUID, bytes: Data) throws -> ProjectKeyMaterial {
    try ProjectKeyMaterial(generation: generation, keyBytes: bytes)
}

private func keyBytes(_ value: UInt8) -> Data { Data(repeating: value, count: 32) }

private func keyBytes(from material: ProjectKeyMaterial) -> Data {
    Data(material.secureStorageRecord().suffix(32))
}

private func scannerFingerprint(keyMaterial: ProjectKeyMaterial) throws -> SuppressionFingerprint {
    let path = try VerifiedRelativePath(components: [
        try VerifiedPathComponent(bytes: Data("state".utf8)),
    ])
    let vector = FramedMACTestVector(
        fixedInteger: 0x01020304,
        fixedBytes: Data([0x00, 0xFF]),
        relativePath: path
    )
    let borrowed = Data([0x10, 0x20, 0x30])
    return try borrowed.withUnsafeBytes {
        try FramedMACTestSupport.fingerprint(
            vector,
            borrowedField: $0,
            keyMaterial: keyMaterial
        )
    }
}

private func uuid(_ value: UInt8) -> UUID {
    UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
}

private struct CoordinatorTestFailure: Error {}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error")
    } catch {
        handler(error)
    }
}

private func XCTAssertThrowsCancellation<T>(
    _ expression: @autoclosure () async throws -> T
) async {
    do {
        _ = try await expression()
        XCTFail("Expected CancellationError")
    } catch is CancellationError {
        // Expected.
    } catch {
        XCTFail("Expected CancellationError, got \(error)")
    }
}
