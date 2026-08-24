import Darwin
import Foundation

enum AtomicStateWriteOutcome: Sendable, Equatable {
    case committed
    case committedDurabilityUncertain
}

final class AtomicStateFile: @unchecked Sendable {
    static let maximumPayloadBytes = 8 * 1_024 * 1_024

    private let operations: any StateFileSystemOperations
    private let descriptorLock = NSLock()
    private var scannerDescriptor: Int32

    private init(scannerDescriptor: Int32, operations: any StateFileSystemOperations) {
        self.scannerDescriptor = scannerDescriptor
        self.operations = operations
    }

    static func open(
        parent: PrivateStateParentCapability,
        operations: any StateFileSystemOperations,
        backupOperations: any BackupExclusionOperations
    ) throws -> AtomicStateFile {
        var parentDescriptor: Int32?
        var sharedDescriptor: Int32?
        var scannerDescriptor: Int32?
        do {
            parentDescriptor = try operations.duplicateParent(parent, site: .duplicatePrivateStateParent)
            let shared = try openDirectory(
                parent: parentDescriptor!, name: "Pearcleaner", existingMode: .ownerControlled,
                createSite: .createSharedDirectory, inspectSite: .inspectSharedDirectory,
                openSite: .openSharedDirectory,
                initialStatusSite: .statSharedDirectoryBeforeModeAdjustment,
                chmodSite: .chmodNewSharedDirectory,
                finalStatusSite: .statSharedDirectoryAfterModeAdjustment,
                childSyncSite: .syncNewSharedDirectory,
                parentSyncSite: .syncParentAfterSharedDirectory,
                operations: operations
            )
            sharedDescriptor = shared
            try closeOwned(&parentDescriptor, site: .closeParentDirectory, operations: operations)

            let scanner = try openDirectory(
                parent: shared, name: "ProjectScanner", existingMode: .exact0700,
                createSite: .createScannerDirectory, inspectSite: .inspectScannerDirectory,
                openSite: .openScannerDirectory,
                initialStatusSite: .statScannerDirectoryBeforeModeAdjustment,
                chmodSite: .chmodNewScannerDirectory,
                finalStatusSite: .statScannerDirectoryAfterModeAdjustment,
                childSyncSite: .syncNewScannerDirectory,
                parentSyncSite: .syncSharedAfterScannerDirectory,
                operations: operations
            )
            scannerDescriptor = scanner
            try closeOwned(&sharedDescriptor, site: .closeSharedDirectory, operations: operations)
            try BackupExclusion.apply(
                pinnedDirectory: scanner,
                state: operations,
                operations: backupOperations
            )
            scannerDescriptor = nil
            return AtomicStateFile(scannerDescriptor: scanner, operations: operations)
        } catch {
            closeAfterFailure(&scannerDescriptor, site: .closeScannerDirectory, operations: operations)
            closeAfterFailure(&sharedDescriptor, site: .closeSharedDirectory, operations: operations)
            closeAfterFailure(&parentDescriptor, site: .closeParentDirectory, operations: operations)
            throw closedStateError(error)
        }
    }

    func retainedDirectoryDescriptor() throws -> Int32 {
        try descriptorLock.withLock {
            guard scannerDescriptor >= 0 else { throw ProjectStateError.stateUnavailable }
            return scannerDescriptor
        }
    }

    func inspect(name: String, site: StateSyscallSite) throws -> stat? {
        try operations.inspect(directory: retainedDirectoryDescriptor(), name: name, site: site)
    }

    func read(name: String) throws -> Data? {
        let directory = try retainedDirectoryDescriptor()
        let descriptor: Int32
        do {
            descriptor = try operations.open(
                directory: directory, name: name,
                flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
                mode: 0, site: .openStateFileForRead
            )
        } catch StateOperationError.notFound {
            return nil
        } catch {
            throw closedReadError(error)
        }

        var owned = true
        do {
            let before = try operations.status(descriptor: descriptor, site: .statStateFileBeforeRead)
            try validateStateFile(before)
            guard before.st_size >= 0,
                  let count = Int(exactly: before.st_size),
                  count <= Self.maximumPayloadBytes else { throw ProjectStateError.invalidState }
            let data = try operations.read(descriptor: descriptor, count: count, site: .readStateFile)
            let after = try operations.status(descriptor: descriptor, site: .statStateFileAfterRead)
            guard sameReadSnapshot(before, after) else { throw ProjectStateError.invalidState }
            try operations.close(descriptor: descriptor, site: .closeStateFileAfterRead)
            owned = false
            return data
        } catch {
            if closeSucceeded(error, at: .closeStateFileAfterRead) { owned = false }
            if owned {
                closeDescriptorAfterFailure(
                    descriptor, site: .closeStateFileAfterRead,
                    operations: operations, original: error
                )
            }
            throw closedReadError(error)
        }
    }

