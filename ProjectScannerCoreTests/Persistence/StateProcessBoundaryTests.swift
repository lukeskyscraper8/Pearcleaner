import Darwin
import Foundation
import XCTest
@testable import ProjectScannerCore

final class StateProcessBoundaryTests: XCTestCase {
    func testSeparateProcessLockContentionTimesOutCancelsAndRecoversAfterSIGKILL() async throws {
        let context = try ProcessHarnessContext.require(role: .lock)
        try createInitialLayout(context)
        let fixture = try await ProcessStateFixture.open(
            context: context,
            operations: SystemStateFileSystemOperations(),
            uuids: processUUIDs()
        )
        defer { fixture.close() }

        let helper = try LockHolderProcess.start(
            executable: try context.requireLockHelper(),
            lockFile: fixture.lockFile
        )
        defer { helper.stopIfNeeded() }

        let busyStarted = ContinuousClock.now
        do {
            _ = try await fixture.store.register(
                label: "must-time-out",
                bookmark: fixture.bookmark,
                limitOverrides: .init(),
                lease: fixture.lease
            )
            XCTFail("A separate process held the transaction lock")
        } catch {
            XCTAssertEqual(error as? ProjectStateError, .transactionBusy)
        }
        let busyDuration = busyStarted.duration(to: .now)
        XCTAssertGreaterThanOrEqual(busyDuration, .seconds(4))
        XCTAssertLessThan(busyDuration, .seconds(6))

        let store = fixture.store
        let bookmark = fixture.bookmark
        let lease = fixture.lease
        let cancelled = Task {
            try await store.register(
                label: "must-cancel",
                bookmark: bookmark,
                limitOverrides: .init(),
                lease: lease
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        let cancellationStarted = ContinuousClock.now
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled transaction completed")
        } catch {
            XCTAssertTrue(
                error is CancellationError || error as? ProjectStateError == .cancelled,
                "Unexpected cancellation error: \(error)"
            )
        }
        XCTAssertLessThan(cancellationStarted.duration(to: .now), .milliseconds(500))

        try helper.stopAndReap()

        let registration = try await fixture.store.register(
            label: "after-kernel-release",
            bookmark: fixture.bookmark,
            limitOverrides: .init(),
            lease: fixture.lease
        )
        XCTAssertEqual(registration.projectID, ProjectID(rawValue: lockRegistrationUUID))
        XCTAssertEqual(registration.commit, .committed)
        try assertOwnedStateFiles(
            fixture,
            stateFile: fixture.stateDirectory.appendingPathComponent(
                "project-\(registration.projectID.rawValue.uuidString.lowercased()).json"
            )
        )
        try writeResult(context, "LOCK_BOUNDARY_OK")
    }

    func testPrepareCrashRecoveryFixture() async throws {
        let context = try ProcessHarnessContext.require(role: .prepare)
        try createInitialLayout(context)
        let fixture = try await ProcessStateFixture.open(
            context: context,
            operations: SystemStateFileSystemOperations(),
            uuids: processUUIDs()
        )
        defer { fixture.close() }

        let registration = try await fixture.store.register(
            label: "old-envelope",
            bookmark: fixture.bookmark,
            limitOverrides: .init(),
            lease: fixture.lease
        )
        XCTAssertEqual(registration.projectID, ProjectID(rawValue: processProjectUUID))
        XCTAssertEqual(registration.commit, .committed)

        try Data(decoyContents.utf8).write(to: fixture.decoyFile, options: .withoutOverwriting)
        guard chmod(fixture.decoyFile.path, 0o600) == 0 else {
            throw ProcessHarnessError.invalidState
        }
        try assertOwnedStateFiles(fixture)
        XCTAssertEqual(try Data(contentsOf: fixture.outsideCanary), outsideCanaryData)
        try writeResult(context, "PREPARE_BOUNDARY_OK")
    }

    func testCrashVictimStopsAtClosedPersistenceBoundary() async throws {
        let context = try ProcessHarnessContext.require(role: .crashVictim)
        let stop = try context.requireCrashStop()
        try writeExclusiveFile(
            try context.requirePIDFile(),
            data: Data(String(getpid()).utf8)
        )

        let fixture = try await ProcessStateFixture.open(
            context: context,
            operations: CrashStoppingStateFileSystemOperations(stop: stop),
            uuids: [victimStagingUUID]
        )
        defer { fixture.close() }

        _ = try await fixture.store.recordAttempt(
            projectID: ProjectID(rawValue: processProjectUUID),
            coverage: nonCompleteCoverage(.failed),
            finishedAt: Date(timeIntervalSince1970: 7),
            metadata: try AttemptSummaryMetadata(
                advisoryCacheSchemaVersion: nil,
                advisory: nil
            ),
            lease: fixture.lease
        )
        XCTFail("Crash victim continued past \(stop.rawValue)")
    }

    func testRecoverPreRenameCrash() async throws {
        let context = try ProcessHarnessContext.require(role: .recoverPreRename)
        try await recover(context: context, expected: .oldEnvelopeWithStaging)
        try writeResult(context, "RECOVER_PRE_RENAME_OK")
    }

    func testRecoverPostRenameCrash() async throws {
        let context = try ProcessHarnessContext.require(role: .recoverPostRename)
        try await recover(context: context, expected: .newEnvelopeWithoutStaging)
        try writeResult(context, "RECOVER_POST_RENAME_OK")
    }
}

private let processProjectUUID = UUID(
    uuidString: "81818181-8181-4181-8181-818181818181"
)!
private let lockRegistrationUUID = UUID(
    uuidString: "87878787-8787-4787-8787-878787878787"
)!
private let processGeneration = UUID(
    uuidString: "82828282-8282-4282-8282-828282828282"
)!
private let prepareStagingUUID = UUID(
    uuidString: "83838383-8383-4383-8383-838383838383"
)!
private let victimStagingUUID = UUID(
    uuidString: "84848484-8484-4484-8484-848484848484"
)!
private let recoveryStagingUUID = UUID(
    uuidString: "85858585-8585-4585-8585-858585858585"
)!
private let outsideCanaryData = Data(
    "PROJECT_SCANNER_PROCESS_OUTSIDE_CANARY_26D189F4".utf8
)
private let decoyContents = "PROJECT_SCANNER_NON_STAGING_DECOY_973E14B6"
private let processHarnessToken = "PROJECT_SCANNER_PROCESS_HARNESS_V1_4B7E91C2"

private enum ProcessHarnessRole: String {
    case lock
    case prepare
    case crashVictim = "crash-victim"
    case recoverPreRename = "recover-pre-rename"
    case recoverPostRename = "recover-post-rename"
}

private enum CrashStop: String {
    case preRename = "syncStagingFile"
    case postRename = "syncScannerAfterRename"
}

private enum ExpectedRecovery {
    case oldEnvelopeWithStaging
    case newEnvelopeWithoutStaging
}

private enum ProcessHarnessError: Error {
    case invalidEnvironment
    case invalidPath
    case invalidState
    case helperFailed
    case timeout
    case markerFailed
}

private struct ProcessHarnessContext {
    let role: ProcessHarnessRole
    let stateRoot: URL
    let workRoot: URL
    private let environment: [String: String]

