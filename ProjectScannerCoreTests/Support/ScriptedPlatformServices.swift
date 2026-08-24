import Darwin
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

enum ScriptedStateDescriptorRole: Sendable, Equatable {
    case privateStateParent
    case sharedDirectory
    case scannerDirectory
    case transactionLock
    case scannerEnumeration
    case recoveredStagingFile
    case stateFile
    case stagingFile
    case untracked
}

struct ScriptedStateSyncEvent: Sendable, Equatable {
    let site: StateSyscallSite
    let role: ScriptedStateDescriptorRole
}

final class ScriptedStateFileSystemOperations: StateFileSystemOperations, @unchecked Sendable {
    struct ProducerCleanup: Equatable, Sendable {
        let producer: StateSyscallSite
        let cleanup: StateSyscallSite
    }

    private let lock = NSLock()
    private let failingSite: StateSyscallSite?
    private let failure: ScriptedStateFailure?
    private let failureOccurrence: Int
    private let repeatedBusySite: StateSyscallSite?
    private let busyStartingOccurrence: Int
    private let failUnlockCleanupAfterAcquiredFailure: Bool
    private let recycleClosedDescriptor: Bool
    private let opaqueDispatchedCloseSite: StateSyscallSite?
    private let opaqueDispatchedCloseOccurrence: Int
    private let mutateCurrentStagingModeBeforeReinspect: Bool
    private let mutatePriorStagingAfterNextReinspect: Bool
    private let exerciseLockReplacementRetryRace: Bool
    private var siteCounts: [StateSyscallSite: Int] = [:]
    private var events: [StateSyscallSite] = []
    private var descriptorRoles: [Int32: ScriptedStateDescriptorRole] = [:]
    private var syncEvents: [ScriptedStateSyncEvent] = []
    private var producerCleanups: [ProducerCleanup] = []
    private var pendingUnlockCleanupFailure = false
    private var recycledDescriptors: Set<Int32> = []
    private var opaqueClosedStreams: Set<ObjectIdentifier> = []
    private var opaqueDirectoryStreamWasRetried = false
    private var currentStagingModeWasMutated = false
    private var priorStagingName: String?
    private var priorStagingMutationAttempted = false
    private var priorStagingEntryWasMutated = false
    private var capturedLockDirectoryDescriptor: Int32?
    private let reached = DispatchSemaphore(value: 0)

    init(
        failingSite: StateSyscallSite? = nil,
        failure: ScriptedStateFailure? = nil,
        failureOccurrence: Int = 1,
        repeatedBusySite: StateSyscallSite? = nil,
        busyStartingOccurrence: Int = 1,
        failUnlockCleanupAfterAcquiredFailure: Bool = false,
        recycleClosedDescriptor: Bool = false,
        opaqueDispatchedCloseSite: StateSyscallSite? = nil,
        opaqueDispatchedCloseOccurrence: Int = 1,
        mutateCurrentStagingModeBeforeReinspect: Bool = false,
        mutatePriorStagingAfterNextReinspect: Bool = false,
        exerciseLockReplacementRetryRace: Bool = false
    ) {
        self.failingSite = failingSite
        self.failure = failure
        self.failureOccurrence = failureOccurrence
        self.repeatedBusySite = repeatedBusySite
        self.busyStartingOccurrence = busyStartingOccurrence
        self.failUnlockCleanupAfterAcquiredFailure = failUnlockCleanupAfterAcquiredFailure
        self.recycleClosedDescriptor = recycleClosedDescriptor
        self.opaqueDispatchedCloseSite = opaqueDispatchedCloseSite
        self.opaqueDispatchedCloseOccurrence = opaqueDispatchedCloseOccurrence
        self.mutateCurrentStagingModeBeforeReinspect = mutateCurrentStagingModeBeforeReinspect
        self.mutatePriorStagingAfterNextReinspect = mutatePriorStagingAfterNextReinspect
        self.exerciseLockReplacementRetryRace = exerciseLockReplacementRetryRace
    }

