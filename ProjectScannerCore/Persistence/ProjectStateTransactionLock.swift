import Darwin
import Foundation

final class ProjectStateTransactionLock: @unchecked Sendable {
    private static let processGate = StateProcessGate()
    private static let retryDelay = Duration.milliseconds(25)
    private static let timeout = Duration.seconds(5)

    private let operations: any StateFileSystemOperations
    private let directoryDescriptor: Int32
    private let identity: LockIdentity
    private let stateLock = NSLock()
    private var descriptor: Int32
    private var retired = false

    private init(
        directoryDescriptor: Int32,
        descriptor: Int32,
        identity: LockIdentity,
        operations: any StateFileSystemOperations
    ) {
        self.directoryDescriptor = directoryDescriptor
        self.descriptor = descriptor
        self.identity = identity
        self.operations = operations
    }

    static func open(
        directoryDescriptor: Int32,
        operations: any StateFileSystemOperations
    ) throws -> ProjectStateTransactionLock {
        let existing = try operations.inspect(
            directory: directoryDescriptor,
            name: ".state.lock",
            site: .inspectExistingLockFile
        )
        let descriptor: Int32
        let status: stat
        if let existing {
            descriptor = try operations.open(
                directory: directoryDescriptor,
                name: ".state.lock",
                flags: O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
                mode: 0,
                site: .openExistingLockFile
            )
            do {
                status = try operations.status(descriptor: descriptor, site: .statExistingLockFile)
                try validateLock(status)
                guard LockIdentity(existing).matches(status) else {
                    throw ProjectStateError.stateUnavailable
                }
            } catch {
                closeLockDescriptor(descriptor, operations: operations, original: error)
                throw closedStateError(error)
            }
        } else {
            descriptor = try operations.open(
                directory: directoryDescriptor,
                name: ".state.lock",
                flags: O_RDWR | O_NONBLOCK | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode: 0o600,
                site: .createLockFile
            )
            do {
                try operations.chmod(descriptor: descriptor, mode: 0o600, site: .chmodNewLockFile)
                status = try operations.status(descriptor: descriptor, site: .statNewLockFile)
                try validateLock(status)
                try operations.sync(descriptor: descriptor, site: .syncNewLockFile)
                try operations.sync(descriptor: directoryDescriptor, site: .syncScannerAfterLockFile)
            } catch {
                closeLockDescriptor(descriptor, operations: operations, original: error)
                throw closedStateError(error)
            }
        }
        return ProjectStateTransactionLock(
            directoryDescriptor: directoryDescriptor,
            descriptor: descriptor,
            identity: LockIdentity(status),
            operations: operations
        )
    }

    func acquire() async throws {
        do { try await Self.processGate.acquire() }
        catch { throw error is CancellationError ? ProjectStateError.cancelled : .stateUnavailable }

        var gateOwned = true
        var flockOwned = false
        do {
            let descriptor = try currentDescriptor()
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: Self.timeout)
            while true {
                if Task.isCancelled { throw ProjectStateError.cancelled }
                try validatePinnedLock(
                    descriptor: descriptor,
                    inspectSite: .inspectLockBeforeAcquire,
                    statusSite: .statLockBeforeAcquire
                )
                do {
                    try operations.lock(
                        descriptor: descriptor,
                        operation: LOCK_EX | LOCK_NB,
                        site: .acquireTransactionLock
                    )
                    flockOwned = true
                    break
                } catch StateOperationError.contention {
                    guard clock.now < deadline else { throw ProjectStateError.transactionBusy }
                    do { try await Task.sleep(for: Self.retryDelay) }
                    catch { throw ProjectStateError.cancelled }
                } catch StateOperationError.acquiredThenFailed {
                    flockOwned = true
                    throw ProjectStateError.stateUnavailable
                }
            }

            try validatePinnedLock(
                descriptor: descriptor,
                inspectSite: .inspectLockAfterAcquire,
                statusSite: .statLockAfterAcquire
            )
            gateOwned = false
        } catch {
            if flockOwned {
                do {
                    try operations.lock(
                        descriptor: try currentDescriptor(),
                        operation: LOCK_UN,
                        site: .releaseTransactionLock
                    )
                } catch {
                    retireDescriptor()
                }
            }
            if gateOwned { Self.processGate.release() }
            if isIdentityFailure(error) { retireWithoutGate() }
            throw closedLockError(error)
        }
    }

    func release() throws {
        let descriptor = try currentDescriptor()
        try operations.lock(
            descriptor: descriptor,
            operation: LOCK_UN,
            site: .releaseTransactionLock
        )
        Self.processGate.release()
    }

    func retireAfterReleaseFailure() {
        retireDescriptor()
        Self.processGate.release()
    }

    func close() { retireWithoutGate() }

    deinit { close() }

    private func currentDescriptor() throws -> Int32 {
        try stateLock.withLock {
            guard !retired, descriptor >= 0 else { throw ProjectStateError.stateUnavailable }
            return descriptor
        }
    }

    private func validatePinnedLock(
        descriptor: Int32,
        inspectSite: StateSyscallSite,
        statusSite: StateSyscallSite
    ) throws {
        let entry = try operations.inspect(
            directory: directoryDescriptor,
            name: ".state.lock",
            site: inspectSite
        )
        guard let entry, identity.matches(entry) else { throw LockIdentityError() }
        let opened = try operations.status(descriptor: descriptor, site: statusSite)
        guard identity.matches(opened) else { throw LockIdentityError() }
        try validateLock(opened)
    }

    private func retireWithoutGate() { retireDescriptor() }

    private func retireDescriptor() {
        let current = stateLock.withLock { () -> Int32 in
            guard !retired else { return -1 }
            retired = true
            let current = descriptor
            descriptor = -1
            return current
        }
        guard current >= 0 else { return }
        do { try operations.close(descriptor: current, site: .closeLockFile) }
        catch {
            if !lockCloseSucceeded(error) {
                try? SystemStateFileSystemOperations().close(
                    descriptor: current, site: .closeLockFile
                )
            }
        }
    }
}