    static func require(role expectedRole: ProcessHarnessRole) throws -> Self {
        let environment = ProcessInfo.processInfo.environment
        guard let harness = environment["PROJECT_SCANNER_PROCESS_HARNESS_TOKEN"] else {
            throw XCTSkip("Task 12 process-boundary harness is not active")
        }
        guard harness == processHarnessToken,
              environment["PROJECT_SCANNER_PROCESS_ROLE"] == expectedRole.rawValue,
              let rootValue = environment["PROJECT_SCANNER_PROCESS_STATE_ROOT"] else {
            throw ProcessHarnessError.invalidEnvironment
        }

        let root = try requireAbsoluteCanonicalURL(rootValue)
        let components = root.pathComponents
        guard components.count >= 4,
              components[0] == "/",
              components[1] == "tmp",
              components[2].hasPrefix("project-scanner-process."),
              components[2].count == "project-scanner-process.".count + 6 else {
            throw ProcessHarnessError.invalidPath
        }
        let workRoot = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(components[2], isDirectory: true)
        guard root.path.hasPrefix(workRoot.path + "/") else {
            throw ProcessHarnessError.invalidPath
        }
        try requireOwnedDirectory(root, mode: 0o700)
        try requireOwnedDirectory(workRoot, mode: 0o700)
        return Self(
            role: expectedRole,
            stateRoot: root,
            workRoot: workRoot,
            environment: environment
        )
    }