    func write(data: Data, destinationName: String, stagingUUID: UUID) throws -> AtomicStateWriteOutcome {
        guard data.count <= Self.maximumPayloadBytes else { throw ProjectStateError.invalidInput }
        let directory = try retainedDirectoryDescriptor()
        let temporaryName = ".state-\(stagingUUID.uuidString.lowercased()).tmp"
        var descriptor: Int32?
        var stagingExists = false
        var commitCrossed = false

        do {
            do {
                descriptor = try operations.open(
                    directory: directory, name: temporaryName,
                    flags: O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    mode: 0o600, site: .createStagingFile
                )
                stagingExists = true
            } catch {
                if operationSucceeded(error, at: .createStagingFile) { stagingExists = true }
                throw error
            }

            try operations.chmod(descriptor: descriptor!, mode: 0o600, site: .chmodStagingFile)
            let status = try operations.status(descriptor: descriptor!, site: .statStagingFile)
            try validateRegularOwned(status, exactMode: 0o600, invalid: .stateUnavailable)
            try operations.write(descriptor: descriptor!, data: data, site: .writeStagingFile)
            try operations.sync(descriptor: descriptor!, site: .syncStagingFile)
            do {
                try operations.close(descriptor: descriptor!, site: .closeStagingFileBeforeRename)
                descriptor = nil
            } catch {
                if closeSucceeded(error, at: .closeStagingFileBeforeRename) { descriptor = nil }
                throw error
            }

            do {
                try operations.rename(
                    directory: directory, from: temporaryName,
                    to: destinationName, site: .renameStagingFile
                )
                commitCrossed = true
                stagingExists = false
            } catch {
                if operationSucceeded(error, at: .renameStagingFile) {
                    commitCrossed = true
                    stagingExists = false
                    return .committedDurabilityUncertain
                }
                throw error
            }

            do { try operations.sync(descriptor: directory, site: .syncScannerAfterRename) }
            catch { return .committedDurabilityUncertain }
            return .committed
        } catch {
            if !commitCrossed {
                if let openDescriptor = descriptor {
                    closeDescriptorAfterFailure(
                        openDescriptor, site: .closeStagingFileAfterFailure,
                        operations: operations, original: error
                    )
                    descriptor = nil
                }
                if stagingExists {
                    try? operations.unlink(
                        directory: directory, name: temporaryName,
                        site: .unlinkStagingFileAfterFailure
                    )
                }
            }
            throw closedStateError(error)
        }
    }

    func removeValidatedStagingFiles() throws {
        let directory = try retainedDirectoryDescriptor()
        let duplicate: Int32
        do { duplicate = try operations.duplicate(descriptor: directory, site: .duplicateScannerForEnumeration) }
        catch { throw closedStateError(error) }

        let stream: StateDirectoryStream
        do { stream = try operations.openDirectoryStream(descriptor: duplicate, site: .openStagingDirectoryStream) }
        catch {
            if !operationSucceeded(error, at: .openStagingDirectoryStream) {
                closeDescriptorAfterFailure(
                    duplicate, site: .closeScannerDirectory,
                    operations: operations, original: error
                )
            }
            throw closedStateError(error)
        }

        var streamOpen = true
        var entries = StateStagingEntryAccumulator()
        do {
            while let bytes = try operations.readDirectoryEntry(stream, site: .readStagingDirectoryEntry) {
                try entries.consume(bytes)
            }
            try operations.closeDirectoryStream(stream, site: .closeStagingDirectoryStream)
            streamOpen = false
        } catch {
            if closeSucceeded(error, at: .closeStagingDirectoryStream) { streamOpen = false }
            if streamOpen { closeStreamAfterFailure(stream, operations: operations, original: error) }
            throw closedStateError(error)
        }

        var validated: [(String, StateStableIdentity)] = []
        validated.reserveCapacity(entries.candidates.count)
        for name in entries.candidates {
            let inspected = try operations.inspect(directory: directory, name: name, site: .inspectStagingEntry)
            guard let inspected else { throw ProjectStateError.stateUnavailable }
            let entry: Int32
            do {
                entry = try operations.open(
                    directory: directory, name: name,
                    flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
                    mode: 0, site: .openStagingEntry
                )
            } catch { throw closedStateError(error) }
            var entryOpen = true
            do {
                let opened = try operations.status(descriptor: entry, site: .statStagingEntry)
                try validateRegularOwned(opened, exactMode: 0o600, invalid: .stateUnavailable)
                guard sameObject(inspected, opened) else { throw ProjectStateError.stateUnavailable }
                try operations.close(descriptor: entry, site: .closeRecoveredStagingEntry)
                entryOpen = false
                validated.append((name, StateStableIdentity(opened)))
            } catch {
                if closeSucceeded(error, at: .closeRecoveredStagingEntry) { entryOpen = false }
                if entryOpen {
                    closeDescriptorAfterFailure(
                        entry, site: .closeRecoveredStagingEntry,
                        operations: operations, original: error
                    )
                }
                throw closedStateError(error)
            }
        }

        for (name, identity) in validated {
            let current = try operations.inspect(
                directory: directory, name: name,
                site: .reinspectStagingEntryBeforeUnlink
            )
            guard let current else { throw ProjectStateError.stateUnavailable }
            try validateRegularOwned(current, exactMode: 0o600, invalid: .stateUnavailable)
            guard identity.matches(current) else { throw ProjectStateError.stateUnavailable }
            try operations.unlink(directory: directory, name: name, site: .unlinkRecoveredStagingEntry)
        }
    }

