import Darwin
import Foundation

enum BackupResourceSite: String, CaseIterable, Sendable {
    case getPinnedDirectoryPath, createFileReferenceURL, openInitialFileReference
    case verifyInitialFileReferenceIdentity, setBackupExclusion, clearBackupResourceCache
    case readBackBackupExclusion, reopenAndVerifyFinalIdentity
}

protocol BackupExclusionOperations: Sendable {
    func pinnedPath(descriptor: Int32) throws -> URL
    func fileReference(for path: URL) throws -> BackupFileReference
    func openReference(_ reference: BackupFileReference, site: BackupResourceSite) throws -> Int32
    func verifyIdentity(_ pinned: stat, _ reference: stat, site: BackupResourceSite) throws -> Bool
    func setExcluded(_ reference: BackupFileReference) throws
    func clearCache(_ reference: BackupFileReference) throws
    func readExcluded(_ reference: BackupFileReference) throws -> Bool
}

final class BackupFileReference: @unchecked Sendable {
    private let reference: CFURL

    init(reference: CFURL) { self.reference = reference }

    func resolvedPathURL() throws -> URL {
        var error: Unmanaged<CFError>?
        guard let result = CFURLCreateFilePathURL(nil, reference, &error) else {
            _ = error?.takeRetainedValue()
            throw ProjectStateError.backupExclusionFailed
        }
        return result.takeRetainedValue() as URL
    }
}

struct SystemBackupExclusionOperations: BackupExclusionOperations {
    func pinnedPath(descriptor: Int32) throws -> URL {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { throw ProjectStateError.backupExclusionFailed }
        return URL(fileURLWithFileSystemRepresentation: buffer, isDirectory: true, relativeTo: nil)
    }
    func fileReference(for path: URL) throws -> BackupFileReference {
        var error: Unmanaged<CFError>?
        guard let result = CFURLCreateFileReferenceURL(nil, path as CFURL, &error) else {
            _ = error?.takeRetainedValue()
            throw ProjectStateError.backupExclusionFailed
        }
        let reference = result.takeRetainedValue()
        guard CFURLIsFileReferenceURL(reference) else { throw ProjectStateError.backupExclusionFailed }
        return BackupFileReference(reference: reference)
    }
    func openReference(_ reference: BackupFileReference, site: BackupResourceSite) throws -> Int32 {
        let resolved = try reference.resolvedPathURL()
        let fd = resolved.withUnsafeFileSystemRepresentation { $0.map { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) } ?? -1 }
        guard fd >= 0 else { throw ProjectStateError.backupExclusionFailed }; return fd
    }
    func verifyIdentity(_ pinned: stat, _ reference: stat, site: BackupResourceSite) throws -> Bool { sameDirectory(pinned, reference) }
    func setExcluded(_ reference: BackupFileReference) throws {
        var url = try reference.resolvedPathURL()
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
    func clearCache(_ reference: BackupFileReference) throws {
        var url = try reference.resolvedPathURL()
        url.removeCachedResourceValue(forKey: .isExcludedFromBackupKey)
    }
    func readExcluded(_ reference: BackupFileReference) throws -> Bool {
        try reference.resolvedPathURL().resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
    }
}

enum BackupExclusion {
    static func apply(pinnedDirectory: Int32, state: any StateFileSystemOperations, operations: any BackupExclusionOperations) throws {
        do {
            let pinned = try state.status(descriptor: pinnedDirectory, site: .statPinnedScannerForBackup)
            let reference: BackupFileReference
            do {
                let ephemeralPath = try operations.pinnedPath(descriptor: pinnedDirectory)
                reference = try operations.fileReference(for: ephemeralPath)
            }

            let first = try operations.openReference(reference, site: .openInitialFileReference)
            do {
                let firstStatus = try state.status(descriptor: first, site: .statInitialBackupReference)
                guard try operations.verifyIdentity(pinned, firstStatus, site: .verifyInitialFileReferenceIdentity) else {
                    throw ProjectStateError.backupExclusionFailed
                }
                try state.close(descriptor: first, site: .closeInitialBackupReference)
            } catch {
                closeAfterFailure(first, site: .closeInitialBackupReference, state: state, original: error)
                throw error
            }

            try operations.setExcluded(reference)
            try operations.clearCache(reference)
            guard try operations.readExcluded(reference) else {
                throw ProjectStateError.backupExclusionFailed
            }

            let final = try operations.openReference(reference, site: .reopenAndVerifyFinalIdentity)
            do {
                let finalStatus = try state.status(descriptor: final, site: .statFinalBackupReference)
                guard try operations.verifyIdentity(pinned, finalStatus, site: .reopenAndVerifyFinalIdentity) else {
                    throw ProjectStateError.backupExclusionFailed
                }
                try state.close(descriptor: final, site: .closeFinalBackupReference)
            } catch {
                closeAfterFailure(final, site: .closeFinalBackupReference, state: state, original: error)
                throw error
            }
        } catch let error as ProjectStateError {
            throw error
        } catch let error as StateOperationError {
            throw error
        } catch {
            throw ProjectStateError.backupExclusionFailed
        }
    }

    private static func closeAfterFailure(
        _ descriptor: Int32,
        site: StateSyscallSite,
        state: any StateFileSystemOperations,
        original: Error
    ) {
        if case StateOperationError.failedBefore(let failedSite, _) = original,
           failedSite == site {
            try? SystemStateFileSystemOperations().close(descriptor: descriptor, site: site)
            return
        }
        if case StateOperationError.failedAfterSuccess(let failedSite, _) = original,
           failedSite == site { return }
        if case StateOperationError.stoppedAfterSuccess(let failedSite) = original,
           failedSite == site { return }
        try? state.close(descriptor: descriptor, site: site)
    }
}

private func sameDirectory(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode & S_IFMT == S_IFDIR && rhs.st_mode & S_IFMT == S_IFDIR
}