    func requireResultFile() throws -> URL {
        guard let value = environment["PROJECT_SCANNER_PROCESS_RESULT_FILE"] else {
            throw ProcessHarnessError.invalidEnvironment
        }
        return try requireNewFile(value)
    }

    func requirePIDFile() throws -> URL {
        guard role == .crashVictim,
              let value = environment["PROJECT_SCANNER_PROCESS_PID_FILE"] else {
            throw ProcessHarnessError.invalidEnvironment
        }
        return try requireNewFile(value)
    }

    func requireCrashStop() throws -> CrashStop {
        guard role == .crashVictim,
              let value = environment["PROJECT_SCANNER_PROCESS_CRASH_SITE"],
              let stop = CrashStop(rawValue: value) else {
            throw ProcessHarnessError.invalidEnvironment
        }
        return stop
    }

    func requireLockHelper() throws -> URL {
        guard let value = environment["PROJECT_SCANNER_LOCK_HELPER"] else {
            throw ProcessHarnessError.invalidEnvironment
        }
        let helper = try requireAbsoluteCanonicalURL(value)
        guard helper.deletingLastPathComponent().path == workRoot.path else {
            throw ProcessHarnessError.invalidPath
        }
        try requireOwnedRegularFile(helper, mode: nil)
        guard access(helper.path, X_OK) == 0 else { throw ProcessHarnessError.invalidPath }
        return helper
    }

    private func requireNewFile(_ value: String) throws -> URL {
        let file = try requireAbsoluteCanonicalURL(value)
        guard file.path.hasPrefix(workRoot.path + "/"),
              !FileManager.default.fileExists(atPath: file.path) else {
            throw ProcessHarnessError.invalidPath
        }
        var status = stat()
        guard lstat(file.path, &status) != 0, errno == ENOENT else {
            throw ProcessHarnessError.invalidPath
        }
        return file
    }
}

private final class ProcessStateFixture {
    let context: ProcessHarnessContext
    let parent: PrivateStateParentCapability
    let store: ProjectStateStore
    let lease: ProjectKeyLease
    let bookmark: ProjectBookmark

    var stateDirectory: URL {
        context.stateRoot.appendingPathComponent("Pearcleaner/ProjectScanner", isDirectory: true)
    }

    var stateFile: URL {
        stateDirectory.appendingPathComponent(
            "project-\(processProjectUUID.uuidString.lowercased()).json"
        )
    }

    var lockFile: URL { stateDirectory.appendingPathComponent(".state.lock") }
    var stagingFile: URL {
        stateDirectory.appendingPathComponent(
            ".state-\(victimStagingUUID.uuidString.lowercased()).tmp"
        )
    }
    var decoyFile: URL { stateDirectory.appendingPathComponent(".state-not-a-uuid.tmp") }
    var selectedRoot: URL {
        context.stateRoot.deletingLastPathComponent()
            .appendingPathComponent("Selected Project", isDirectory: true)
    }
    var outsideCanary: URL {
        context.stateRoot.deletingLastPathComponent()
            .appendingPathComponent("outside-canary", isDirectory: false)
    }