    func close() {
        let descriptor = descriptorLock.withLock { () -> Int32 in
            let current = scannerDescriptor
            scannerDescriptor = -1
            return current
        }
        guard descriptor >= 0 else { return }
        do { try operations.close(descriptor: descriptor, site: .closeScannerDirectory) }
        catch {
            if !closeSucceeded(error, at: .closeScannerDirectory) {
                try? SystemStateFileSystemOperations().close(
                    descriptor: descriptor, site: .closeScannerDirectory
                )
            }
        }
    }

    deinit { close() }
}

private enum ExistingDirectoryMode { case ownerControlled, exact0700 }

private struct StateStableIdentity: Sendable, Equatable {
    let device: dev_t
    let inode: ino_t
    let type: mode_t

    init(_ status: stat) {
        device = status.st_dev
        inode = status.st_ino
        type = status.st_mode & S_IFMT
    }

    func matches(_ status: stat) -> Bool {
        device == status.st_dev && inode == status.st_ino && type == status.st_mode & S_IFMT
    }
}

private func openDirectory(
    parent: Int32,
    name: String,
    existingMode: ExistingDirectoryMode,
    createSite: StateSyscallSite,
    inspectSite: StateSyscallSite,
    openSite: StateSyscallSite,
    initialStatusSite: StateSyscallSite,
    chmodSite: StateSyscallSite,
    finalStatusSite: StateSyscallSite,
    childSyncSite: StateSyscallSite,
    parentSyncSite: StateSyscallSite,
    operations: any StateFileSystemOperations
) throws -> Int32 {
    var inspected = try operations.inspect(directory: parent, name: name, site: inspectSite)
    let created = inspected == nil
    if created {
        try operations.mkdir(directory: parent, name: name, mode: 0o700, site: createSite)
        inspected = try operations.inspect(directory: parent, name: name, site: inspectSite)
    }
    guard let inspected else { throw ProjectStateError.stateUnavailable }
    let descriptor = try operations.open(
        directory: parent, name: name,
        flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
        mode: 0, site: openSite
    )
    do {
        let opened = try operations.status(descriptor: descriptor, site: initialStatusSite)
        guard sameObject(inspected, opened) else { throw ProjectStateError.stateUnavailable }
        try validateDirectoryOwned(opened)
        if created {
            try operations.chmod(descriptor: descriptor, mode: 0o700, site: chmodSite)
            let final = try operations.status(descriptor: descriptor, site: finalStatusSite)
            try validateDirectoryOwned(final)
            guard permissionBits(final) == 0o700 else { throw ProjectStateError.stateUnavailable }
            try operations.sync(descriptor: descriptor, site: childSyncSite)
            try operations.sync(descriptor: parent, site: parentSyncSite)
        } else {
            switch existingMode {
            case .ownerControlled:
                guard opened.st_mode & 0o022 == 0 else { throw ProjectStateError.stateUnavailable }
            case .exact0700:
                guard permissionBits(opened) == 0o700 else { throw ProjectStateError.stateUnavailable }
            }
        }
        return descriptor
    } catch {
        closeDescriptorAfterFailure(
            descriptor,
            site: openSite == .openSharedDirectory ? .closeSharedDirectory : .closeScannerDirectory,
            operations: operations,
            original: error
        )
        throw error
    }
}

private func validateDirectoryOwned(_ status: stat) throws {
    guard status.st_mode & S_IFMT == S_IFDIR, status.st_uid == geteuid() else {
        throw ProjectStateError.stateUnavailable
    }
}

private func validateStateFile(_ status: stat) throws {
    try validateRegularOwned(status, exactMode: 0o600, invalid: .invalidState)
}

