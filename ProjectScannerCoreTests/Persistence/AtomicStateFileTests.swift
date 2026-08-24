import Darwin
import Foundation
import XCTest
@testable import ProjectScannerCore

final class AtomicStateFileTests: XCTestCase {
    func testStateDirectoryIsMode0700AndFileIsMode0600() async throws {
        let fixture = try await StateStoreFixture.make(); defer { fixture.remove() }
        _ = try await fixture.register()
        XCTAssertEqual(try modeBits(fixture.stateDirectory), 0o700)
        XCTAssertEqual(try modeBits(fixture.stateFile), 0o600)
    }

    func testExistingOwnerControlled0755PearcleanerParentAllows0700ScannerChild() async throws {
        let fixture = try await StateStoreFixture.make { parent in
            try FileManager.default.createDirectory(at: parent.appendingPathComponent("Pearcleaner"), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        }; defer { fixture.remove() }
        _ = try await fixture.register()
        XCTAssertEqual(try modeBits(fixture.parentURL.appendingPathComponent("Pearcleaner")), 0o755)
        XCTAssertEqual(try modeBits(fixture.stateDirectory), 0o700)
    }

    func testGroupOrWorldWritablePearcleanerParentIsRejected() async throws {
        for mode in [0o720, 0o702] {
            do {
                let fixture = try await StateStoreFixture.make { parent in
                    let shared = parent.appendingPathComponent("Pearcleaner")
                    try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: false, attributes: [.posixPermissions: mode])
                    _ = chmod(shared.path, mode_t(mode))
                }
                defer { fixture.remove() }
                _ = try await fixture.register()
                XCTFail("Writable shared directory was accepted")
            } catch { XCTAssertEqual(error as? ProjectStateError, .stateUnavailable) }
        }
    }

