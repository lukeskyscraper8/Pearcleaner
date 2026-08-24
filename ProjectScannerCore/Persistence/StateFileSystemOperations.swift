import Darwin
import Foundation

enum StateSyscallSite: String, CaseIterable, Sendable {
    case duplicatePrivateStateParent, createSharedDirectory, inspectSharedDirectory, openSharedDirectory
    case statSharedDirectoryBeforeModeAdjustment, chmodNewSharedDirectory, statSharedDirectoryAfterModeAdjustment
    case syncNewSharedDirectory, syncParentAfterSharedDirectory, closeParentDirectory
    case createScannerDirectory, inspectScannerDirectory, openScannerDirectory
    case statScannerDirectoryBeforeModeAdjustment, chmodNewScannerDirectory, statScannerDirectoryAfterModeAdjustment
    case syncNewScannerDirectory, syncSharedAfterScannerDirectory, closeSharedDirectory, closeScannerDirectory
    case statPinnedScannerForBackup, statInitialBackupReference, closeInitialBackupReference
    case statFinalBackupReference, closeFinalBackupReference, createLockFile, chmodNewLockFile
    case statNewLockFile, syncNewLockFile, syncScannerAfterLockFile, inspectExistingLockFile
    case openExistingLockFile, statExistingLockFile, inspectLockBeforeAcquire, statLockBeforeAcquire
    case acquireTransactionLock, inspectLockAfterAcquire, statLockAfterAcquire, releaseTransactionLock
    case closeLockFile, duplicateScannerForEnumeration, openStagingDirectoryStream
    case readStagingDirectoryEntry, closeStagingDirectoryStream, inspectStagingEntry, openStagingEntry
    case statStagingEntry, reinspectStagingEntryBeforeUnlink, unlinkRecoveredStagingEntry
    case closeRecoveredStagingEntry, openStateFileForRead, statStateFileBeforeRead, readStateFile
    case statStateFileAfterRead, closeStateFileAfterRead, inspectRegistrationDestination
    case createStagingFile, chmodStagingFile, statStagingFile, writeStagingFile, syncStagingFile
    case closeStagingFileBeforeRename, unlinkStagingFileAfterFailure, closeStagingFileAfterFailure
    case renameStagingFile, syncScannerAfterRename
}

enum ScriptedStateFailure: Sendable, Equatable { case failBefore(Int32), failAfterSuccess(Int32), stopAfterSuccess }

enum StateOperationError: Error, Sendable, Equatable {
    case contention
    case notFound
    case alreadyExists
    case failedBefore(StateSyscallSite, Int32)
    case failedAfterSuccess(StateSyscallSite, Int32)
    case acquiredThenFailed(Int32)
    case stoppedAfterSuccess(StateSyscallSite)
}

final class StateDirectoryStream: @unchecked Sendable {
    fileprivate let pointer: UnsafeMutablePointer<DIR>
    fileprivate init(_ pointer: UnsafeMutablePointer<DIR>) { self.pointer = pointer }
}

protocol StateFileSystemOperations: Sendable {
    func duplicateParent(_ capability: PrivateStateParentCapability, site: StateSyscallSite) throws -> Int32
    func mkdir(directory: Int32, name: String, mode: mode_t, site: StateSyscallSite) throws
    func inspect(directory: Int32, name: String, site: StateSyscallSite) throws -> stat?
    func open(directory: Int32, name: String, flags: Int32, mode: mode_t, site: StateSyscallSite) throws -> Int32
    func status(descriptor: Int32, site: StateSyscallSite) throws -> stat
    func chmod(descriptor: Int32, mode: mode_t, site: StateSyscallSite) throws
    func sync(descriptor: Int32, site: StateSyscallSite) throws
    func close(descriptor: Int32, site: StateSyscallSite) throws
    func lock(descriptor: Int32, operation: Int32, site: StateSyscallSite) throws
    func duplicate(descriptor: Int32, site: StateSyscallSite) throws -> Int32
    func openDirectoryStream(descriptor: Int32, site: StateSyscallSite) throws -> StateDirectoryStream
    func readDirectoryEntry(_ stream: StateDirectoryStream, site: StateSyscallSite) throws -> [UInt8]?
    func closeDirectoryStream(_ stream: StateDirectoryStream, site: StateSyscallSite) throws
    func read(descriptor: Int32, count: Int, site: StateSyscallSite) throws -> Data
    func write(descriptor: Int32, data: Data, site: StateSyscallSite) throws
    func unlink(directory: Int32, name: String, site: StateSyscallSite) throws
    func rename(directory: Int32, from: String, to: String, site: StateSyscallSite) throws
}