    func snapshot() -> [StateSyscallSite] { lock.withLock { events } }
    func syncSnapshot() -> [ScriptedStateSyncEvent] { lock.withLock { syncEvents } }
    func cleanupSnapshot() -> [ProducerCleanup] { lock.withLock { producerCleanups } }
    func priorStagingEntryWasMutatedBeforeUnlink() -> Bool {
        lock.withLock { priorStagingEntryWasMutated }
    }
    func consumeRecycledDescriptorsWereOpen() -> Bool {
        let descriptors = lock.withLock { () -> [Int32] in
            let result = Array(recycledDescriptors)
            recycledDescriptors.removeAll()
            return result
        }
        guard !descriptors.isEmpty else { return false }
        var allOpen = true
        for descriptor in descriptors {
            errno = 0
            if fcntl(descriptor, F_GETFD) == -1 && errno == EBADF { allOpen = false }
            else { _ = Darwin.close(descriptor) }
        }
        return allOpen
    }
    func consumeOpaqueDirectoryStreamWasRetried() -> Bool {
        lock.withLock {
            let result = opaqueDirectoryStreamWasRetried
            opaqueDirectoryStreamWasRetried = false
            return result
        }
    }
    func waitUntilReached(timeout: TimeInterval) -> Bool { reached.wait(timeout: .now() + timeout) == .success }
    func waitUntil(_ site: StateSyscallSite, count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if lock.withLock({ events.filter { $0 == site }.count >= count }) { return true }
            usleep(1_000)
        }
        return false
    }

    private func begin(_ site: StateSyscallSite) throws -> ScriptedStateFailure? {
        lock.withLock { events.append(site) }
        reached.signal()
        let occurrence = lock.withLock { siteCounts[site, default: 0] += 1; return siteCounts[site]! }
        if site == repeatedBusySite && occurrence >= busyStartingOccurrence { throw StateOperationError.contention }
        let shouldFail = site == failingSite && occurrence == failureOccurrence
        if shouldFail, case .failBefore(let code) = failure {
            throw StateOperationError.failedBefore(site, code)
        }
        return shouldFail ? failure : nil
    }

    private func finish(_ site: StateSyscallSite, failure: ScriptedStateFailure?) throws {
        if case .failAfterSuccess(let code) = failure { throw StateOperationError.failedAfterSuccess(site, code) }
        if case .stopAfterSuccess = failure { throw StateOperationError.stoppedAfterSuccess(site) }
    }

    private func call<T>(_ site: StateSyscallSite, _ body: () throws -> T) throws -> T {
        let selected = try begin(site)
        let value = try body()
        try finish(site, failure: selected)
        return value
    }

    func duplicateParent(_ capability: PrivateStateParentCapability, site: StateSyscallSite) throws -> Int32 {
        let selected = try begin(site); let descriptor = try SystemStateFileSystemOperations().duplicateParent(capability, site: site)
        recordRole(.privateStateParent, descriptor: descriptor)
        do { try finish(site, failure: selected); return descriptor } catch { cleanupDescriptor(descriptor, producingSite: site); throw error }
    }
    func mkdir(directory: Int32, name: String, mode: mode_t, site: StateSyscallSite) throws { try call(site) { try SystemStateFileSystemOperations().mkdir(directory: directory, name: name, mode: mode, site: site) } }
    func inspect(directory: Int32, name: String, site: StateSyscallSite) throws -> stat? {
        if site == .inspectLockBeforeAcquire, exerciseLockReplacementRetryRace {
            lock.withLock { capturedLockDirectoryDescriptor = directory }
        }
        if site == .reinspectStagingEntryBeforeUnlink {
            var currentNameToMutate: String?
            var priorNameToMutate: String?
            lock.withLock {
                if mutateCurrentStagingModeBeforeReinspect && !currentStagingModeWasMutated {
                    currentStagingModeWasMutated = true
                    currentNameToMutate = name
                }
                if mutatePriorStagingAfterNextReinspect {
                    if priorStagingName == nil {
                        priorStagingName = name
                    } else if !priorStagingMutationAttempted {
                        priorStagingMutationAttempted = true
                        priorNameToMutate = priorStagingName
                    }
                }
            }
            if let currentNameToMutate {
                _ = try changeModeIfPresent(directory: directory, name: currentNameToMutate, mode: 0o644)
            }
            if let priorNameToMutate {
                let changed = try changeModeIfPresent(directory: directory, name: priorNameToMutate, mode: 0o644)
                lock.withLock { priorStagingEntryWasMutated = changed }
            }
        }
        return try call(site) {
            try SystemStateFileSystemOperations().inspect(directory: directory, name: name, site: site)
        }
    }
    func open(directory: Int32, name: String, flags: Int32, mode: mode_t, site: StateSyscallSite) throws -> Int32 {
        let selected = try begin(site); let descriptor = try SystemStateFileSystemOperations().open(directory: directory, name: name, flags: flags, mode: mode, site: site)
        recordRole(roleProduced(at: site), descriptor: descriptor)
        do { try finish(site, failure: selected); return descriptor } catch { cleanupDescriptor(descriptor, producingSite: site); throw error }
    }
    func status(descriptor: Int32, site: StateSyscallSite) throws -> stat { try call(site) { try SystemStateFileSystemOperations().status(descriptor: descriptor, site: site) } }
    func chmod(descriptor: Int32, mode: mode_t, site: StateSyscallSite) throws { try call(site) { try SystemStateFileSystemOperations().chmod(descriptor: descriptor, mode: mode, site: site) } }
    func sync(descriptor: Int32, site: StateSyscallSite) throws {
        let selected = try begin(site)
        try SystemStateFileSystemOperations().sync(descriptor: descriptor, site: site)
        let role = lock.withLock { descriptorRoles[descriptor] ?? .untracked }
        lock.withLock { syncEvents.append(.init(site: site, role: role)) }
        try finish(site, failure: selected)
    }
    func close(descriptor: Int32, site: StateSyscallSite) throws {
        let selected = try begin(site)
        try SystemStateFileSystemOperations().close(descriptor: descriptor, site: site)
        removeRole(descriptor)
        let opaqueFailure = isOpaqueDispatchedClose(site)
        if recycleClosedDescriptor,
           selected?.succeededBeforeFailure == true || opaqueFailure {
            try recycleDescriptor(descriptor)
        }
        if opaqueFailure { throw ProjectStateError.stateUnavailable }
        try finish(site, failure: selected)
    }
    func lock(descriptor: Int32, operation: Int32, site: StateSyscallSite) throws {
        if exerciseLockReplacementRetryRace,
           site == .acquireTransactionLock,
           operation & LOCK_EX != 0 {
            let nextOccurrence = lock.withLock { siteCounts[site, default: 0] + 1 }
            if nextOccurrence == 2 {
                _ = try begin(site)
                try replaceLockEntryForRetryRace()
                throw StateOperationError.contention
            }
            if nextOccurrence == 3 {
                let selected = try begin(site)
                try SystemStateFileSystemOperations().lock(
                    descriptor: descriptor, operation: operation, site: site
                )
                try restoreLockEntryAfterRetryRace()
                try finish(site, failure: selected)
                return
            }
        }
        if operation == LOCK_UN {
            let shouldFail = lock.withLock { () -> Bool in
                guard pendingUnlockCleanupFailure else { return false }
                pendingUnlockCleanupFailure = false
                return true
            }
            if shouldFail {
                _ = try begin(site)
                throw StateOperationError.failedBefore(site, EIO)
            }
        }
        do {
            try call(site) {
                try SystemStateFileSystemOperations().lock(
                    descriptor: descriptor, operation: operation, site: site
                )
            }
        } catch StateOperationError.failedAfterSuccess(_, let code) where operation & LOCK_EX != 0 {
            markAcquiredCleanupFailureIfNeeded()
            throw StateOperationError.acquiredThenFailed(code)
        } catch StateOperationError.stoppedAfterSuccess where operation & LOCK_EX != 0 {
            markAcquiredCleanupFailureIfNeeded()
            throw StateOperationError.acquiredThenFailed(EIO)
        }
    }
    func duplicate(descriptor: Int32, site: StateSyscallSite) throws -> Int32 {
        let selected = try begin(site); let result = try SystemStateFileSystemOperations().duplicate(descriptor: descriptor, site: site)
        recordRole(.scannerEnumeration, descriptor: result)
        do { try finish(site, failure: selected); return result } catch { cleanupDescriptor(result, producingSite: site); throw error }
    }
    func openDirectoryStream(descriptor: Int32, site: StateSyscallSite) throws -> StateDirectoryStream {
        let selected = try begin(site); let stream = try SystemStateFileSystemOperations().openDirectoryStream(descriptor: descriptor, site: site)
        removeRole(descriptor)
        do { try finish(site, failure: selected); return stream } catch {
            lock.withLock { events.append(.closeStagingDirectoryStream) }
            if (try? SystemStateFileSystemOperations().closeDirectoryStream(stream, site: .closeStagingDirectoryStream)) != nil {
                recordCleanup(producer: site, cleanup: .closeStagingDirectoryStream)
            }
            throw error
        }
    }
    func readDirectoryEntry(_ stream: StateDirectoryStream, site: StateSyscallSite) throws -> [UInt8]? { try call(site) { try SystemStateFileSystemOperations().readDirectoryEntry(stream, site: site) } }
    func closeDirectoryStream(_ stream: StateDirectoryStream, site: StateSyscallSite) throws {
        let identifier = ObjectIdentifier(stream)
        if lock.withLock({ opaqueClosedStreams.contains(identifier) }) {
            _ = try begin(site)
            lock.withLock { opaqueDirectoryStreamWasRetried = true }
            throw ProjectStateError.stateUnavailable
        }
        let selected = try begin(site)
        try SystemStateFileSystemOperations().closeDirectoryStream(stream, site: site)
        if isOpaqueDispatchedClose(site) {
            lock.withLock { _ = opaqueClosedStreams.insert(identifier) }
            throw ProjectStateError.stateUnavailable
        }
        try finish(site, failure: selected)
    }
    func read(descriptor: Int32, count: Int, site: StateSyscallSite) throws -> Data { try call(site) { try SystemStateFileSystemOperations().read(descriptor: descriptor, count: count, site: site) } }
    func write(descriptor: Int32, data: Data, site: StateSyscallSite) throws { try call(site) { try SystemStateFileSystemOperations().write(descriptor: descriptor, data: data, site: site) } }
    func unlink(directory: Int32, name: String, site: StateSyscallSite) throws { try call(site) { try SystemStateFileSystemOperations().unlink(directory: directory, name: name, site: site) } }
    func rename(directory: Int32, from: String, to: String, site: StateSyscallSite) throws { try call(site) { try SystemStateFileSystemOperations().rename(directory: directory, from: from, to: to, site: site) } }

    private func cleanupDescriptor(_ descriptor: Int32, producingSite: StateSyscallSite) {
        let cleanupSite: StateSyscallSite
        switch producingSite {
        case .duplicatePrivateStateParent: cleanupSite = .closeParentDirectory
        case .openSharedDirectory: cleanupSite = .closeSharedDirectory
        case .openScannerDirectory: cleanupSite = .closeScannerDirectory
        case .createLockFile, .openExistingLockFile: cleanupSite = .closeLockFile
        case .duplicateScannerForEnumeration: cleanupSite = .closeScannerDirectory
        case .openStagingEntry: cleanupSite = .closeRecoveredStagingEntry
        case .openStateFileForRead: cleanupSite = .closeStateFileAfterRead
        case .createStagingFile: cleanupSite = .closeStagingFileAfterFailure
        default: cleanupSite = .closeScannerDirectory
        }
        lock.withLock { events.append(cleanupSite) }
        if (try? SystemStateFileSystemOperations().close(descriptor: descriptor, site: cleanupSite)) != nil {
            removeRole(descriptor)
            recordCleanup(producer: producingSite, cleanup: cleanupSite)
        }
    }

    private func recordCleanup(producer: StateSyscallSite, cleanup: StateSyscallSite) {
        lock.withLock { producerCleanups.append(.init(producer: producer, cleanup: cleanup)) }
    }

    private func isOpaqueDispatchedClose(_ site: StateSyscallSite) -> Bool {
        lock.withLock {
            site == opaqueDispatchedCloseSite
                && siteCounts[site] == opaqueDispatchedCloseOccurrence
        }
    }

    private func roleProduced(at site: StateSyscallSite) -> ScriptedStateDescriptorRole {
        switch site {
        case .openSharedDirectory: return .sharedDirectory
        case .openScannerDirectory: return .scannerDirectory
        case .createLockFile, .openExistingLockFile: return .transactionLock
        case .openStagingEntry: return .recoveredStagingFile
        case .openStateFileForRead: return .stateFile
        case .createStagingFile: return .stagingFile
        default: return .untracked
        }
    }

    private func recordRole(_ role: ScriptedStateDescriptorRole, descriptor: Int32) {
        lock.withLock { descriptorRoles[descriptor] = role }
    }

    private func removeRole(_ descriptor: Int32) {
        _ = lock.withLock { descriptorRoles.removeValue(forKey: descriptor) }
    }

    private func markAcquiredCleanupFailureIfNeeded() {
        guard failUnlockCleanupAfterAcquiredFailure else { return }
        lock.withLock { pendingUnlockCleanupFailure = true }
    }

    private func changeModeIfPresent(
        directory: Int32,
        name: String,
        mode: mode_t
    ) throws -> Bool {
        let system = SystemStateFileSystemOperations()
        let descriptor: Int32
        do {
            descriptor = try system.open(
                directory: directory, name: name,
                flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
                mode: 0, site: .openStagingEntry
            )
        } catch StateOperationError.notFound {
            return false
        }
        defer { try? system.close(descriptor: descriptor, site: .closeRecoveredStagingEntry) }
        try system.chmod(descriptor: descriptor, mode: mode, site: .statStagingEntry)
        return true
    }

    private func recycleDescriptor(_ descriptor: Int32) throws {
        let temporary = Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
        guard temporary >= 0 else { throw ProjectStateError.stateUnavailable }
        if temporary != descriptor {
            guard dup2(temporary, descriptor) == descriptor else {
                _ = Darwin.close(temporary)
                throw ProjectStateError.stateUnavailable
            }
            _ = Darwin.close(temporary)
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        }
        _ = lock.withLock { recycledDescriptors.insert(descriptor) }
    }

    private func replaceLockEntryForRetryRace() throws {
        guard let directory = lock.withLock({ capturedLockDirectoryDescriptor }) else {
            throw ProjectStateError.stateUnavailable
        }
        let system = SystemStateFileSystemOperations()
        try system.rename(
            directory: directory, from: ".state.lock",
            to: ".state.lock.retry-race-original", site: .acquireTransactionLock
        )
        let replacement = try system.open(
            directory: directory, name: ".state.lock",
            flags: O_RDWR | O_NONBLOCK | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode: 0o600, site: .acquireTransactionLock
        )
        try system.chmod(descriptor: replacement, mode: 0o600, site: .acquireTransactionLock)
        try system.close(descriptor: replacement, site: .closeLockFile)
    }

    private func restoreLockEntryAfterRetryRace() throws {
        guard let directory = lock.withLock({ capturedLockDirectoryDescriptor }) else {
            throw ProjectStateError.stateUnavailable
        }
        let system = SystemStateFileSystemOperations()
        try system.unlink(
            directory: directory, name: ".state.lock", site: .acquireTransactionLock
        )
        try system.rename(
            directory: directory, from: ".state.lock.retry-race-original",
            to: ".state.lock", site: .acquireTransactionLock
        )
    }
}

