import Foundation

public protocol ScannerDiagnosticSinking: Sendable {
    func record(_ event: ScannerDiagnosticEvent) async
}

public enum KeyStoreUnavailableReason: Sendable, Equatable {
    case interactionNotAllowed
    case systemFailure
}

public enum StoredKeyRead: Sendable {
    case found(ProjectKeyMaterial)
    case missing
    case invalidRecord
    case unavailable(KeyStoreUnavailableReason)
}

public enum StoredKeyCreate: Sendable {
    case created(ProjectKeyMaterial)
    case existing(ProjectKeyMaterial)
    case invalidRecord
    case unavailable(KeyStoreUnavailableReason)
}

public protocol ProjectKeyMaterialStoring: Sendable {
    func read() async -> StoredKeyRead
    func createIfMissing(_ material: ProjectKeyMaterial) async -> StoredKeyCreate
}

protocol SecureRandomGenerating: Sendable {
    func bytes(count: Int) throws -> Data
}

protocol UUIDGenerating: Sendable {
    func makeUUID() -> UUID
}

public protocol ScannerEnvironmentProviding: Sendable {
    func privateStateParent() throws -> PrivateStateParentCapability
}

public protocol GitFeasibilityProviding: Sendable {
    func currentSnapshot() -> GitFeasibilitySnapshot
}

public enum GitEvidenceExecutionFailure: String, Error, Sendable, Equatable {
    case transportFailed = "transport_failed"
    case timedOut = "timed_out"
    case outputRejected = "output_rejected"
    case descriptorRejected = "descriptor_rejected"
    case operationFailed = "operation_failed"
    case outputLimitExceeded = "output_limit_exceeded"
    case unavailable = "unavailable"
}

public struct GitHeadTreePathEntry: Sendable, Equatable {
    public let path: String
    public let objectID: GitObjectID
    public let objectType: String

    public init(path: String, objectID: GitObjectID, objectType: String) {
        self.path = path
        self.objectID = objectID
        self.objectType = objectType
    }
}

public struct GitEvidenceExecutionRequest: Sendable {
    public let operation: GitEvidenceOperation
    public let context: GitRepositoryContext
    public let descriptorTransfers: [GitMetadataDescriptorTransfer]
    public let catFileObjectIDs: [GitObjectID]

    public init(
        operation: GitEvidenceOperation,
        context: GitRepositoryContext,
        descriptorTransfers: [GitMetadataDescriptorTransfer],
        catFileObjectIDs: [GitObjectID] = []
    ) {
        self.operation = operation
        self.context = context
        self.descriptorTransfers = descriptorTransfers
        self.catFileObjectIDs = catFileObjectIDs
    }
}

public struct GitEvidenceExecutionResponse: Sendable, Equatable {
    public let cachedPaths: [String]
    public let headTreeEntries: [GitHeadTreePathEntry]
    public let catFileBlobBytes: Data

    public init(
        cachedPaths: [String] = [],
        headTreeEntries: [GitHeadTreePathEntry] = [],
        catFileBlobBytes: Data = Data()
    ) {
        self.cachedPaths = cachedPaths
        self.headTreeEntries = headTreeEntries
        self.catFileBlobBytes = catFileBlobBytes
    }
}

public protocol GitEvidenceExecuting: Sendable {
    func execute(_ request: GitEvidenceExecutionRequest) async -> Result<
        GitEvidenceExecutionResponse,
        GitEvidenceExecutionFailure
    >
}

public protocol GitIndexHeadBlobConsuming: Sendable {
    func consumeBlob(
        objectID: GitObjectID,
        path: VerifiedRelativePath,
        bytes: Data
    ) async
}