    static func open(
        context: ProcessHarnessContext,
        operations: any StateFileSystemOperations,
        uuids: [UUID]
    ) async throws -> ProcessStateFixture {
        let parent = try PrivateStateParentCapability.open(
            applicationSupportURL: context.stateRoot
        )
        do {
            let material = try ProjectKeyMaterial(
                generation: processGeneration,
                keyBytes: Data(repeating: 0xA5, count: 32)
            )
            let coordinator = ProjectKeyCoordinator(
                store: ScriptedKeyStore(stored: material)
            )
            let store = try await ProjectStateStore(
                parent: parent,
                keyCoordinator: coordinator,
                uuid: ScriptedUUID(uuids),
                operations: operations,
                backupOperations: SystemBackupExclusionOperations()
            )
            let selected = context.stateRoot.deletingLastPathComponent()
                .appendingPathComponent("Selected Project", isDirectory: true)
            let bookmark = try ProjectBookmarkPersistence.decode(
                testBookmarkBytes(payload: Data(selected.path.utf8))
            )
            return ProcessStateFixture(
                context: context,
                parent: parent,
                store: store,
                lease: .persistent(material),
                bookmark: bookmark
            )
        } catch {
            parent.close()
            throw error
        }
    }

    private init(
        context: ProcessHarnessContext,
        parent: PrivateStateParentCapability,
        store: ProjectStateStore,
        lease: ProjectKeyLease,
        bookmark: ProjectBookmark
    ) {
        self.context = context
        self.parent = parent
        self.store = store
        self.lease = lease
        self.bookmark = bookmark
    }

    func close() { parent.close() }
}

private final class LockHolderProcess: @unchecked Sendable {
    private let process: Process
    private var reaped = false

    private init(process: Process) { self.process = process }

    static func start(executable: URL, lockFile: URL) throws -> LockHolderProcess {
        try requireOwnedRegularFile(lockFile, mode: 0o600)
        let process = Process()
        let stdout = Pipe()
        process.executableURL = executable
        process.arguments = [lockFile.path]
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        let holder = LockHolderProcess(process: process)
        do {
            try requireReadiness(stdout.fileHandleForReading.fileDescriptor)
            guard process.isRunning else { throw ProcessHarnessError.helperFailed }
            return holder
        } catch {
            holder.stopIfNeeded()
            throw error
        }
    }

    func stopAndReap() throws {
        guard !reaped, process.isRunning else {
            throw ProcessHarnessError.helperFailed
        }
        guard kill(process.processIdentifier, SIGKILL) == 0 else {
            throw ProcessHarnessError.helperFailed
        }
        process.waitUntilExit()
        reaped = true
        guard process.terminationReason == .uncaughtSignal,
              process.terminationStatus == SIGKILL else {
            throw ProcessHarnessError.helperFailed
        }
    }

    func stopIfNeeded() {
        guard !reaped else { return }
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        reaped = true
    }
}

private struct CrashStoppingStateFileSystemOperations: StateFileSystemOperations {
    let stop: CrashStop
    private let system = SystemStateFileSystemOperations()

