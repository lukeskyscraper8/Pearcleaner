import Darwin
import Foundation

public enum GitEvidenceDescriptorValidator {
    public static func validateReadOnlyRegularFile(
        fileDescriptor: Int32,
        expectedIdentity: GitEvidenceXPCFileIdentity
    ) throws -> GitEvidenceXPCFileIdentity {
        guard fileDescriptor >= 0 else {
            throw GitEvidenceXPCValidationError.invalidDescriptor
        }

        let flags = fcntl(fileDescriptor, F_GETFL)
        guard flags >= 0 else {
            throw GitEvidenceXPCValidationError.invalidDescriptor
        }
        guard (flags & O_ACCMODE) == O_RDONLY else {
            throw GitEvidenceXPCValidationError.notReadOnly
        }

        var statBuffer = stat()
        guard fstat(fileDescriptor, &statBuffer) == 0 else {
            throw GitEvidenceXPCValidationError.invalidDescriptor
        }
        guard (statBuffer.st_mode & S_IFMT) == S_IFREG else {
            throw GitEvidenceXPCValidationError.notRegularFile
        }

        let actualIdentity = GitEvidenceXPCFileIdentity(statBuffer: statBuffer)
        guard actualIdentity.matches(expectedIdentity) else {
            throw GitEvidenceXPCValidationError.identityMismatch
        }

        return actualIdentity
    }

    public static func isReadOnly(fileDescriptor: Int32) -> Bool {
        guard fileDescriptor >= 0 else {
            return false
        }
        let flags = fcntl(fileDescriptor, F_GETFL)
        guard flags >= 0 else {
            return false
        }
        return (flags & O_ACCMODE) == O_RDONLY
    }
}

public extension GitEvidenceXPCFileIdentity {
    func matches(_ other: GitEvidenceXPCFileIdentity) -> Bool {
        device == other.device
            && inode == other.inode
            && size == other.size
            && mode == other.mode
            && modificationSeconds == other.modificationSeconds
            && modificationNanoseconds == other.modificationNanoseconds
            && statusChangeSeconds == other.statusChangeSeconds
            && statusChangeNanoseconds == other.statusChangeNanoseconds
    }
}
