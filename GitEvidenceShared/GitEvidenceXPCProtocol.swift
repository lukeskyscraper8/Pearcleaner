import Darwin
import Foundation

public enum GitEvidenceXPCLimits {
    public static let maxTransferBatchSize = 32
    public static let maxOutputPreviewBytes = 4_096
    public static let maxCombinedOutputBytes: UInt64 = 32 * 1_024 * 1_024
}

public enum GitEvidenceXPCOperation: String, Sendable, CaseIterable {
    case listCachedPaths = "list_cached_paths"
    case listHeadTreePaths = "list_head_tree_paths"
    case catFileBatch = "cat_file_batch"
}

public enum GitEvidenceXPCDescriptorRole: String, Sendable, CaseIterable {
    case index
    case sharedIndex = "shared_index"
    case looseObject = "loose_object"
    case packIndex = "pack_index"
    case packData = "pack_data"
    case packReverseIndex = "pack_reverse_index"
}

public enum GitEvidenceXPCObjectHashAlgorithm: String, Sendable {
    case sha1
    case sha256
}

public enum GitEvidenceXPCOperationStatus: String, Sendable {
    case accepted = "accepted"
    case invalidRequest = "invalid_request"
    case descriptorRejected = "descriptor_rejected"
    case notImplemented = "not_implemented"
}

@objc(GitEvidenceXPCFileIdentity)
public final class GitEvidenceXPCFileIdentity: NSObject, NSSecureCoding, Sendable {
    public static let supportsSecureCoding = true

    public let device: UInt64
    public let inode: UInt64
    public let size: UInt64
    public let mode: UInt16
    public let modificationSeconds: Int64
    public let modificationNanoseconds: Int64
    public let statusChangeSeconds: Int64
    public let statusChangeNanoseconds: Int64

    public init(
        device: UInt64,
        inode: UInt64,
        size: UInt64,
        mode: UInt16,
        modificationSeconds: Int64,
        modificationNanoseconds: Int64,
        statusChangeSeconds: Int64,
        statusChangeNanoseconds: Int64
    ) {
        self.device = device
        self.inode = inode
        self.size = size
        self.mode = mode
        self.modificationSeconds = modificationSeconds
        self.modificationNanoseconds = modificationNanoseconds
        self.statusChangeSeconds = statusChangeSeconds
        self.statusChangeNanoseconds = statusChangeNanoseconds
        super.init()
    }

    public convenience init(statBuffer: stat) {
        self.init(
            device: UInt64(statBuffer.st_dev),
            inode: UInt64(statBuffer.st_ino),
            size: UInt64(statBuffer.st_size),
            mode: UInt16(statBuffer.st_mode),
            modificationSeconds: Int64(statBuffer.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(statBuffer.st_mtimespec.tv_nsec),
            statusChangeSeconds: Int64(statBuffer.st_ctimespec.tv_sec),
            statusChangeNanoseconds: Int64(statBuffer.st_ctimespec.tv_nsec)
        )
    }

    public required init?(coder: NSCoder) {
        guard coder.containsValue(forKey: "device"),
              coder.containsValue(forKey: "inode"),
              coder.containsValue(forKey: "size"),
              coder.containsValue(forKey: "mode"),
              coder.containsValue(forKey: "modificationSeconds"),
              coder.containsValue(forKey: "modificationNanoseconds"),
              coder.containsValue(forKey: "statusChangeSeconds"),
              coder.containsValue(forKey: "statusChangeNanoseconds") else {
            return nil
        }

        device = UInt64(coder.decodeInt64(forKey: "device"))
        inode = UInt64(coder.decodeInt64(forKey: "inode"))
        size = UInt64(coder.decodeInt64(forKey: "size"))
        mode = UInt16(coder.decodeInt32(forKey: "mode"))
        modificationSeconds = coder.decodeInt64(forKey: "modificationSeconds")
        modificationNanoseconds = coder.decodeInt64(forKey: "modificationNanoseconds")
        statusChangeSeconds = coder.decodeInt64(forKey: "statusChangeSeconds")
        statusChangeNanoseconds = coder.decodeInt64(forKey: "statusChangeNanoseconds")
        super.init()
    }

    public func encode(with coder: NSCoder) {
        coder.encode(Int64(device), forKey: "device")
        coder.encode(Int64(inode), forKey: "inode")
        coder.encode(Int64(size), forKey: "size")
        coder.encode(Int32(mode), forKey: "mode")
        coder.encode(modificationSeconds, forKey: "modificationSeconds")
        coder.encode(modificationNanoseconds, forKey: "modificationNanoseconds")
        coder.encode(statusChangeSeconds, forKey: "statusChangeSeconds")
        coder.encode(statusChangeNanoseconds, forKey: "statusChangeNanoseconds")
    }
}

@objc(GitEvidenceXPCObjectID)
public final class GitEvidenceXPCObjectID: NSObject, NSSecureCoding, Sendable {
    public static let supportsSecureCoding = true