    func duplicateParent(_ capability: PrivateStateParentCapability, site: StateSyscallSite) throws -> Int32 {
        try system.duplicateParent(capability, site: site)
    }
    func mkdir(directory: Int32, name: String, mode: mode_t, site: StateSyscallSite) throws {
        try system.mkdir(directory: directory, name: name, mode: mode, site: site)
    }
    func inspect(directory: Int32, name: String, site: StateSyscallSite) throws -> stat? {
        try system.inspect(directory: directory, name: name, site: site)
    }
    func open(directory: Int32, name: String, flags: Int32, mode: mode_t, site: StateSyscallSite) throws -> Int32 {
        try system.open(directory: directory, name: name, flags: flags, mode: mode, site: site)
    }
    func status(descriptor: Int32, site: StateSyscallSite) throws -> stat {
        try system.status(descriptor: descriptor, site: site)
    }
    func chmod(descriptor: Int32, mode: mode_t, site: StateSyscallSite) throws {
        try system.chmod(descriptor: descriptor, mode: mode, site: site)
    }
    func sync(descriptor: Int32, site: StateSyscallSite) throws {
        if stop == .preRename, site == .syncStagingFile {
            try system.sync(descriptor: descriptor, site: site)
            try stopProcess()
            return
        }
        if stop == .postRename, site == .syncScannerAfterRename {
            try stopProcess()
            try system.sync(descriptor: descriptor, site: site)
            return
        }
        try system.sync(descriptor: descriptor, site: site)
    }
    func close(descriptor: Int32, site: StateSyscallSite) throws {
        try system.close(descriptor: descriptor, site: site)
    }
    func lock(descriptor: Int32, operation: Int32, site: StateSyscallSite) throws {
        try system.lock(descriptor: descriptor, operation: operation, site: site)
    }
    func duplicate(descriptor: Int32, site: StateSyscallSite) throws -> Int32 {
        try system.duplicate(descriptor: descriptor, site: site)
    }
    func openDirectoryStream(descriptor: Int32, site: StateSyscallSite) throws -> StateDirectoryStream {
        try system.openDirectoryStream(descriptor: descriptor, site: site)
    }
    func readDirectoryEntry(_ stream: StateDirectoryStream, site: StateSyscallSite) throws -> [UInt8]? {
        try system.readDirectoryEntry(stream, site: site)
    }
    func closeDirectoryStream(_ stream: StateDirectoryStream, site: StateSyscallSite) throws {
        try system.closeDirectoryStream(stream, site: site)
    }
    func read(descriptor: Int32, count: Int, site: StateSyscallSite) throws -> Data {
        try system.read(descriptor: descriptor, count: count, site: site)
    }
    func write(descriptor: Int32, data: Data, site: StateSyscallSite) throws {
        try system.write(descriptor: descriptor, data: data, site: site)
    }
    func unlink(directory: Int32, name: String, site: StateSyscallSite) throws {
        try system.unlink(directory: directory, name: name, site: site)
    }
    func rename(directory: Int32, from: String, to: String, site: StateSyscallSite) throws {
        try system.rename(directory: directory, from: from, to: to, site: site)
    }