private extension ScriptedStateFailure {
    var succeededBeforeFailure: Bool {
        switch self {
        case .failBefore: false
        case .failAfterSuccess, .stopAfterSuccess: true
        }
    }
}

enum ScriptedBackupMutation: Sendable { case none, renameAfterReference, replaceBeforeReference }

final class ScriptedBackupExclusionOperations: BackupExclusionOperations, @unchecked Sendable {
    private let lock = NSLock()
    private let failingSite: BackupResourceSite?
    private let failureOccurrence: Int
    private let mutation: ScriptedBackupMutation
    private var events: [BackupResourceSite] = []
    private var siteCounts: [BackupResourceSite: Int] = [:]

    init(
        failingSite: BackupResourceSite? = nil,
        failureOccurrence: Int = 1,
        mutation: ScriptedBackupMutation = .none
    ) {
        self.failingSite = failingSite
        self.failureOccurrence = failureOccurrence
        self.mutation = mutation
    }

    private func visit(_ site: BackupResourceSite) throws {
        let occurrence = lock.withLock { () -> Int in
            events.append(site)
            siteCounts[site, default: 0] += 1
            return siteCounts[site]!
        }
        if site == failingSite, occurrence == failureOccurrence {
            throw ProjectStateError.backupExclusionFailed
        }
    }

