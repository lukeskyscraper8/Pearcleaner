import Foundation

public enum GitMetadataDescriptorRole: String, Sendable, Equatable, Codable {
    case index
    case sharedIndex = "shared_index"
    case looseObject = "loose_object"
    case packIndex = "pack_index"
    case packData = "pack_data"
    case packReverseIndex = "pack_reverse_index"
}

public struct GitMetadataDescriptor: Sendable, Equatable, Hashable {
    public let role: GitMetadataDescriptorRole
    public let relativePath: VerifiedRelativePath
    public let identity: FileIdentity
    public let objectID: GitObjectID?

    public init(
        role: GitMetadataDescriptorRole,
        relativePath: VerifiedRelativePath,
        identity: FileIdentity,
        objectID: GitObjectID? = nil
    ) {
        self.role = role
        self.relativePath = relativePath
        self.identity = identity
        self.objectID = objectID
    }
}

public struct GitMetadataDescriptorManifest: Sendable, Equatable {
    public let descriptors: [GitMetadataDescriptor]

    public init(descriptors: [GitMetadataDescriptor], descriptorLimit: UInt64) throws {
        guard descriptors.count <= Int(descriptorLimit) else {
            throw GitMetadataManifestError.descriptorBudgetExceeded
        }
        self.descriptors = descriptors
    }
}

public enum GitMetadataManifestError: Error, Sendable, Equatable {
    case descriptorBudgetExceeded
}

public struct GitMetadataDescriptorTransfer: Sendable, Equatable {
    public let descriptor: GitMetadataDescriptor
    public let fileDescriptor: Int32

    public init(descriptor: GitMetadataDescriptor, fileDescriptor: Int32) {
        self.descriptor = descriptor
        self.fileDescriptor = fileDescriptor
    }
}

public enum GitMetadataDescriptorBatchLimits {
    public static let maxDescriptorsPerOperation: UInt64 = 1_024
    public static let descriptorReserve: UInt64 = 128
    public static let maxTransferBatchSize: Int = 32
}