    func testSymlinkedPearcleanerParentCannotRedirectStateToOutsideCanary() async throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID())")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        do {
            let fixture = try await StateStoreFixture.make { parent in
                try FileManager.default.createSymbolicLink(at: parent.appendingPathComponent("Pearcleaner"), withDestinationURL: outside)
            }
            defer { fixture.remove() }
            _ = try await fixture.register()
            XCTFail("Symlinked shared directory was accepted")
        } catch { XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), []) }
    }

    func testFirstUseFsyncsEachNewDirectoryBeforeItsParent() async throws {
        let operations = ScriptedStateFileSystemOperations()
        let fixture = try await StateStoreFixture.make(operations: operations); defer { fixture.remove() }
        let events = operations.snapshot()
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: .syncNewSharedDirectory)), try XCTUnwrap(events.firstIndex(of: .syncParentAfterSharedDirectory)))
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: .syncNewScannerDirectory)), try XCTUnwrap(events.firstIndex(of: .syncSharedAfterScannerDirectory)))
        XCTAssertEqual(
            operations.syncSnapshot(),
            [
                .init(site: .syncNewSharedDirectory, role: .sharedDirectory),
                .init(site: .syncParentAfterSharedDirectory, role: .privateStateParent),
                .init(site: .syncNewScannerDirectory, role: .scannerDirectory),
                .init(site: .syncSharedAfterScannerDirectory, role: .sharedDirectory),
                .init(site: .syncNewLockFile, role: .transactionLock),
                .init(site: .syncScannerAfterLockFile, role: .scannerDirectory),
            ],
            "Fresh initialization must fsync each actual produced descriptor in durability order"
        )
    }

    func testFirstUseFsyncsNewLockFileBeforeScannerDirectory() async throws {
        let operations = ScriptedStateFileSystemOperations()
        let fixture = try await StateStoreFixture.make(operations: operations); defer { fixture.remove() }
        let events = operations.snapshot()
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: .syncNewLockFile)), try XCTUnwrap(events.firstIndex(of: .syncScannerAfterLockFile)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.stateDirectory.appendingPathComponent(".state.lock").path))
    }

    func testPreRenameAtomicWriteFailureLeavesPriorFileReadableAndUnchanged() async throws {
        let fixture = try await StateStoreFixture.make(); defer { fixture.remove() }
        _ = try await fixture.register(label: "before")
        let original = try Data(contentsOf: fixture.stateFile)
        let operations = ScriptedStateFileSystemOperations(failingSite: .syncStagingFile, failure: .failBefore(EIO))
        let second = try await ProjectStateStore(parent: fixture.parent, keyCoordinator: fixture.coordinator, uuid: ScriptedUUID([UUID()]), operations: operations, backupOperations: SystemBackupExclusionOperations())
        await XCTAssertThrowsProjectState(.stateUnavailable) { _ = try await second.recordAttempt(projectID: ProjectID(rawValue: fixture.projectUUID), coverage: nonCompleteCoverage(.partial), finishedAt: Date(timeIntervalSince1970: 1), metadata: try AttemptSummaryMetadata(advisoryCacheSchemaVersion: nil, advisory: nil), lease: fixture.lease) }
        XCTAssertEqual(try Data(contentsOf: fixture.stateFile), original)
    }

    func testPostRenameDirectorySyncFailureReportsDurabilityUncertainWithNewFileVisible() async throws {
        let operations = ScriptedStateFileSystemOperations(failingSite: .syncScannerAfterRename, failure: .failAfterSuccess(EIO))
        let fixture = try await StateStoreFixture.make(operations: operations); defer { fixture.remove() }
        let registration = try await fixture.register(label: "visible-after-rename")
        XCTAssertEqual(registration.commit, .committedDurabilityUncertain)
        let loaded = try await fixture.store.loadSummary(projectID: registration.projectID)
        XCTAssertEqual(loaded?.label, "visible-after-rename")
    }

    func testDestinationSymlinkIsReplacedWithoutTouchingOutsideCanary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("atomic-symlink-\(UUID())")
        let outside = root.deletingLastPathComponent().appendingPathComponent("atomic-symlink-outside-\(UUID())")
        let outsideSnapshot = Data("outside-unchanged".utf8)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try outsideSnapshot.write(to: outside)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let parent = try PrivateStateParentCapability.open(applicationSupportURL: root)
        defer { parent.close() }
        let atomic = try AtomicStateFile.open(
            parent: parent, operations: SystemStateFileSystemOperations(),
            backupOperations: SystemBackupExclusionOperations()
        )
        defer { atomic.close() }
        let destinationName = "project-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.json"
        let destination = root.appendingPathComponent("Pearcleaner/ProjectScanner/\(destinationName)")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: outside)
        let replacement = Data("new-whole-envelope".utf8)
        XCTAssertEqual(
            try atomic.write(data: replacement, destinationName: destinationName, stagingUUID: UUID()),
            .committed
        )
        XCTAssertEqual(try Data(contentsOf: outside), outsideSnapshot)
        XCTAssertEqual(try Data(contentsOf: destination), replacement)
        var status = stat()
        XCTAssertEqual(lstat(destination.path, &status), 0)
        XCTAssertEqual(status.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(status.st_mode & 0o7777, 0o600)
    }

    func testStateFileReplacedByFIFOFailsPromptlyWithoutBlocking() async throws {
        let fixture = try await StateStoreFixture.make(); defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.stateDirectory, withIntermediateDirectories: true)
        _ = mkfifo(fixture.stateFile.path, 0o600)
        let started = ContinuousClock.now
        await XCTAssertThrowsProjectState(.invalidState) { try await fixture.store.loadSummary(projectID: ProjectID(rawValue: fixture.projectUUID)) }
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
    }

    func testLockFileReplacedBySpecialFileFailsPromptlyWithoutBlocking() async throws {
        let fifoFixture = try await StateStoreFixture.make(); defer { fifoFixture.remove() }
        let lock = fifoFixture.stateDirectory.appendingPathComponent(".state.lock")
        try? FileManager.default.removeItem(at: lock); _ = mkfifo(lock.path, 0o600)
        let started = ContinuousClock.now
        await XCTAssertThrowsProjectState(.stateUnavailable) { _ = try await fifoFixture.register() }
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))

        let regularFixture = try await StateStoreFixture.make(projectUUID: UUID()); defer { regularFixture.remove() }
        let regularLock = regularFixture.stateDirectory.appendingPathComponent(".state.lock")
        try? FileManager.default.removeItem(at: regularLock)
        FileManager.default.createFile(atPath: regularLock.path, contents: Data("replacement".utf8), attributes: [.posixPermissions: 0o600])
        await XCTAssertThrowsProjectState(.stateUnavailable) { _ = try await regularFixture.register() }
    }

    func testCrashLeftStagingFilesAreCleanedOnlyUnderTheTransactionLock() async throws {
        let operations = ScriptedStateFileSystemOperations()
        let fixture = try await StateStoreFixture.make(operations: operations) { parent in
            let state = parent.appendingPathComponent("Pearcleaner/ProjectScanner")
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            FileManager.default.createFile(atPath: state.appendingPathComponent(".state-33333333-3333-4333-8333-333333333333.tmp").path, contents: Data("stale".utf8), attributes: [.posixPermissions: 0o600])
        }; defer { fixture.remove() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stateDirectory.appendingPathComponent(".state-33333333-3333-4333-8333-333333333333.tmp").path))
        let events = operations.snapshot()
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: .acquireTransactionLock)), try XCTUnwrap(events.firstIndex(of: .unlinkRecoveredStagingEntry)))
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: .unlinkRecoveredStagingEntry)), try XCTUnwrap(events.firstIndex(of: .releaseTransactionLock)))
    }

    func testMoreThanOneHundredTwentyEightStagingFilesFailsClosed() async throws {
        let atMatchLimit = try await preparedStateAttempt(matchCount: 128, totalEntries: 4_096, invalidateLaterCandidate: false)
        defer { atMatchLimit.remove() }
        if case .failure(let error) = atMatchLimit.result {
            XCTFail("The exact staging bounds must initialize successfully: \(error)")
            return
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: atMatchLimit.state.path).filter { $0.hasPrefix(".state-") && $0.hasSuffix(".tmp") }, [])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: atMatchLimit.state.path).filter { !$0.hasPrefix(".state-") }), Set(atMatchLimit.initialNames.filter { !$0.hasPrefix(".state-") }))

        let tooManyMatches = try await preparedStateAttempt(matchCount: 129, totalEntries: 130, invalidateLaterCandidate: false)
        defer { tooManyMatches.remove() }
        XCTAssertThrowsError(try tooManyMatches.result.get()) { XCTAssertEqual($0 as? ProjectStateError, .stateUnavailable) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tooManyMatches.state.path).filter { $0.hasPrefix(".state-") }.count, 129)

        let tooManyEntries = try await preparedStateAttempt(matchCount: 128, totalEntries: 4_097, invalidateLaterCandidate: false)
        defer { tooManyEntries.remove() }
        XCTAssertThrowsError(try tooManyEntries.result.get()) { XCTAssertEqual($0 as? ProjectStateError, .stateUnavailable) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tooManyEntries.state.path).filter { $0.hasPrefix(".state-") }.count, 128)

        let invalidLater = try await preparedStateAttempt(matchCount: 8, totalEntries: 9, invalidateLaterCandidate: true)
        defer { invalidLater.remove() }
        XCTAssertThrowsError(try invalidLater.result.get())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: invalidLater.state.path).filter { $0.hasPrefix(".state-") }.count, 8, "Any unlink before complete validation violates all-or-none cleanup")

        var rawAccumulator = StateStagingEntryAccumulator()
        for index in 0..<4_096 {
            try rawAccumulator.consume(Array("unrelated-\(index)".utf8))
        }
        XCTAssertThrowsError(try rawAccumulator.consume([0xFF])) {
            XCTAssertEqual($0 as? ProjectStateError, .stateUnavailable)
        }

        let multibyteName = ".state-" + String(repeating: "é", count: 18) + ".tmp"
        XCTAssertEqual(multibyteName.utf8.count, 47)
        XCTAssertFalse(isStagingName(multibyteName))
        let multibyte = try await preparedStateAttempt(
            matchCount: 0, totalEntries: 1,
            invalidateLaterCandidate: false, additionalName: multibyteName
        )
        defer { multibyte.remove() }
        if case .failure(let error) = multibyte.result {
            XCTFail("A 47-byte non-ASCII non-staging name must remain untouched: \(error)")
            return
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: multibyte.state.appendingPathComponent(multibyteName).path))

        let modeMutationOperations = ScriptedStateFileSystemOperations(
            mutateCurrentStagingModeBeforeReinspect: true
        )
        let modeMutation = try await preparedStateAttempt(
            matchCount: 1, totalEntries: 2,
            invalidateLaterCandidate: false, operations: modeMutationOperations
        )
        defer { modeMutation.remove() }
        XCTAssertThrowsError(try modeMutation.result.get()) {
            XCTAssertEqual($0 as? ProjectStateError, .stateUnavailable)
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: modeMutation.state.path)
                .filter { $0.hasPrefix(".state-") }.count,
            1,
            "A mode change at the immediate pre-unlink recheck must preserve the candidate"
        )

        let immediateReinspectOperations = ScriptedStateFileSystemOperations(
            mutatePriorStagingAfterNextReinspect: true
        )
        let immediateReinspect = try await preparedStateAttempt(
            matchCount: 2, totalEntries: 3,
            invalidateLaterCandidate: false, operations: immediateReinspectOperations
        )
        defer { immediateReinspect.remove() }
        if case .failure(let error) = immediateReinspect.result {
            XCTFail("Immediate per-candidate reinspection should clean valid staging files: \(error)")
            return
        }
        XCTAssertFalse(
            immediateReinspectOperations.priorStagingEntryWasMutatedBeforeUnlink(),
            "Each candidate must be unlinked immediately after its own final recheck"
        )
    }
}