    func snapshot() -> [BackupResourceSite] { lock.withLock { events } }

    func pinnedPath(descriptor: Int32) throws -> URL { try visit(.getPinnedDirectoryPath); return try SystemBackupExclusionOperations().pinnedPath(descriptor: descriptor) }
    func fileReference(for path: URL) throws -> BackupFileReference {
        try visit(.createFileReferenceURL)
        switch mutation {
        case .none: return try SystemBackupExclusionOperations().fileReference(for: path)
        case .renameAfterReference:
            let reference = try SystemBackupExclusionOperations().fileReference(for: path)
            try FileManager.default.moveItem(at: path, to: path.deletingLastPathComponent().appendingPathComponent("renamed-pinned"))
            return reference
        case .replaceBeforeReference:
            let moved = path.deletingLastPathComponent().appendingPathComponent("original-pinned")
            try FileManager.default.moveItem(at: path, to: moved)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
            return try SystemBackupExclusionOperations().fileReference(for: path)
        }
    }
    func openReference(_ reference: BackupFileReference, site: BackupResourceSite) throws -> Int32 { try visit(site); return try SystemBackupExclusionOperations().openReference(reference, site: site) }
    func verifyIdentity(_ pinned: stat, _ reference: stat, site: BackupResourceSite) throws -> Bool { try visit(site); return try SystemBackupExclusionOperations().verifyIdentity(pinned, reference, site: site) }
    func setExcluded(_ reference: BackupFileReference) throws { try visit(.setBackupExclusion); try SystemBackupExclusionOperations().setExcluded(reference) }
    func clearCache(_ reference: BackupFileReference) throws { try visit(.clearBackupResourceCache); try SystemBackupExclusionOperations().clearCache(reference) }
    func readExcluded(_ reference: BackupFileReference) throws -> Bool { try visit(.readBackBackupExclusion); return try SystemBackupExclusionOperations().readExcluded(reference) }
}

