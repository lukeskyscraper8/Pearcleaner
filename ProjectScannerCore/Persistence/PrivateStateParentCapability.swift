import Darwin
import Foundation

public enum PrivateStateParentError: Error, CaseIterable, Sendable, Equatable {
    case invalidSelection
    case symlink
    case notDirectory
    case openFailed
    case identityChanged
    case wrongOwner
    case unsafePermissions
    case closedCapability
}

final class PrivateStateParentOpenPause: @unchecked Sendable {
    private let paused = DispatchSemaphore(value: 0)
    private let resumed = DispatchSemaphore(value: 0)

    func pauseAfterLstat() {
        paused.signal()
        resumed.wait()
    }

    func waitUntilPaused(timeout: TimeInterval) -> Bool {
        paused.wait(timeout: .now() + timeout) == .success
    }

    func resume() {
        resumed.signal()
    }
}

public final class PrivateStateParentCapability: @unchecked Sendable {
    private struct StableIdentity: Sendable, Equatable {
        let device: UInt64
        let inode: UInt64
        let type: UInt16

        init(_ status: stat) throws {
            guard let device = UInt64(exactly: status.st_dev),
                  let inode = UInt64(exactly: status.st_ino),
                  let mode = UInt16(exactly: status.st_mode) else {
                throw PrivateStateParentError.identityChanged
            }
            self.device = device
            self.inode = inode
            type = mode & UInt16(S_IFMT)
        }
    }

    private let lock = NSLock()
    private let identity: StableIdentity
    private var descriptor: Int32

    private init(descriptor: Int32, identity: StableIdentity) {
        self.descriptor = descriptor
        self.identity = identity
    }

    public static func open(applicationSupportURL: URL) throws -> PrivateStateParentCapability {
        try open(applicationSupportURL: applicationSupportURL, testPause: nil)
    }

    static func open(
        applicationSupportURL: URL,
        testPause: PrivateStateParentOpenPause?
    ) throws -> PrivateStateParentCapability {
        try applicationSupportURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw PrivateStateParentError.invalidSelection }

            var inspected = stat()
            guard lstat(path, &inspected) == 0 else {
                throw PrivateStateParentError.openFailed
            }
            let inspectedType = inspected.st_mode & S_IFMT
            guard inspectedType != S_IFLNK else { throw PrivateStateParentError.symlink }
            guard inspectedType == S_IFDIR else { throw PrivateStateParentError.notDirectory }

            testPause?.pauseAfterLstat()

            let openedDescriptor = Darwin.open(
                path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard openedDescriptor >= 0 else { throw PrivateStateParentError.openFailed }
            var shouldClose = true
            defer {
                if shouldClose {
                    Darwin.close(openedDescriptor)
                }
            }

            var opened = stat()
            guard fstat(openedDescriptor, &opened) == 0 else {
                throw PrivateStateParentError.openFailed
            }
            try validate(inspected: inspected, opened: opened, effectiveUserID: geteuid())
            let capability = PrivateStateParentCapability(
                descriptor: openedDescriptor,
                identity: try StableIdentity(opened)
            )
            shouldClose = false
            return capability
        }
    }

    static func validate(
        inspected: stat,
        opened: stat,
        effectiveUserID: uid_t
    ) throws {
        let inspectedType = inspected.st_mode & S_IFMT
        guard inspectedType != S_IFLNK else { throw PrivateStateParentError.symlink }
        guard inspectedType == S_IFDIR else { throw PrivateStateParentError.notDirectory }
        guard opened.st_mode & S_IFMT == S_IFDIR else {
            throw PrivateStateParentError.identityChanged
        }
        guard inspected.st_dev == opened.st_dev, inspected.st_ino == opened.st_ino else {
            throw PrivateStateParentError.identityChanged
        }
        guard opened.st_uid == effectiveUserID else { throw PrivateStateParentError.wrongOwner }
        guard opened.st_mode & 0o022 == 0 else {
            throw PrivateStateParentError.unsafePermissions
        }
    }

    func duplicateValidatedDescriptor() throws -> Int32 {
        try lock.withLock {
            guard descriptor >= 0 else { throw PrivateStateParentError.closedCapability }

            try validateCurrentDescriptor(descriptor)
            let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
            guard duplicate >= 0 else { throw PrivateStateParentError.openFailed }
            do {
                try validateCurrentDescriptor(descriptor)
                try validateCurrentDescriptor(duplicate)
                return duplicate
            } catch {
                Darwin.close(duplicate)
                throw error
            }
        }
    }

    public func close() {
        lock.withLock {
            guard descriptor >= 0 else { return }
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    deinit {
        close()
    }

    private func validateCurrentDescriptor(_ descriptor: Int32) throws {
        var current = stat()
        guard fstat(descriptor, &current) == 0 else {
            throw PrivateStateParentError.openFailed
        }
        guard try StableIdentity(current) == identity else {
            throw PrivateStateParentError.identityChanged
        }
        guard current.st_mode & S_IFMT == S_IFDIR else {
            throw PrivateStateParentError.identityChanged
        }
        guard current.st_uid == geteuid() else { throw PrivateStateParentError.wrongOwner }
        guard current.st_mode & 0o022 == 0 else {
            throw PrivateStateParentError.unsafePermissions
        }
    }
}
