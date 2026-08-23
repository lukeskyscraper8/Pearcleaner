import Foundation
@testable import ProjectScannerCore

enum ScriptedStoreCall: Sendable, Equatable {
    case read
    case create(generation: UUID)
}

enum ScriptedReadStep: Sendable {
    case fixed(StoredKeyRead)
    case current
}

enum ScriptedCreateStep: Sendable {
    case fixed(StoredKeyCreate)
    case installOrExisting
}

actor ScriptedKeyStore: ProjectKeyMaterialStoring {
    private var stored: ProjectKeyMaterial?
    private var reads: [ScriptedReadStep]
    private var creates: [ScriptedCreateStep]
    private var calls: [ScriptedStoreCall] = []
    private var activeOperations = 0
    private var maximumConcurrentOperations = 0
    private var firstReadPaused = false
    private var firstReadReached = false
    private var firstReadWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstReadTimedWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var firstReadResume: CheckedContinuation<Void, Never>?
    private var firstCreatePaused = false
    private var firstCreateReached = false
    private var firstCreateTimedWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var firstCreateResume: CheckedContinuation<Void, Never>?

    init(
        stored: ProjectKeyMaterial? = nil,
        reads: [ScriptedReadStep] = [],
        creates: [ScriptedCreateStep] = [],
        pauseFirstRead: Bool = false,
        pauseFirstCreate: Bool = false
    ) {
        self.stored = stored
        self.reads = reads
        self.creates = creates
        firstReadPaused = pauseFirstRead
        firstCreatePaused = pauseFirstCreate
    }

    func read() async -> StoredKeyRead {
        beginOperation()
        defer { endOperation() }
        calls.append(.read)
        let result = reads.isEmpty ? currentRead() : readNext()
        if firstReadPaused && !firstReadReached {
            firstReadReached = true
            let waiters = firstReadWaiters
            firstReadWaiters.removeAll()
            waiters.forEach { $0.resume() }
            let timedWaiters = firstReadTimedWaiters.values
            firstReadTimedWaiters.removeAll()
            timedWaiters.forEach { $0.resume(returning: true) }
            await withCheckedContinuation { firstReadResume = $0 }
        }
        return result
    }

    func createIfMissing(_ material: ProjectKeyMaterial) async -> StoredKeyCreate {
        beginOperation()
        defer { endOperation() }
        calls.append(.create(generation: material.generation))
        if firstCreatePaused && !firstCreateReached {
            firstCreateReached = true
            let timedWaiters = firstCreateTimedWaiters.values
            firstCreateTimedWaiters.removeAll()
            timedWaiters.forEach { $0.resume(returning: true) }
            await withCheckedContinuation { firstCreateResume = $0 }
        }
        if !creates.isEmpty {
            switch creates.removeFirst() {
            case .fixed(let result): return result
            case .installOrExisting: break
            }
        }
        if let stored { return .existing(stored) }
        stored = material
        return .created(material)
    }

    func waitUntilFirstReadPaused() async {
        guard !firstReadReached else { return }
        await withCheckedContinuation { firstReadWaiters.append($0) }
    }

    func waitUntilFirstReadPaused(timeoutNanoseconds: UInt64) async -> Bool {
        guard !firstReadReached else { return true }
        let token = UUID()
        return await withCheckedContinuation { continuation in
            firstReadTimedWaiters[token] = continuation
            Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                self.timeoutFirstReadWaiter(token)
            }
        }
    }

    func resumeFirstRead() {
        firstReadPaused = false
        let continuation = firstReadResume
        firstReadResume = nil
        continuation?.resume()
    }

    func waitUntilFirstCreatePaused(timeoutNanoseconds: UInt64) async -> Bool {
        guard !firstCreateReached else { return true }
        let token = UUID()
        return await withCheckedContinuation { continuation in
            firstCreateTimedWaiters[token] = continuation
            Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                self.timeoutFirstCreateWaiter(token)
            }
        }
    }

    func resumeFirstCreate() {
        firstCreatePaused = false
        let continuation = firstCreateResume
        firstCreateResume = nil
        continuation?.resume()
    }

    func createCallCount() -> Int {
        calls.reduce(into: 0) { count, call in
            if case .create = call { count += 1 }
        }
    }

    private func timeoutFirstReadWaiter(_ token: UUID) {
        firstReadTimedWaiters.removeValue(forKey: token)?.resume(returning: false)
    }

    private func timeoutFirstCreateWaiter(_ token: UUID) {
        firstCreateTimedWaiters.removeValue(forKey: token)?.resume(returning: false)
    }

    func snapshot() -> (calls: [ScriptedStoreCall], stored: ProjectKeyMaterial?, maximumConcurrent: Int) {
        (calls, stored, maximumConcurrentOperations)
    }

    private func currentRead() -> StoredKeyRead {
        if let stored { return .found(stored) }
        return .missing
    }

    private func readNext() -> StoredKeyRead {
        switch reads.removeFirst() {
        case .fixed(let result): return result
        case .current: return currentRead()
        }
    }

    private func beginOperation() {
        activeOperations += 1
        maximumConcurrentOperations = max(maximumConcurrentOperations, activeOperations)
    }

    private func endOperation() { activeOperations -= 1 }
}

enum ScriptedRandomStep: Sendable {
    case bytes(Data)
    case failure
}

final class ScriptedRandom: SecureRandomGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [ScriptedRandomStep]
    private var requestedCounts: [Int] = []

    init(_ steps: [ScriptedRandomStep]) { self.steps = steps }

    func bytes(count: Int) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        requestedCounts.append(count)
        guard !steps.isEmpty else { throw ScriptedRandomFailure() }
        switch steps.removeFirst() {
        case .bytes(let bytes): return bytes
        case .failure: throw ScriptedRandomFailure()
        }
    }

    func snapshotRequestedCounts() -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return requestedCounts
    }
}

private struct ScriptedRandomFailure: Error {}

final class ScriptedUUID: UUIDGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID]
    private var callCount = 0

    init(_ values: [UUID]) { self.values = values }

    func makeUUID() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        callCount += 1
        return values.removeFirst()
    }

    func snapshotCallCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }
}

actor AsyncStartMarker {
    private var reached = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        reached = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        guard !reached else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