    private func stopProcess() throws {
        guard raise(SIGSTOP) == 0 else { throw ProcessHarnessError.invalidState }
    }
}

private func recover(
    context: ProcessHarnessContext,
    expected: ExpectedRecovery
) async throws {
    let stateDirectory = context.stateRoot
        .appendingPathComponent("Pearcleaner/ProjectScanner", isDirectory: true)
    let stateFile = stateDirectory.appendingPathComponent(
        "project-\(processProjectUUID.uuidString.lowercased()).json"
    )
    let stagingFile = stateDirectory.appendingPathComponent(
        ".state-\(victimStagingUUID.uuidString.lowercased()).tmp"
    )
    let decoyFile = stateDirectory.appendingPathComponent(".state-not-a-uuid.tmp")
    let outside = context.stateRoot.deletingLastPathComponent()
        .appendingPathComponent("outside-canary")

    let bytesBeforeRecovery = try Data(contentsOf: stateFile)
    let decodedBeforeRecovery = try ProjectStateJSONCodec.decode(
        bytesBeforeRecovery,
        expectedProjectID: ProjectID(rawValue: processProjectUUID)
    )
    XCTAssertEqual(decodedBeforeRecovery.label, "old-envelope")
    XCTAssertEqual(try Data(contentsOf: outside), outsideCanaryData)
    XCTAssertEqual(try Data(contentsOf: decoyFile), Data(decoyContents.utf8))

    switch expected {
    case .oldEnvelopeWithStaging:
        XCTAssertNil(decodedBeforeRecovery.lastAttempt)
        try requireOwnedRegularFile(stagingFile, mode: 0o600)
        let helper = try LockHolderProcess.start(
            executable: try context.requireLockHelper(),
            lockFile: stateDirectory.appendingPathComponent(".state.lock")
        )
        defer { helper.stopIfNeeded() }
        let contentionStarted = ContinuousClock.now
        do {
            let unexpectedlyOpened = try await ProcessStateFixture.open(
                context: context,
                operations: SystemStateFileSystemOperations(),
                uuids: [recoveryStagingUUID]
            )
            unexpectedlyOpened.close()
            XCTFail("Recovery cleaned staging without owning the transaction lock")
        } catch {
            XCTAssertEqual(error as? ProjectStateError, .transactionBusy)
        }
        let contentionDuration = contentionStarted.duration(to: .now)
        XCTAssertGreaterThanOrEqual(contentionDuration, .seconds(4))
        XCTAssertLessThan(contentionDuration, .seconds(6))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingFile.path))
        XCTAssertEqual(try Data(contentsOf: decoyFile), Data(decoyContents.utf8))
        try helper.stopAndReap()
    case .newEnvelopeWithoutStaging:
        XCTAssertEqual(decodedBeforeRecovery.lastAttempt?.terminalState, .failed)
        XCTAssertEqual(
            decodedBeforeRecovery.lastAttempt?.finishedAt,
            Date(timeIntervalSince1970: 7)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingFile.path))
    }

    let fixture = try await ProcessStateFixture.open(
        context: context,
        operations: SystemStateFileSystemOperations(),
        uuids: [recoveryStagingUUID]
    )
    defer { fixture.close() }

    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stagingFile.path))
    XCTAssertEqual(try Data(contentsOf: fixture.decoyFile), Data(decoyContents.utf8))
    XCTAssertEqual(try Data(contentsOf: fixture.stateFile), bytesBeforeRecovery)
    let summary = try await fixture.store.loadSummary(
        projectID: ProjectID(rawValue: processProjectUUID)
    )
    XCTAssertEqual(summary?.label, "old-envelope")
    switch expected {
    case .oldEnvelopeWithStaging:
        XCTAssertNil(summary?.lastAttempt)
    case .newEnvelopeWithoutStaging:
        XCTAssertEqual(summary?.lastAttempt?.terminalState, .failed)
    }

    try assertOwnedStateFiles(fixture)
    XCTAssertNil(bytesBeforeRecovery.range(of: outsideCanaryData))
    XCTAssertEqual(try Data(contentsOf: fixture.outsideCanary), outsideCanaryData)

    let laterCommit = try await fixture.store.recordAttempt(
        projectID: ProjectID(rawValue: processProjectUUID),
        coverage: nonCompleteCoverage(.partial),
        finishedAt: Date(timeIntervalSince1970: 9),
        metadata: try AttemptSummaryMetadata(
            advisoryCacheSchemaVersion: nil,
            advisory: nil
        ),
        lease: fixture.lease
    )
    XCTAssertEqual(laterCommit, .committed)
    let afterCommit = try await fixture.store.loadSummary(
        projectID: ProjectID(rawValue: processProjectUUID)
    )
    XCTAssertEqual(afterCommit?.lastAttempt?.terminalState, .partial)
    _ = try ProjectStateJSONCodec.decode(
        Data(contentsOf: fixture.stateFile),
        expectedProjectID: ProjectID(rawValue: processProjectUUID)
    )
    try assertOwnedStateFiles(fixture)
    XCTAssertEqual(try Data(contentsOf: fixture.outsideCanary), outsideCanaryData)
}