final class StateStoreFixture {
    let parentURL: URL
    let selectedRoot: URL
    let outsideCanary: URL
    let outsideSnapshot: Data
    let projectUUID: UUID
    let stagingUUID: UUID
    let generation: UUID
    let parent: PrivateStateParentCapability
    let coordinator: ProjectKeyCoordinator
    let lease: ProjectKeyLease
    let bookmark: ProjectBookmark
    let uuid: ScriptedUUID
    let store: ProjectStateStore

    var stateDirectory: URL { parentURL.appendingPathComponent("Pearcleaner/ProjectScanner", isDirectory: true) }
    var stateFile: URL { stateDirectory.appendingPathComponent("project-\(projectUUID.uuidString.lowercased()).json") }

    static func make(
        operations: any StateFileSystemOperations = SystemStateFileSystemOperations(),
        backupOperations: any BackupExclusionOperations = SystemBackupExclusionOperations(),
        prepare: ((URL) throws -> Void)? = nil,
        projectUUID: UUID = UUID(uuidString: "abcdefab-cdef-4abc-8def-abcdefabcdef")!
    ) async throws -> StateStoreFixture {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectStateTests-\(UUID().uuidString)", isDirectory: true)
        let parentURL = container.appendingPathComponent("Application Support", isDirectory: true)
        let selected = container.appendingPathComponent("Selected Project", isDirectory: true)
        let outside = container.appendingPathComponent("outside-canary", isDirectory: false)
        try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let allCanaries = Data(PrivacyCanaries.all.joined(separator: "|").utf8)
        try allCanaries.write(to: selected.appendingPathComponent("privacy-marker"))
        try allCanaries.write(to: outside)
        try prepare?(parentURL)
        let parent = try PrivateStateParentCapability.open(applicationSupportURL: parentURL)
        let generation = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let material = try ProjectKeyMaterial(generation: generation, keyBytes: Data(repeating: 0xA5, count: 32))
        let keyStore = ScriptedKeyStore(stored: material)
        let coordinator = ProjectKeyCoordinator(store: keyStore)
        let lease = ProjectKeyLease.persistent(material)
        let stagingUUID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let uuids = [projectUUID, stagingUUID] + (0..<80).map { _ in UUID() }
        let uuid = ScriptedUUID(uuids)
        let store = try await ProjectStateStore(
            parent: parent,
            keyCoordinator: coordinator,
            uuid: uuid,
            operations: operations,
            backupOperations: backupOperations
        )
        return try StateStoreFixture(
            parentURL: parentURL, selectedRoot: selected, outsideCanary: outside,
            projectUUID: projectUUID, stagingUUID: stagingUUID, generation: generation,
            parent: parent, coordinator: coordinator, lease: lease,
            bookmark: ProjectBookmarkPersistence.decode(testBookmarkBytes(payload: Data((selected.path + "\0" + PrivacyCanaries.path).utf8))),
            uuid: uuid,
            store: store
        )
    }

