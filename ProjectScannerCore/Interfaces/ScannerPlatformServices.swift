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