    public let algorithm: String
    public let hex: String

    public init(algorithm: GitEvidenceXPCObjectHashAlgorithm, hex: String) {
        self.algorithm = algorithm.rawValue
        self.hex = hex
        super.init()
    }

    public required init?(coder: NSCoder) {
        guard let algorithm = coder.decodeObject(of: NSString.self, forKey: "algorithm") as String?,
              let hex = coder.decodeObject(of: NSString.self, forKey: "hex") as String? else {
            return nil
        }
        self.algorithm = algorithm
        self.hex = hex
        super.init()
    }

    public func encode(with coder: NSCoder) {
        coder.encode(algorithm as NSString, forKey: "algorithm")
        coder.encode(hex as NSString, forKey: "hex")
    }
}

@objc(GitEvidenceXPCDescriptorRecord)
public final class GitEvidenceXPCDescriptorRecord: NSObject, NSSecureCoding, Sendable {
    public static let supportsSecureCoding = true

    public let role: String
    public let identity: GitEvidenceXPCFileIdentity
    public let objectID: GitEvidenceXPCObjectID?

    public init(
        role: GitEvidenceXPCDescriptorRole,
        identity: GitEvidenceXPCFileIdentity,
        objectID: GitEvidenceXPCObjectID? = nil
    ) {
        self.role = role.rawValue
        self.identity = identity
        self.objectID = objectID
        super.init()
    }

    public required init?(coder: NSCoder) {
        guard let role = coder.decodeObject(of: NSString.self, forKey: "role") as String?,
              let identity = coder.decodeObject(
                  of: GitEvidenceXPCFileIdentity.self,
                  forKey: "identity"
              ) else {
            return nil
        }
        self.role = role
        self.identity = identity
        objectID = coder.decodeObject(of: GitEvidenceXPCObjectID.self, forKey: "objectID")
        super.init()
    }

    public func encode(with coder: NSCoder) {
        coder.encode(role as NSString, forKey: "role")
        coder.encode(identity, forKey: "identity")
        coder.encode(objectID, forKey: "objectID")
    }
}

@objc(GitEvidenceXPCTransferredDescriptor)
public final class GitEvidenceXPCTransferredDescriptor: NSObject, NSSecureCoding, Sendable {
    public static let supportsSecureCoding = true

    public let record: GitEvidenceXPCDescriptorRecord
    public let fileHandle: FileHandle

    public init(record: GitEvidenceXPCDescriptorRecord, fileHandle: FileHandle) {
        self.record = record
        self.fileHandle = fileHandle
        super.init()
    }

    public required init?(coder: NSCoder) {
        guard let record = coder.decodeObject(
            of: GitEvidenceXPCDescriptorRecord.self,
            forKey: "record"
        ),
        let fileHandle = coder.decodeObject(of: FileHandle.self, forKey: "fileHandle") else {
            return nil
        }
        self.record = record
        self.fileHandle = fileHandle
        super.init()
    }

    public func encode(with coder: NSCoder) {
        coder.encode(record, forKey: "record")
        coder.encode(fileHandle, forKey: "fileHandle")
    }
}

@objc(GitEvidenceXPCRequest)
public final class GitEvidenceXPCRequest: NSObject, NSSecureCoding, Sendable {
    public static let supportsSecureCoding = true

    public let operation: String
    public let headObjectID: GitEvidenceXPCObjectID?
    public let repositoryFormatVersion: Int32
    public let objectHashAlgorithm: String
    public let transferredDescriptors: [GitEvidenceXPCTransferredDescriptor]