    private init(parentURL: URL, selectedRoot: URL, outsideCanary: URL, projectUUID: UUID,
                 stagingUUID: UUID, generation: UUID, parent: PrivateStateParentCapability,
                 coordinator: ProjectKeyCoordinator, lease: ProjectKeyLease,
                 bookmark: ProjectBookmark, uuid: ScriptedUUID,
                 store: ProjectStateStore) {
        self.parentURL = parentURL; self.selectedRoot = selectedRoot; self.outsideCanary = outsideCanary
        outsideSnapshot = (try? Data(contentsOf: outsideCanary)) ?? Data()
        self.projectUUID = projectUUID; self.stagingUUID = stagingUUID; self.generation = generation
        self.parent = parent; self.coordinator = coordinator; self.lease = lease
        self.bookmark = bookmark; self.uuid = uuid; self.store = store
    }

    func register(label: String? = nil, overrides: ScanLimitOverrides = .init()) async throws -> ProjectRegistration {
        try await store.register(label: label, bookmark: bookmark, limitOverrides: overrides, lease: lease)
    }

    func remove() {
        parent.close()
        try? FileManager.default.removeItem(at: parentURL.deletingLastPathComponent())
    }
}

func testBookmarkBytes(payload: Data = Data([0xAA])) -> Data {
    var result = Data([0x50,0x53,0x42,0x4D,0x01, 0,0,0,0,0,0,0,1, 0,0,0,0,0,0,0,2, 0x40,0])
    let length = UInt32(payload.count).bigEndian
    withUnsafeBytes(of: length) { result.append(contentsOf: $0) }
    result.append(payload)
    return result
}

