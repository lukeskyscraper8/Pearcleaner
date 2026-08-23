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
        try await operationGate.acquire()
        defer { operationGate.release() }
        try throwIfCancelled()

        let read = await store.read()
        try throwIfCancelled()
        switch read {
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
            try throwIfCancelled()
            let created = await store.createIfMissing(proposed)
            switch created {
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
            let proposed = try generateMaterial()
            try throwIfCancelled()
            return .ready(.ephemeral(proposed))
        }
    }

    public func revalidate(_ lease: ProjectKeyLease) async -> ProjectKeyRevalidation {
        guard case .persistent(let generation) = lease.persistence else {
            return .ephemeralOnly
        }
        do {
            try await operationGate.acquire()
        } catch is CancellationError {
            return .ephemeralOnly
        } catch {
            return .ephemeralOnly
        }
        defer { operationGate.release() }
        guard !Task.isCancelled else { return .ephemeralOnly }

        let read = await store.read()
        guard !Task.isCancelled else { return .ephemeralOnly }
        switch read {
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

    private func throwIfCancelled() throws {
        guard !Task.isCancelled else { throw CancellationError() }
    }
}

private final class FIFOOperationGate: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var isHeld = false
    private var waiters: [Waiter] = []

    func acquire() async throws {
        try Task.checkCancellation()
        let waiterID = UUID()
        try await withTaskCancellationHandler(operation: { () async throws -> Void in
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if isHeld {
                    waiters.append(Waiter(id: waiterID, continuation: continuation))
                    lock.unlock()
                } else {
                    isHeld = true
                    lock.unlock()
                    continuation.resume()
                }
            }
        }, onCancel: { [weak self] in
            self?.cancelWaiter(id: waiterID)
        })
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    func release() {
        lock.lock()
        let next = waiters.isEmpty ? nil : waiters.removeFirst().continuation
        if next == nil {
            isHeld = false
        }
        lock.unlock()
        next?.resume()
    }

    private func cancelWaiter(id: UUID) {
        lock.lock()
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        let waiter = waiters.remove(at: index)
        lock.unlock()
        waiter.continuation.resume(throwing: CancellationError())
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