private final class PreparedStateAttempt {
    let root: URL; let state: URL; let parent: PrivateStateParentCapability; let result: Result<ProjectStateStore, Error>; let initialNames: [String]
    init(root: URL, state: URL, parent: PrivateStateParentCapability, result: Result<ProjectStateStore, Error>, initialNames: [String]) { self.root = root; self.state = state; self.parent = parent; self.result = result; self.initialNames = initialNames }
    func remove() {
        parent.close()
        try? FileManager.default.removeItem(at: root)
    }
}

private func preparedStateAttempt(
    matchCount: Int,
    totalEntries: Int,
    invalidateLaterCandidate: Bool,
    additionalName: String? = nil,
    operations: any StateFileSystemOperations = SystemStateFileSystemOperations()
) async throws -> PreparedStateAttempt {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("staging-bounds-\(UUID())")
    let state = root.appendingPathComponent("Pearcleaner/ProjectScanner")
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    FileManager.default.createFile(atPath: state.appendingPathComponent(".state.lock").path, contents: Data(), attributes: [.posixPermissions: 0o600])
    for index in 0..<matchCount {
        let name = String(format: ".state-00000000-0000-4000-8000-%012d.tmp", index)
        FileManager.default.createFile(atPath: state.appendingPathComponent(name).path, contents: Data(), attributes: [.posixPermissions: 0o600])
    }
    for index in 0..<(totalEntries - matchCount - 1) { FileManager.default.createFile(atPath: state.appendingPathComponent("unrelated-\(index)").path, contents: Data()) }
    if let additionalName {
        FileManager.default.createFile(
            atPath: state.appendingPathComponent(additionalName).path,
            contents: Data(), attributes: [.posixPermissions: 0o600]
        )
    }
    if invalidateLaterCandidate {
        let observed = try rawDirectoryOrder(state).filter { $0.hasPrefix(".state-") && $0.hasSuffix(".tmp") }
        let later = try XCTUnwrap(observed.last)
        _ = chmod(state.appendingPathComponent(later).path, 0o644)
    }
    let initialNames = try FileManager.default.contentsOfDirectory(atPath: state.path)
    let parent = try PrivateStateParentCapability.open(applicationSupportURL: root)
    let result: Result<ProjectStateStore, Error>
    do { result = .success(try await ProjectStateStore(parent: parent, keyCoordinator: ProjectKeyCoordinator(store: ScriptedKeyStore()), uuid: ScriptedUUID([UUID()]), operations: operations, backupOperations: SystemBackupExclusionOperations())) }
    catch { result = .failure(error) }
    return PreparedStateAttempt(root: root, state: state, parent: parent, result: result, initialNames: initialNames)
}

private func rawDirectoryOrder(_ directory: URL) throws -> [String] {
    let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard descriptor >= 0, let stream = fdopendir(descriptor) else { if descriptor >= 0 { Darwin.close(descriptor) }; throw ProjectStateError.stateUnavailable }
    defer { closedir(stream) }
    var names: [String] = []
    while let entry = readdir(stream) {
        let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
        }
        if name != "." && name != ".." { names.append(name) }
    }
    return names
}

func XCTAssertThrowsProjectState<T>(_ expected: ProjectStateError, operation: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
    catch { XCTAssertEqual(error as? ProjectStateError, expected, file: file, line: line) }
}