func completeCoverage(advisory: AdvisoryCoverageMetadata? = nil) -> ScanCoverageSnapshot {
    let advisory = advisory ?? testAdvisoryMetadata()
    let detectors = DetectorID.allCases.map { detector in
        DetectorCoverageSnapshot(
            transactionID: CoverageTransactionID(rawValue: UUID()), detector: detector,
            terminalState: .complete, candidateFiles: 1, scannedFiles: 1,
            skippedFiles: 0, unsupportedFiles: 0, failedFiles: 0,
            candidateBytes: 4, scannedBytes: 4, skippedBytes: 0,
            unsupportedBytes: 0, failedBytes: 0, reasonCounts: [:],
            details: detector == .advisory ? [.advisory(advisory)] : []
        )
    }
    return ScanCoverageSnapshot(sessionID: ScanSessionID(rawValue: UUID()), terminalState: .complete, detectors: detectors)
}

func testAdvisoryMetadata() -> AdvisoryCoverageMetadata {
    AdvisoryCoverageMetadata(
        generation: UUID(uuidString: "77777777-7777-4777-8777-777777777777")!,
        source: .osv, ageSeconds: 60,
        lastSuccessfulRefresh: Date(timeIntervalSince1970: 1),
        activatedAt: Date(timeIntervalSince1970: 1), validation: .complete
    )
}