struct SystemStateFileSystemOperations: StateFileSystemOperations {
    func duplicateParent(_ capability: PrivateStateParentCapability, site: StateSyscallSite) throws -> Int32 { try capability.duplicateValidatedDescriptor() }
    func mkdir(directory: Int32, name: String, mode: mode_t, site: StateSyscallSite) throws {
        while true {
            let result = name.withCString { mkdirat(directory, $0, mode) }
            if result == 0 { return }
            if errno == EINTR { continue }
            if errno == EEXIST { throw StateOperationError.alreadyExists }
            throw ProjectStateError.stateUnavailable
        }
    }
    func inspect(directory: Int32, name: String, site: StateSyscallSite) throws -> stat? {
        while true {
            var value = stat()
            let result = name.withCString { fstatat(directory, $0, &value, AT_SYMLINK_NOFOLLOW) }
            if result == 0 { return value }
            if errno == EINTR { continue }
            if errno == ENOENT { return nil }
            throw ProjectStateError.stateUnavailable
        }
    }
    func open(directory: Int32, name: String, flags: Int32, mode: mode_t, site: StateSyscallSite) throws -> Int32 {
        while true {
            let descriptor = name.withCString { openat(directory, $0, flags, mode) }
            if descriptor >= 0 { return descriptor }
            if errno == EINTR { continue }
            if errno == ENOENT { throw StateOperationError.notFound }
            if errno == EEXIST { throw StateOperationError.alreadyExists }
            throw ProjectStateError.stateUnavailable
        }
    }
    func status(descriptor: Int32, site: StateSyscallSite) throws -> stat {
        while true { var value = stat(); if fstat(descriptor, &value) == 0 { return value }; if errno != EINTR { throw ProjectStateError.stateUnavailable } }
    }
    func chmod(descriptor: Int32, mode: mode_t, site: StateSyscallSite) throws {
        while fchmod(descriptor, mode) != 0 { if errno != EINTR { throw ProjectStateError.stateUnavailable } }
    }
    func sync(descriptor: Int32, site: StateSyscallSite) throws {
        while fsync(descriptor) != 0 { if errno != EINTR { throw ProjectStateError.stateUnavailable } }
    }
    func close(descriptor: Int32, site: StateSyscallSite) throws { guard Darwin.close(descriptor) == 0 else { throw ProjectStateError.stateUnavailable } }
    func lock(descriptor: Int32, operation: Int32, site: StateSyscallSite) throws {
        while flock(descriptor, operation) != 0 {
            if errno == EINTR { continue }
            if errno == EWOULDBLOCK { throw StateOperationError.contention }
            throw ProjectStateError.stateUnavailable
        }
    }
    func duplicate(descriptor: Int32, site: StateSyscallSite) throws -> Int32 {
        while true { let fd = fcntl(descriptor, F_DUPFD_CLOEXEC, 0); if fd >= 0 { return fd }; if errno != EINTR { throw ProjectStateError.stateUnavailable } }
    }
    func openDirectoryStream(descriptor: Int32, site: StateSyscallSite) throws -> StateDirectoryStream { guard let pointer = fdopendir(descriptor) else { throw ProjectStateError.stateUnavailable }; return StateDirectoryStream(pointer) }
    func readDirectoryEntry(_ stream: StateDirectoryStream, site: StateSyscallSite) throws -> [UInt8]? {
        errno = 0; guard let entry = readdir(stream.pointer) else { if errno != 0 { throw ProjectStateError.stateUnavailable }; return nil }
        return withUnsafeBytes(of: &entry.pointee.d_name) { raw in Array(raw.prefix { $0 != 0 }) }
    }
    func closeDirectoryStream(_ stream: StateDirectoryStream, site: StateSyscallSite) throws { guard closedir(stream.pointer) == 0 else { throw ProjectStateError.stateUnavailable } }
    func read(descriptor: Int32, count: Int, site: StateSyscallSite) throws -> Data {
        var data = Data(count: count); var offset = 0
        while offset < count { let amount = data.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!.advanced(by: offset), count - offset) }; if amount < 0 && errno == EINTR { continue }; guard amount > 0 else { throw ProjectStateError.invalidState }; offset += amount }
        return data
    }
    func write(descriptor: Int32, data: Data, site: StateSyscallSite) throws {
        var offset = 0
        while offset < data.count { let amount = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset) }; if amount < 0 && errno == EINTR { continue }; guard amount > 0 else { throw ProjectStateError.stateUnavailable }; offset += amount }
    }
    func unlink(directory: Int32, name: String, site: StateSyscallSite) throws {
        while name.withCString({ unlinkat(directory, $0, 0) }) != 0 { if errno != EINTR { throw ProjectStateError.stateUnavailable } }
    }
    func rename(directory: Int32, from: String, to: String, site: StateSyscallSite) throws {
        while from.withCString({ a in to.withCString { b in renameat(directory, a, directory, b) } }) != 0 { if errno != EINTR { throw ProjectStateError.stateUnavailable } }
    }
}
