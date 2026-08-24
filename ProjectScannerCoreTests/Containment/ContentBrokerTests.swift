import Foundation
import XCTest
@testable import ProjectScannerCore

final class ContentBrokerTests: XCTestCase {
    func testReadsARegularCandidateInBoundedChunks() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let expected = patternedData(count: 64 * 1_024 + 17)
        let (broker, candidates) = try await brokerAndCandidates(
            fixture,
            files: [("source", expected)]
        )

        let admission = await broker.makeContentBroker().read(candidates["source"]!, for: .secretInspection)

        guard case let .admitted(lease) = admission else {
            return XCTFail("Expected bounded regular-file admission, got \(admission)")
        }
        XCTAssertEqual(lease.byteCount, UInt64(expected.count))
        let received = try lease.withBytes(for: .secretInspection) { Data($0) }
        XCTAssertEqual(received, expected)
    }

    func testPerDetectorLimitSkipsWholeFileWithoutSampling() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let limits = try ScanLimitOverrides(secretFileBytes: 4).applying(to: .defaults)
        let (broker, candidates) = try await brokerAndCandidates(
            fixture,
            files: [("source", Data("12345".utf8))],
            limits: limits
        )

        let admission = await broker.makeContentBroker().read(candidates["source"]!, for: .secretInspection)

        assertSkipped(admission, reason: .ordinaryFileTooLarge, bytes: 5)
    }

    func testPurposeSelectsValidatedConfiguredLimitWithoutCallerOverride() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let limits = try ScanLimitOverrides(
            secretFileBytes: 4,
            lockfileBytes: 8,
            manifestBytes: 3
        ).applying(to: .defaults)
        let (broker, candidates) = try await brokerAndCandidates(
            fixture,
            files: [("candidate", Data("12345".utf8))],
            limits: limits
        )
        let content = broker.makeContentBroker()

        assertSkipped(
            await content.read(candidates["candidate"]!, for: .secretInspection),
            reason: .ordinaryFileTooLarge,
            bytes: 5
        )
        assertSkipped(
            await content.read(candidates["candidate"]!, for: .packageManifestParsing),
            reason: .manifestTooLarge,
            bytes: 5
        )
        guard case .admitted = await content.read(candidates["candidate"]!, for: .nodeLockfileParsing) else {
            return XCTFail("The validated lockfile allowance should admit five bytes")
        }
    }

    func testTwentyMiBLockfileLeaseCannotExposeBytesForSecretInspection() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let byteCount = 20 * 1_024 * 1_024
        let (broker, candidates) = try await brokerAndCandidates(
            fixture,
            files: [("package-lock.json", Data(repeating: 0x61, count: byteCount))]
        )

        let admission = await broker.makeContentBroker().read(
            candidates["package-lock.json"]!,
            for: .nodeLockfileParsing
        )

        guard case let .admitted(lease) = admission else {
            return XCTFail("Expected lockfile admission")
        }
        XCTAssertEqual(try lease.withBytes(for: .nodeLockfileParsing) { $0.count }, byteCount)
        XCTAssertThrowsError(try lease.withBytes(for: .secretInspection) { _ in XCTFail("Unauthorized bytes escaped") }) {
            XCTAssertEqual($0 as? ContentReadError, .purposeTooLarge(.ordinaryFileTooLarge))
        }
    }

    func testGlobalInputLimitStopsAtTheBoundary() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let limits = try ScanLimitOverrides(inputBytes: 6).applying(to: .defaults)
        let (broker, candidates) = try await brokerAndCandidates(
            fixture,
            files: [("one", Data("123".utf8)), ("two", Data("456".utf8)), ("three", Data("7".utf8))],
            limits: limits
        )
        let content = broker.makeContentBroker()

        guard case .admitted = await content.read(candidates["one"]!, for: .secretInspection) else {
            return XCTFail("Expected first boundary admission")
        }
        guard case .admitted = await content.read(candidates["two"]!, for: .secretInspection) else {
            return XCTFail("Expected exact boundary admission")
        }
        assertSkipped(
            await content.read(candidates["three"]!, for: .secretInspection),
            reason: .globalByteBudget,
            bytes: 1
        )
    }

    func testPreAdmissionFailuresConsumeNeitherInputNorRetainedBudget() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let limits = try ScanLimitOverrides(secretFileBytes: 2, inputBytes: 4).applying(to: .defaults)
        let (broker, candidates) = try await brokerAndCandidates(
            fixture,
            files: [
                ("oversized", Data("123".utf8)),
                ("replaced", Data("12".utf8)),
                ("first", Data("ab".utf8)),
                ("second", Data("cd".utf8)),
            ],
            limits: limits
        )
        let content = broker.makeContentBroker()
        assertSkipped(
            await content.read(candidates["oversized"]!, for: .secretInspection),
            reason: .ordinaryFileTooLarge,
            bytes: 3
        )
        try fixture.replaceRegularFile(
            at: fixture.url.appendingPathComponent("replaced"),
            contents: Data("zz".utf8)
        )
        assertSkipped(
            await content.read(candidates["replaced"]!, for: .secretInspection),
            reason: .identityChanged,
            bytes: 2
        )
        guard case .admitted = await content.read(candidates["first"]!, for: .secretInspection),
              case .admitted = await content.read(candidates["second"]!, for: .secretInspection) else {
            return XCTFail("Pre-admission failures consumed the four-byte allowance")
        }
    }

    func testConcurrentReservationsNeverExceedInputOrRetainedLimits() async throws {
        let inputLimits = try ScanLimitOverrides(inputBytes: 100 * 1_024 * 1_024).applying(to: .defaults)
        let inputBudget = InputBudget(limits: inputLimits)
        let inputLeases = await committedReservations(
            count: 8,
            bytes: 25 * 1_024 * 1_024,
            budget: inputBudget
        )
        XCTAssertEqual(inputLeases.count, 4)

        let retainedBudget = InputBudget(limits: .defaults)
        let retainedLeases = await committedReservations(
            count: 6,
            bytes: 50 * 1_024 * 1_024,
            budget: retainedBudget
        )
        XCTAssertEqual(retainedLeases.count, 5)
        withExtendedLifetime((inputLeases, retainedLeases)) {}
    }

    func testMultipleContentBrokersFromOneFileBrokerShareOneSessionBudget() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let limits = try ScanLimitOverrides(inputBytes: 4).applying(to: .defaults)
        let (broker, candidates) = try await brokerAndCandidates(
            fixture,
            files: [("source", Data("1234".utf8))],
            limits: limits
        )

        guard case .admitted = await broker.makeContentBroker().read(candidates["source"]!, for: .secretInspection) else {
            return XCTFail("Expected first broker admission")
        }
        assertSkipped(
            await broker.makeContentBroker().read(candidates["source"]!, for: .secretInspection),
            reason: .globalByteBudget,
            bytes: 4
        )
    }

    func testLogicalHardlinkPathsAreChargedSeparately() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let original = try fixture.regularFile(named: "original", contents: Data("same".utf8))
        try fixture.hardLink(from: original, to: fixture.url.appendingPathComponent("linked"))
        let limits = try ScanLimitOverrides(inputBytes: 4).applying(to: .defaults)
        let (broker, candidates) = try await existingBrokerAndCandidates(fixture, limits: limits)
        let content = broker.makeContentBroker()

        guard case .admitted = await content.read(candidates["original"]!, for: .secretInspection) else {
            return XCTFail("Expected original hardlink path admission")
        }
        assertSkipped(
            await content.read(candidates["linked"]!, for: .secretInspection),
            reason: .globalByteBudget,
            bytes: 4
        )
    }

    func testOneLeaseSharedAcrossDetectorPassesIsChargedOnce() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let limits = try ScanLimitOverrides(secretFileBytes: 4, lockfileBytes: 4, inputBytes: 4)
            .applying(to: .defaults)
        let (broker, candidates) = try await brokerAndCandidates(
            fixture,
            files: [("source", Data("same".utf8))],
            limits: limits
        )
        let content = broker.makeContentBroker()

        guard case let .admitted(lease) = await content.read(candidates["source"]!, for: .nodeLockfileParsing) else {
            return XCTFail("Expected shared lease")
        }
        XCTAssertEqual(try lease.withBytes(for: .nodeLockfileParsing) { $0.count }, 4)
        XCTAssertEqual(try lease.withBytes(for: .secretInspection) { $0.count }, 4)
        assertSkipped(
            await content.read(candidates["source"]!, for: .nodeLockfileParsing),
            reason: .globalByteBudget,
            bytes: 4
        )
    }

    func testRetainedInputBudgetReleasesWhenLeaseDeinitializes() throws {
        let budget = InputBudget(limits: .defaults)
        var leases: [RetainedBudgetLease] = []
        for _ in 0..<5 {
            leases.append(try budget.reserve(
                admittedFileBytes: 50 * 1_024 * 1_024,
                for: .nodeLockfileParsing
            ).commit())
        }
        XCTAssertThrowsError(try budget.reserve(
            admittedFileBytes: 50 * 1_024 * 1_024,
            for: .nodeLockfileParsing
        )) {
            XCTAssertEqual($0 as? ContentReadError, .globalByteBudget)
        }

        leases.removeFirst()

        let releasedAdmission = try budget.reserve(
            admittedFileBytes: 50 * 1_024 * 1_024,
            for: .nodeLockfileParsing
        ).commit()
        withExtendedLifetime((leases, releasedAdmission)) {}
    }

    func testCancelledReservationCommitReturnsClosedAndCannotMintLease() throws {
        let budget = InputBudget(limits: .defaults)
        let reservation = try budget.reserve(
            admittedFileBytes: 50 * 1_024 * 1_024,
            for: .nodeLockfileParsing
        )

        reservation.cancel()
        reservation.cancel()

        XCTAssertThrowsError(try reservation.commit()) {
            XCTAssertEqual($0 as? ContentReadError, .reservationClosed)
        }
        XCTAssertThrowsError(try reservation.commit()) {
            XCTAssertEqual($0 as? ContentReadError, .reservationClosed)
        }
        let leases = try fillRetainedCapacity(budget)
        XCTAssertEqual(leases.count, 5)
        withExtendedLifetime(leases) {}
    }

    func testCommitWinnerIsIdempotentOnlyWhileTransferredLeaseLives() throws {
        let budget = InputBudget(limits: .defaults)
        let reservation = try budget.reserve(
            admittedFileBytes: 50 * 1_024 * 1_024,
            for: .nodeLockfileParsing
        )
        var first: RetainedBudgetLease? = try reservation.commit()

        var repeated: RetainedBudgetLease? = try reservation.commit()
        XCTAssertTrue(first === repeated)
        reservation.cancel()
        reservation.cancel()
        first = nil
        repeated = nil

        XCTAssertThrowsError(try reservation.commit()) {
            XCTAssertEqual($0 as? ContentReadError, .reservationClosed)
        }
    }

    func testConcurrentCommitAndCancelOnSameReservationHasOneStableWinner() async throws {
        let budget = InputBudget(limits: .defaults)
        let reservation = try budget.reserve(
            admittedFileBytes: 50 * 1_024 * 1_024,
            for: .nodeLockfileParsing
        )
        let gate = ReservationRaceGate(participants: 2)
        var winners = await withTaskGroup(
            of: RetainedBudgetLease?.self,
            returning: [RetainedBudgetLease].self
        ) { group in
            group.addTask {
                await gate.arriveAndWait()
                return try? reservation.commit()
            }
            group.addTask {
                await gate.arriveAndWait()
                reservation.cancel()
                return nil
            }
            var leases: [RetainedBudgetLease] = []
            for await lease in group {
                if let lease { leases.append(lease) }
            }
            return leases
        }

        XCTAssertLessThanOrEqual(winners.count, 1)
        if let winner = winners.first {
            XCTAssertTrue(try reservation.commit() === winner)
        } else {
            XCTAssertThrowsError(try reservation.commit()) {
                XCTAssertEqual($0 as? ContentReadError, .reservationClosed)
            }
        }
        reservation.cancel()
        reservation.cancel()
        winners.removeAll(keepingCapacity: false)

        let capacityLeases = try fillRetainedCapacity(budget)
        XCTAssertEqual(capacityLeases.count, 5)
        withExtendedLifetime(capacityLeases) {}
    }

    func testPendingReservationDeinitRollsBackInputAndRetainedCounters() throws {
        let limits = try ScanLimitOverrides(inputBytes: 50 * 1_024 * 1_024).applying(to: .defaults)
        let budget = InputBudget(limits: limits)
        do {
            _ = try budget.reserve(
                admittedFileBytes: 50 * 1_024 * 1_024,
                for: .nodeLockfileParsing
            )
        }

        let lease = try budget.reserve(
            admittedFileBytes: 50 * 1_024 * 1_024,
            for: .nodeLockfileParsing
        ).commit()
        withExtendedLifetime(lease) {}
    }

    func testCommittedReservationDoesNotRetainTransferredLease() throws {
        let budget = InputBudget(limits: .defaults)
        let reservation = try budget.reserve(
            admittedFileBytes: 50 * 1_024 * 1_024,
            for: .nodeLockfileParsing
        )
        var transferred: RetainedBudgetLease? = try reservation.commit()
        weak let released = transferred

        transferred = nil

        XCTAssertNil(released)
        let leases = try fillRetainedCapacity(budget)
        XCTAssertEqual(leases.count, 5)
        withExtendedLifetime((reservation, leases)) {}
    }

    func testGlobalBudgetPrecedesPurposeLimitWhenBothReject() throws {
        let limits = try ScanLimitOverrides(secretFileBytes: 4, inputBytes: 4).applying(to: .defaults)
        let exhaustedBudget = InputBudget(limits: limits)
        let admitted = try exhaustedBudget.reserve(
            admittedFileBytes: 4,
            for: .secretInspection
        ).commit()

        XCTAssertThrowsError(try exhaustedBudget.reserve(
            admittedFileBytes: 5,
            for: .secretInspection
        )) {
            XCTAssertEqual($0 as? ContentReadError, .globalByteBudget)
        }

        let retainedBudget = InputBudget(limits: .defaults)
        let retainedLeases = try fillRetainedCapacity(retainedBudget)
        XCTAssertThrowsError(try retainedBudget.reserve(
            admittedFileBytes: 10 * 1_024 * 1_024,
            for: .packageManifestParsing
        )) {
            XCTAssertEqual($0 as? ContentReadError, .globalByteBudget)
        }

        let purposeOnlyLimits = try ScanLimitOverrides(secretFileBytes: 4, inputBytes: 6)
            .applying(to: .defaults)
        let freshBudget = InputBudget(limits: purposeOnlyLimits)
        XCTAssertThrowsError(try freshBudget.reserve(
            admittedFileBytes: 5,
            for: .secretInspection
        )) {
            XCTAssertEqual($0 as? ContentReadError, .purposeTooLarge(.ordinaryFileTooLarge))
        }
        withExtendedLifetime((admitted, retainedLeases)) {}
    }

    func testReplacementBeforeReadReturnsIdentityChanged() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let file = try fixture.regularFile(named: "candidate", contents: Data("old".utf8))
        let (broker, candidates) = try await existingBrokerAndCandidates(fixture)
        try fixture.replaceRegularFile(at: file, contents: Data("new".utf8))

        assertSkipped(
            await broker.makeContentBroker().read(candidates["candidate"]!, for: .secretInspection),
            reason: .identityChanged,
            bytes: 3
        )
    }

    func testReplacementByFIFOBeforeContentReopenReturnsPromptlyWithoutReading() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let file = try fixture.regularFile(named: "candidate", contents: Data("old".utf8))
        let (broker, candidates) = try await existingBrokerAndCandidates(fixture)
        try fixture.replaceWithFIFO(at: file)
        let clock = ContinuousClock()
        let start = clock.now

        let admission = await broker.makeContentBroker().read(candidates["candidate"]!, for: .secretInspection)

        XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(500))
        assertSkipped(admission, reason: .identityChanged, bytes: 3)
    }

    func testMutationOrTruncationDuringReadDiscardsAllBytes() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let file = try fixture.regularFile(named: "candidate", contents: patternedData(count: 128 * 1_024))
        let (broker, candidates) = try await existingBrokerAndCandidates(fixture)
        guard await requireOperationalRead(broker, candidate: candidates["candidate"]!) else { return }
        let control = ContentBrokerTestControl(.pauseAfterFirstChunk)
        let read = Task {
            await broker.makeContentBroker(testControl: control)
                .read(candidates["candidate"]!, for: .secretInspection)
        }
        await control.waitUntilFirstChunkRead()
        try fixture.overwriteRegularFile(at: file, contents: Data("short".utf8))
        await control.resumeAfterFirstChunk()

        assertSkipped(await read.value, reason: .identityChanged, bytes: 128 * 1_024)
    }

    func testEqualSizeMutationWithRestoredMTimeStillFailsCTimeCheck() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let original = patternedData(count: 128 * 1_024)
        let file = try fixture.regularFile(named: "candidate", contents: original)
        let originalIdentity = try fixture.identity(of: file, followLinks: true)
        let (broker, candidates) = try await existingBrokerAndCandidates(fixture)
        guard await requireOperationalRead(broker, candidate: candidates["candidate"]!) else { return }
        let control = ContentBrokerTestControl(.pauseAfterFirstChunk)
        let read = Task {
            await broker.makeContentBroker(testControl: control)
                .read(candidates["candidate"]!, for: .secretInspection)
        }
        await control.waitUntilFirstChunkRead()
        try fixture.overwriteRegularFile(at: file, contents: Data(repeating: 0x7A, count: original.count))
        try fixture.restoreModificationTime(of: file, to: originalIdentity)
        await control.resumeAfterFirstChunk()

        assertSkipped(await read.value, reason: .identityChanged, bytes: UInt64(original.count))
    }

    func testCancellationDiscardsPartialBuffer() async throws {
        let (read, control) = try await cancellableRead()
        read.cancel()
        await control.resumeAfterFirstChunk()

        assertSkipped(await read.value, reason: .cancelled, bytes: 128 * 1_024)
    }

    func testCancellationCompletesWithinFiveHundredMilliseconds() async throws {
        let (read, control) = try await cancellableRead()
        let clock = ContinuousClock()
        let start = clock.now
        read.cancel()
        await control.resumeAfterFirstChunk()

        let admission = await read.value

        XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(500))
        assertSkipped(admission, reason: .cancelled, bytes: 128 * 1_024)
    }

    func testReadErrorsExposeOnlySanitizedCodes() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let (broker, candidates) = try await brokerAndCandidates(
            fixture,
            files: [("candidate", patternedData(count: 128 * 1_024))]
        )
        let control = ContentBrokerTestControl(.failRead(chunk: 2))

        let admission = await broker.makeContentBroker(testControl: control)
            .read(candidates["candidate"]!, for: .secretInspection)

        assertSkipped(admission, reason: .unreadable, bytes: 128 * 1_024)
    }

    func testContentBrokerNeverWritesTheCandidate() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        _ = try fixture.regularFile(named: "candidate", contents: patternedData(count: 70 * 1_024))
        let before = try fixture.snapshot()
        let (broker, candidates) = try await existingBrokerAndCandidates(fixture)

        guard case .admitted = await broker.makeContentBroker()
            .read(candidates["candidate"]!, for: .secretInspection) else {
            return XCTFail("Expected read-only admission")
        }

        XCTAssertEqual(try fixture.snapshot(), before)
    }
}