private struct LockIdentity: Sendable, Equatable {
    let device: dev_t
    let inode: ino_t
    let type: mode_t
    let owner: uid_t
    let mode: mode_t

    init(_ status: stat) {
        device = status.st_dev
        inode = status.st_ino
        type = status.st_mode & S_IFMT
        owner = status.st_uid
        mode = status.st_mode & 0o7777
    }

    func matches(_ status: stat) -> Bool {
        device == status.st_dev
            && inode == status.st_ino
            && type == status.st_mode & S_IFMT
            && owner == status.st_uid
            && mode == status.st_mode & 0o7777
    }
}

private struct LockIdentityError: Error {}

private func validateLock(_ status: stat) throws {
    guard status.st_mode & S_IFMT == S_IFREG,
          status.st_uid == geteuid(),
          status.st_mode & 0o7777 == 0o600 else {
        throw ProjectStateError.stateUnavailable
    }
}

private func closeLockDescriptor(
    _ descriptor: Int32,
    operations: any StateFileSystemOperations,
    original: Error
) {
    if case StateOperationError.failedAfterSuccess(let site, _) = original,
       site == .createLockFile || site == .openExistingLockFile { return }
    if case StateOperationError.stoppedAfterSuccess(let site) = original,
       site == .createLockFile || site == .openExistingLockFile { return }
    do { try operations.close(descriptor: descriptor, site: .closeLockFile) }
    catch {
        if !lockCloseSucceeded(error) {
            try? SystemStateFileSystemOperations().close(
                descriptor: descriptor, site: .closeLockFile
            )
        }
    }
}

private func lockCloseSucceeded(_ error: Error) -> Bool {
    if case StateOperationError.failedAfterSuccess(let site, _) = error {
        return site == .closeLockFile
    }
    if case StateOperationError.stoppedAfterSuccess(let site) = error {
        return site == .closeLockFile
    }
    return false
}

private func isIdentityFailure(_ error: Error) -> Bool { error is LockIdentityError }

private func closedLockError(_ error: Error) -> ProjectStateError {
    if let state = error as? ProjectStateError { return state }
    if error is CancellationError { return .cancelled }
    return .stateUnavailable
}

private final class StateProcessGate: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var held = false
    private var waiters: [Waiter] = []

    func acquire() async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler(operation: { () async throws -> Void in
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if held {
                    waiters.append(Waiter(id: id, continuation: continuation))
                    lock.unlock()
                } else {
                    held = true
                    lock.unlock()
                    continuation.resume()
                }
            }
        }, onCancel: { [weak self] in self?.cancel(id) })
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    func release() {
        lock.lock()
        let next = waiters.isEmpty ? nil : waiters.removeFirst().continuation
        if next == nil { held = false }
        lock.unlock()
        next?.resume()
    }

    private func cancel(_ id: UUID) {
        lock.lock()
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        let waiter = waiters.remove(at: index)
        lock.unlock()
        waiter.continuation.resume(throwing: CancellationError())
    }
}