private func createInitialLayout(_ context: ProcessHarnessContext) throws {
    let contents = try FileManager.default.contentsOfDirectory(
        atPath: context.stateRoot.path
    )
    guard contents.isEmpty else { throw ProcessHarnessError.invalidState }
    let scenario = context.stateRoot.deletingLastPathComponent()
    let selected = scenario.appendingPathComponent("Selected Project", isDirectory: true)
    let outside = scenario.appendingPathComponent("outside-canary", isDirectory: false)
    try FileManager.default.createDirectory(
        at: selected,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    try outsideCanaryData.write(to: outside, options: .withoutOverwriting)
}

private func processUUIDs() -> [UUID] {
    [
        processProjectUUID,
        UUID(uuidString: "86868686-8686-4686-8686-868686868686")!,
        lockRegistrationUUID,
        UUID(uuidString: "88888888-8888-4888-8888-888888888888")!,
    ]
}

private func writeResult(_ context: ProcessHarnessContext, _ value: String) throws {
    try writeExclusiveFile(try context.requireResultFile(), data: Data(value.utf8))
}

private func writeExclusiveFile(_ url: URL, data: Data) throws {
    let descriptor = url.path.withCString {
        Darwin.open(
            $0,
            O_WRONLY | O_NONBLOCK | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
    }
    guard descriptor >= 0 else { throw ProcessHarnessError.markerFailed }
    var owned = true
    defer { if owned { _ = Darwin.close(descriptor) } }
    guard fchmod(descriptor, 0o600) == 0 else {
        throw ProcessHarnessError.markerFailed
    }
    let status = try descriptorStatus(descriptor)
    guard status.st_mode & S_IFMT == S_IFREG,
          status.st_uid == geteuid(),
          status.st_mode & 0o7777 == 0o600 else {
        throw ProcessHarnessError.markerFailed
    }
    var offset = 0
    while offset < data.count {
        let amount = data.withUnsafeBytes { bytes in
            Darwin.write(
                descriptor,
                bytes.baseAddress!.advanced(by: offset),
                data.count - offset
            )
        }
        if amount < 0, errno == EINTR { continue }
        guard amount > 0 else { throw ProcessHarnessError.markerFailed }
        offset += amount
    }
    while fsync(descriptor) != 0 {
        if errno != EINTR { throw ProcessHarnessError.markerFailed }
    }
    guard Darwin.close(descriptor) == 0 else {
        throw ProcessHarnessError.markerFailed
    }
    owned = false
}

private func requireReadiness(_ descriptor: Int32) throws {
    var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    while true {
        let result = poll(&pollDescriptor, 1, 5_000)
        if result < 0, errno == EINTR { continue }
        guard result == 1, pollDescriptor.revents & Int16(POLLIN) != 0 else {
            throw ProcessHarnessError.timeout
        }
        break
    }
    var byte: UInt8 = 0
    while true {
        let count = withUnsafeMutablePointer(to: &byte) {
            Darwin.read(descriptor, $0, 1)
        }
        if count < 0, errno == EINTR { continue }
        guard count == 1, byte == 0x52 else {
            throw ProcessHarnessError.helperFailed
        }
        return
    }
}

private func assertOwnedStateFiles(
    _ fixture: ProcessStateFixture,
    stateFile: URL? = nil
) throws {
    try requireOwnedDirectory(fixture.stateDirectory, mode: 0o700)
    try requireOwnedRegularFile(fixture.lockFile, mode: 0o600)
    try requireOwnedRegularFile(stateFile ?? fixture.stateFile, mode: 0o600)
}

private func requireAbsoluteCanonicalURL(_ value: String) throws -> URL {
    let url = URL(fileURLWithPath: value)
    guard value.hasPrefix("/"),
          url.path == value,
          url.standardizedFileURL.path == value else {
        throw ProcessHarnessError.invalidPath
    }
    return url
}

private func requireOwnedDirectory(_ url: URL, mode: mode_t) throws {
    let status = try pathStatus(url)
    guard status.st_mode & S_IFMT == S_IFDIR,
          status.st_uid == geteuid(),
          status.st_mode & 0o7777 == mode else {
        throw ProcessHarnessError.invalidPath
    }
}

private func requireOwnedRegularFile(_ url: URL, mode: mode_t?) throws {
    let status = try pathStatus(url)
    guard status.st_mode & S_IFMT == S_IFREG,
          status.st_uid == geteuid(),
          mode.map({ status.st_mode & 0o7777 == $0 }) ?? true else {
        throw ProcessHarnessError.invalidPath
    }
}

private func pathStatus(_ url: URL) throws -> stat {
    var status = stat()
    while lstat(url.path, &status) != 0 {
        if errno != EINTR { throw ProcessHarnessError.invalidPath }
    }
    return status
}

private func descriptorStatus(_ descriptor: Int32) throws -> stat {
    var status = stat()
    while fstat(descriptor, &status) != 0 {
        if errno != EINTR { throw ProcessHarnessError.invalidPath }
    }
    return status
}