private func validateRegularOwned(
    _ status: stat,
    exactMode: mode_t,
    invalid: ProjectStateError
) throws {
    guard status.st_mode & S_IFMT == S_IFREG,
          status.st_uid == geteuid(),
          permissionBits(status) == exactMode else { throw invalid }
}

private func permissionBits(_ status: stat) -> mode_t { status.st_mode & 0o7777 }

private func sameObject(_ lhs: stat, _ rhs: stat) -> Bool {
    StateStableIdentity(lhs).matches(rhs)
}

private func sameReadSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
    sameObject(lhs, rhs)
        && lhs.st_size == rhs.st_size
        && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
        && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
        && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
        && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
}

struct StateStagingEntryAccumulator {
    private(set) var entryCount = 0
    private(set) var candidates: [String] = []

    mutating func consume(_ bytes: [UInt8]) throws {
        if bytes == [0x2E] || bytes == [0x2E, 0x2E] { return }
        entryCount += 1
        guard entryCount <= 4_096 else { throw ProjectStateError.stateUnavailable }
        guard let name = String(bytes: bytes, encoding: .utf8), isStagingName(name) else {
            return
        }
        candidates.append(name)
        guard candidates.count <= 128 else { throw ProjectStateError.stateUnavailable }
    }
}

func isStagingName(_ name: String) -> Bool {
    let bytes = Array(name.utf8)
    let prefix = Array(".state-".utf8)
    let suffix = Array(".tmp".utf8)
    guard bytes.count == 47,
          bytes[..<prefix.count].elementsEqual(prefix),
          bytes[(bytes.count - suffix.count)...].elementsEqual(suffix),
          let value = String(
              bytes: bytes[prefix.count..<(bytes.count - suffix.count)],
              encoding: .ascii
          ) else { return false }
    guard let uuid = UUID(uuidString: value) else { return false }
    return value == uuid.uuidString.lowercased()
}

private func closeOwned(
    _ descriptor: inout Int32?,
    site: StateSyscallSite,
    operations: any StateFileSystemOperations
) throws {
    guard let current = descriptor else { return }
    do {
        try operations.close(descriptor: current, site: site)
        descriptor = nil
    } catch {
        if !closeSucceeded(error, at: site) {
            try? SystemStateFileSystemOperations().close(descriptor: current, site: site)
        }
        descriptor = nil
        throw error
    }
}

private func closeAfterFailure(
    _ descriptor: inout Int32?,
    site: StateSyscallSite,
    operations: any StateFileSystemOperations
) {
    guard let current = descriptor else { return }
    try? operations.close(descriptor: current, site: site)
    descriptor = nil
}

private func closeDescriptorAfterFailure(
    _ descriptor: Int32,
    site: StateSyscallSite,
    operations: any StateFileSystemOperations,
    original: Error
) {
    if closeSucceeded(original, at: site) { return }
    if case StateOperationError.failedBefore(let failedSite, _) = original, failedSite == site {
        try? SystemStateFileSystemOperations().close(descriptor: descriptor, site: site)
        return
    }
    do { try operations.close(descriptor: descriptor, site: site) }
    catch {
        if !closeSucceeded(error, at: site) {
            try? SystemStateFileSystemOperations().close(descriptor: descriptor, site: site)
        }
    }
}

private func closeStreamAfterFailure(
    _ stream: StateDirectoryStream,
    operations: any StateFileSystemOperations,
    original: Error
) {
    if closeSucceeded(original, at: .closeStagingDirectoryStream) { return }
    if case StateOperationError.failedBefore(let site, _) = original,
       site == .closeStagingDirectoryStream {
        try? SystemStateFileSystemOperations().closeDirectoryStream(
            stream, site: .closeStagingDirectoryStream
        )
        return
    }
    try? operations.closeDirectoryStream(stream, site: .closeStagingDirectoryStream)
}

private func closeSucceeded(_ error: Error, at site: StateSyscallSite) -> Bool {
    if case StateOperationError.failedAfterSuccess(let failedSite, _) = error { return failedSite == site }
    if case StateOperationError.stoppedAfterSuccess(let failedSite) = error { return failedSite == site }
    return false
}

private func operationSucceeded(_ error: Error, at site: StateSyscallSite) -> Bool {
    closeSucceeded(error, at: site)
}

private func closedReadError(_ error: Error) -> ProjectStateError {
    if let state = error as? ProjectStateError, state == .invalidState { return .invalidState }
    return .invalidState
}

func closedStateError(_ error: Error) -> ProjectStateError {
    if let state = error as? ProjectStateError { return state }
    if error is CancellationError { return .cancelled }
    return .stateUnavailable
}