private extension ContentBrokerTests {
    func brokerAndCandidates(
        _ fixture: TemporaryProjectFixture,
        files: [(String, Data)],
        limits: ScanLimits = .defaults
    ) async throws -> (FileBroker, [String: FileCandidate]) {
        for (name, contents) in files {
            _ = try fixture.regularFile(named: name, contents: contents)
        }
        return try await existingBrokerAndCandidates(fixture, limits: limits)
    }

    func existingBrokerAndCandidates(
        _ fixture: TemporaryProjectFixture,
        limits: ScanLimits = .defaults
    ) async throws -> (FileBroker, [String: FileCandidate]) {
        let capability = try RootCapability.open(selectedURL: fixture.url)
        let broker = try capability.makeFileBroker(limits: limits)
        let traversal = try await broker.makeTraversal()
        var candidates: [String: FileCandidate] = [:]
        while let event = try await traversal.next() {
            if case let .candidate(candidate) = event {
                candidates[candidate.logicalPath.escapedForDisplay().text] = candidate
            }
        }
        return (broker, candidates)
    }

    func assertSkipped(
        _ admission: ContentAdmission,
        reason expectedReason: CoverageReasonCode,
        bytes expectedBytes: UInt64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .skipped(reason, bytes) = admission else {
            return XCTFail("Expected skip, got \(admission)", file: file, line: line)
        }
        XCTAssertEqual(reason, expectedReason, file: file, line: line)
        XCTAssertEqual(bytes, expectedBytes, file: file, line: line)
    }