    public init(
        operation: GitEvidenceXPCOperation,
        headObjectID: GitEvidenceXPCObjectID?,
        repositoryFormatVersion: Int32,
        objectHashAlgorithm: GitEvidenceXPCObjectHashAlgorithm,
        transferredDescriptors: [GitEvidenceXPCTransferredDescriptor]
    ) throws {
        guard transferredDescriptors.count <= GitEvidenceXPCLimits.maxTransferBatchSize else {
            throw GitEvidenceXPCValidationError.batchTooLarge
        }
        self.operation = operation.rawValue
        self.headObjectID = headObjectID
        self.repositoryFormatVersion = repositoryFormatVersion
        self.objectHashAlgorithm = objectHashAlgorithm.rawValue
        self.transferredDescriptors = transferredDescriptors
        super.init()
    }

    public required init?(coder: NSCoder) {
        guard let operation = coder.decodeObject(of: NSString.self, forKey: "operation") as String?,
              let objectHashAlgorithm = coder.decodeObject(
                  of: NSString.self,
                  forKey: "objectHashAlgorithm"
              ) as String?,
              let transferredDescriptors = coder.decodeObject(
                  of: [GitEvidenceXPCTransferredDescriptor.self, NSArray.self],
                  forKey: "transferredDescriptors"
              ) as? [GitEvidenceXPCTransferredDescriptor] else {
            return nil
        }

        self.operation = operation
        headObjectID = coder.decodeObject(of: GitEvidenceXPCObjectID.self, forKey: "headObjectID")
        repositoryFormatVersion = coder.decodeInt32(forKey: "repositoryFormatVersion")
        self.objectHashAlgorithm = objectHashAlgorithm
        self.transferredDescriptors = transferredDescriptors
        super.init()
    }

    public func encode(with coder: NSCoder) {
        coder.encode(operation as NSString, forKey: "operation")
        coder.encode(headObjectID, forKey: "headObjectID")
        coder.encode(repositoryFormatVersion, forKey: "repositoryFormatVersion")
        coder.encode(objectHashAlgorithm as NSString, forKey: "objectHashAlgorithm")
        coder.encode(transferredDescriptors as NSArray, forKey: "transferredDescriptors")
    }
}

@objc(GitEvidenceXPCOperationResult)
public final class GitEvidenceXPCOperationResult: NSObject, NSSecureCoding, Sendable {
    public static let supportsSecureCoding = true

    public let status: String
    public let stdoutByteCount: UInt64
    public let stderrByteCount: UInt64
    public let stdoutPreview: Data
    public let stderrPreview: Data
    public let blobPipeReadHandle: FileHandle?

    public init(
        status: GitEvidenceXPCOperationStatus,
        stdoutByteCount: UInt64 = 0,
        stderrByteCount: UInt64 = 0,
        stdoutPreview: Data = Data(),
        stderrPreview: Data = Data(),
        blobPipeReadHandle: FileHandle? = nil
    ) {
        self.status = status.rawValue
        self.stdoutByteCount = stdoutByteCount
        self.stderrByteCount = stderrByteCount
        self.stdoutPreview = stdoutPreview.prefix(GitEvidenceXPCLimits.maxOutputPreviewBytes)
        self.stderrPreview = stderrPreview.prefix(GitEvidenceXPCLimits.maxOutputPreviewBytes)
        self.blobPipeReadHandle = blobPipeReadHandle
        super.init()
    }

    public required init?(coder: NSCoder) {
        guard let status = coder.decodeObject(of: NSString.self, forKey: "status") as String?,
              let stdoutPreview = coder.decodeObject(of: NSData.self, forKey: "stdoutPreview") as Data?,
              let stderrPreview = coder.decodeObject(of: NSData.self, forKey: "stderrPreview") as Data? else {
            return nil
        }
        self.status = status
        stdoutByteCount = UInt64(coder.decodeInt64(forKey: "stdoutByteCount"))
        stderrByteCount = UInt64(coder.decodeInt64(forKey: "stderrByteCount"))
        self.stdoutPreview = stdoutPreview
        self.stderrPreview = stderrPreview
        blobPipeReadHandle = coder.decodeObject(of: FileHandle.self, forKey: "blobPipeReadHandle")
        super.init()
    }