func testAttemptMetadata() throws -> AttemptSummaryMetadata {
    try AttemptSummaryMetadata(advisoryCacheSchemaVersion: 1, advisory: testAdvisoryMetadata())
}

func completeCoverageWithAdvisoryDetails(_ details: [AdvisoryCoverageMetadata]) -> ScanCoverageSnapshot {
    let base = completeCoverage()
    let detectors = base.detectors.map { detector -> DetectorCoverageSnapshot in
        guard detector.detector == .advisory else { return detector }
        return DetectorCoverageSnapshot(
            transactionID: detector.transactionID, detector: detector.detector,
            terminalState: detector.terminalState, candidateFiles: detector.candidateFiles,
            scannedFiles: detector.scannedFiles, skippedFiles: detector.skippedFiles,
            unsupportedFiles: detector.unsupportedFiles, failedFiles: detector.failedFiles,
            candidateBytes: detector.candidateBytes, scannedBytes: detector.scannedBytes,
            skippedBytes: detector.skippedBytes, unsupportedBytes: detector.unsupportedBytes,
            failedBytes: detector.failedBytes, reasonCounts: detector.reasonCounts,
            details: details.map { .advisory($0) }
        )
    }
    return ScanCoverageSnapshot(sessionID: base.sessionID, terminalState: base.terminalState, detectors: detectors)
}

func nonCompleteCoverage(_ state: ScanTerminalState) -> ScanCoverageSnapshot {
    let detectorState: DetectorTerminalState = state == .cancelled ? .cancelled : state == .failed ? .failed : state == .unavailable ? .unavailable : .partial
    let detectors = DetectorID.allCases.map { detector in
        DetectorCoverageSnapshot(
            transactionID: CoverageTransactionID(rawValue: UUID()), detector: detector,
            terminalState: detectorState, candidateFiles: 1, scannedFiles: 0,
            skippedFiles: 1, unsupportedFiles: 0, failedFiles: 0,
            candidateBytes: 4, scannedBytes: 0, skippedBytes: 4,
            unsupportedBytes: 0, failedBytes: 0, reasonCounts: [.cancelled: 1], details: []
        )
    }
    return ScanCoverageSnapshot(sessionID: ScanSessionID(rawValue: UUID()), terminalState: state, detectors: detectors)
}

func modeBits(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

func seedUniqueSuppressions(in stateFile: URL, count: Int) throws {
    var object = try (JSONSerialization.jsonObject(with: Data(contentsOf: stateFile)) as? [String: Any]).unwrapStateFixture()
    let template = try ((object["suppressions"] as? [[String: Any]])?.first).unwrapStateFixture()
    object["suppressions"] = (0..<count).map { index -> [String: Any] in
        var record = template
        var bytes = Data(repeating: 0, count: 32)
        withUnsafeBytes(of: UInt64(index).bigEndian) { bytes.replaceSubrange(24..<32, with: $0) }
        record["fingerprint"] = bytes.base64EncodedString()
        return record
    }
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: stateFile)
    _ = chmod(stateFile.path, 0o600)
}

private extension Optional {
    func unwrapStateFixture() throws -> Wrapped {
        guard let self else { throw ProjectStateError.invalidState }
        return self
    }
}