    func committedReservations(
        count: Int,
        bytes: UInt64,
        budget: InputBudget
    ) async -> [RetainedBudgetLease] {
        await withTaskGroup(of: RetainedBudgetLease?.self, returning: [RetainedBudgetLease].self) { group in
            for _ in 0..<count {
                group.addTask {
                    try? budget.reserve(admittedFileBytes: bytes, for: .nodeLockfileParsing).commit()
                }
            }
            var leases: [RetainedBudgetLease] = []
            for await lease in group {
                if let lease { leases.append(lease) }
            }
            return leases
        }
    }

    func fillRetainedCapacity(_ budget: InputBudget) throws -> [RetainedBudgetLease] {
        try (0..<5).map { _ in
            try budget.reserve(
                admittedFileBytes: 50 * 1_024 * 1_024,
                for: .nodeLockfileParsing
            ).commit()
        }
    }

    func requireOperationalRead(_ broker: FileBroker, candidate: FileCandidate) async -> Bool {
        guard case .admitted = await broker.makeContentBroker().read(candidate, for: .secretInspection) else {
            XCTFail("Content scaffold did not perform the prerequisite read")
            return false
        }
        return true
    }

    func cancellableRead() async throws -> (Task<ContentAdmission, Never>, ContentBrokerTestControl) {
        let fixture = try TemporaryProjectFixture()
        _ = try fixture.regularFile(named: "candidate", contents: patternedData(count: 128 * 1_024))
        let (broker, candidates) = try await existingBrokerAndCandidates(fixture)
        guard await requireOperationalRead(broker, candidate: candidates["candidate"]!) else {
            fixture.remove()
            return (
                Task { .skipped(reason: .unreadable, bytes: 128 * 1_024) },
                ContentBrokerTestControl(.pauseAfterFirstChunk)
            )
        }
        let control = ContentBrokerTestControl(.pauseAfterFirstChunk)
        let read = Task { [fixture] in
            defer { fixture.remove() }
            return await broker.makeContentBroker(testControl: control)
                .read(candidates["candidate"]!, for: .secretInspection)
        }
        await control.waitUntilFirstChunkRead()
        return (read, control)
    }
}

private func patternedData(count: Int) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0) })
}

private actor ReservationRaceGate {
    private let participants: Int
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(participants: Int) {
        precondition(participants > 0)
        self.participants = participants
    }

    func arriveAndWait() async {
        arrivals += 1
        if arrivals == participants {
            waiters.forEach { $0.resume() }
            waiters.removeAll(keepingCapacity: false)
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