    public func encode(with coder: NSCoder) {
        coder.encode(status as NSString, forKey: "status")
        coder.encode(Int64(stdoutByteCount), forKey: "stdoutByteCount")
        coder.encode(Int64(stderrByteCount), forKey: "stderrByteCount")
        coder.encode(stdoutPreview as NSData, forKey: "stdoutPreview")
        coder.encode(stderrPreview as NSData, forKey: "stderrPreview")
        coder.encode(blobPipeReadHandle, forKey: "blobPipeReadHandle")
    }
}

@objc(GitEvidenceXPCReply)
public final class GitEvidenceXPCReply: NSObject, NSSecureCoding, Sendable {
    public static let supportsSecureCoding = true

    public let result: GitEvidenceXPCOperationResult

    public init(result: GitEvidenceXPCOperationResult) {
        self.result = result
        super.init()
    }

    public required init?(coder: NSCoder) {
        guard let result = coder.decodeObject(
            of: GitEvidenceXPCOperationResult.self,
            forKey: "result"
        ) else {
            return nil
        }
        self.result = result
        super.init()
    }

    public func encode(with coder: NSCoder) {
        coder.encode(result, forKey: "result")
    }
}

@objc(GitEvidenceXPCProtocol)
public protocol GitEvidenceXPCProtocol {
    func perform(
        _ request: GitEvidenceXPCRequest,
        reply: @escaping (GitEvidenceXPCReply?, NSError?) -> Void
    )
}

public enum GitEvidenceXPCValidationError: Error, Sendable, Equatable {
    case batchTooLarge
    case unknownOperation
    case invalidDescriptor
    case notReadOnly
    case notRegularFile
    case identityMismatch
}

public enum GitEvidenceXPCInterfaceConfigurator {
    private static func requestClasses() -> Set<AnyHashable> {
        NSSet(array: [
            GitEvidenceXPCRequest.self,
            GitEvidenceXPCTransferredDescriptor.self,
            GitEvidenceXPCDescriptorRecord.self,
            GitEvidenceXPCFileIdentity.self,
            GitEvidenceXPCObjectID.self,
            FileHandle.self,
            NSData.self,
            NSString.self,
            NSNumber.self,
            NSArray.self,
        ]) as! Set<AnyHashable>
    }

    private static func replyClasses() -> Set<AnyHashable> {
        NSSet(array: [
            GitEvidenceXPCReply.self,
            GitEvidenceXPCOperationResult.self,
            GitEvidenceXPCFileIdentity.self,
            GitEvidenceXPCObjectID.self,
            FileHandle.self,
            NSData.self,
            NSString.self,
            NSNumber.self,
            NSArray.self,
        ]) as! Set<AnyHashable>
    }

    public static func apply(to interface: NSXPCInterface, isRemote: Bool) {
        _ = isRemote
        let selector = #selector(GitEvidenceXPCProtocol.perform(_:reply:))
        interface.setClasses(requestClasses(), for: selector, argumentIndex: 0, ofReply: false)
        interface.setClasses(replyClasses(), for: selector, argumentIndex: 0, ofReply: true)
    }
}

public enum GitEvidenceXPCConnectionFactory {
    public static func embeddedServiceURL(in bundle: Bundle = .main) -> URL? {
        let xpcServicesURL = bundle.bundleURL
            .appendingPathComponent("Contents/XPCServices", isDirectory: true)
            .appendingPathComponent("GitEvidenceService.xpc", isDirectory: true)
        if FileManager.default.fileExists(atPath: xpcServicesURL.path) {
            return xpcServicesURL
        }

        return bundle.builtInPlugInsURL?
            .appendingPathComponent("GitEvidenceService.xpc", isDirectory: true)
    }

    public static func makeClientConnection(serviceURL: URL) -> NSXPCConnection {
        _ = serviceURL
        let connection = NSXPCConnection(
            serviceName: GitEvidenceServiceIdentity.serviceBundleIdentifier
        )
        connection.setCodeSigningRequirement(GitEvidenceServiceIdentity.serviceRequirement)
        let interface = NSXPCInterface(with: GitEvidenceXPCProtocol.self)
        GitEvidenceXPCInterfaceConfigurator.apply(to: interface, isRemote: true)
        connection.remoteObjectInterface = interface
        return connection
    }
}
