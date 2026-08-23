import Foundation

enum ProjectKeyCoordinatorError: Error, Sendable, Equatable {
    case keyGenerationFailed
}

public enum ExistingKeyedState: Sendable, Equatable {
    case none
    case generation(UUID)
}

public struct ProjectKeyLease: Sendable {
    public enum Persistence: Sendable, Equatable {
        case persistent(generation: UUID)
        case ephemeral
    }

    let material: ProjectKeyMaterial
    public let persistence: Persistence

    private init(material: ProjectKeyMaterial, persistence: Persistence) {
        self.material = material
        self.persistence = persistence
    }

    static func persistent(_ material: ProjectKeyMaterial) -> Self {
        Self(material: material, persistence: .persistent(generation: material.generation))
    }

    static func ephemeral(_ material: ProjectKeyMaterial) -> Self {
        Self(material: material, persistence: .ephemeral)
    }

    public var permitsPersistentState: Bool {
        if case .persistent = persistence { return true }
        return false
    }

    public var permitsPersistentSuppression: Bool { permitsPersistentState }
}

public enum ProjectKeyAccess: Sendable {
    case ready(ProjectKeyLease)
    case resetRequired
}

public enum ProjectKeyRevalidation: Sendable, Equatable {
    case valid
    case ephemeralOnly
    case resetRequired
}

public actor ProjectKeyCoordinator {
    private let store: any ProjectKeyMaterialStoring
    private let random: any SecureRandomGenerating
    private let uuid: any UUIDGenerating
    private let operationGate = FIFOOperationGate()

    public init(store: any ProjectKeyMaterialStoring) {
        self.store = store
        random = SystemSecureRandom()
        uuid = SystemUUIDGenerator()
    }

    init(
        store: any ProjectKeyMaterialStoring,
        random: any SecureRandomGenerating,
        uuid: any UUIDGenerating
    ) {
        self.store = store
        self.random = random
        self.uuid = uuid
    }

    public func access(for state: ExistingKeyedState) async throws -> ProjectKeyAccess {
        await operationGate.acquire()
        defer { operationGate.release() }

        switch await store.read() {
        case .found(let material):
            switch state {
            case .none:
                return .ready(.persistent(material))
            case .generation(let expected) where expected == material.generation:
                return .ready(.persistent(material))
            case .generation:
                return .resetRequired
            }
        case .missing:
            guard state == .none else { return .resetRequired }
            let proposed = try generateMaterial()
            switch await store.createIfMissing(proposed) {
            case .created(let material), .existing(let material):
                return .ready(.persistent(material))
            case .invalidRecord:
                return .resetRequired
            case .unavailable:
                return .ready(.ephemeral(proposed))
            }
        case .invalidRecord:
            return .resetRequired
        case .unavailable:
            return .ready(.ephemeral(try generateMaterial()))
        }
    }

    public func revalidate(_ lease: ProjectKeyLease) async -> ProjectKeyRevalidation {
        guard case .persistent(let generation) = lease.persistence else {
            return .ephemeralOnly
        }
        await operationGate.acquire()
        defer { operationGate.release() }

        switch await store.read() {
        case .found(let material) where material.generation == generation:
            return .valid
        case .unavailable:
            return .ephemeralOnly
        case .found, .missing, .invalidRecord:
            return .resetRequired
        }
    }

    private func generateMaterial() throws -> ProjectKeyMaterial {
        var bytes: Data
        do {
            bytes = try random.bytes(count: 32)
        } catch {
            throw ProjectKeyCoordinatorError.keyGenerationFailed
        }
        defer {
            if !bytes.isEmpty {
                bytes.resetBytes(in: bytes.startIndex..<bytes.endIndex)
            }
        }
        guard bytes.count == 32 else {
            throw ProjectKeyCoordinatorError.keyGenerationFailed
        }
        do {
            return try ProjectKeyMaterial(generation: uuid.makeUUID(), keyBytes: bytes)
        } catch {
            throw ProjectKeyCoordinatorError.keyGenerationFailed
        }
    }
}

private final class FIFOOperationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isHeld {
                waiters.append(continuation)
            } else {
                isHeld = true
                continuation.resume()
            }
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        let next = waiters.isEmpty ? nil : waiters.removeFirst()
        if next == nil {
            isHeld = false
        }
        lock.unlock()
        next?.resume()
    }
}

private struct SystemSecureRandom: SecureRandomGenerating {
    func bytes(count: Int) throws -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

private struct SystemUUIDGenerator: UUIDGenerating {
    func makeUUID() -> UUID { UUID() }
}
