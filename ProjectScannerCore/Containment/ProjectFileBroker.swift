import Darwin
import Foundation

public enum ContainmentError: Error, CaseIterable, Sendable, Equatable {
    case invalidSelection
    case rootIsLink
    case notDirectory
    case openFailed
    case identityChanged
    case mountBoundary
    case closedCapability
    case brokerAlreadyIssued
    case pathTooLong

    var coverageReasonCode: CoverageReasonCode {
        switch self {
        case .invalidSelection, .openFailed, .closedCapability, .brokerAlreadyIssued:
            .unreadable
        case .rootIsLink:
            .externalBoundary
        case .notDirectory:
            .specialFile
        case .identityChanged:
            .identityChanged
        case .mountBoundary:
            .mountBoundary
        case .pathTooLong:
            .pathTooLong
        }
    }
}

public struct FileIdentity: Sendable, Equatable, Hashable {
    public let device: UInt64
    public let inode: UInt64
    public let size: UInt64
    public let mode: UInt16
    public let modificationSeconds: Int64
    public let modificationNanoseconds: Int64
    public let statusChangeSeconds: Int64
    public let statusChangeNanoseconds: Int64

    init(_ value: stat) throws {
        guard let device = UInt64(exactly: value.st_dev),
              let inode = UInt64(exactly: value.st_ino),
              let size = UInt64(exactly: value.st_size),
              let mode = UInt16(exactly: value.st_mode),
              let modificationSeconds = Int64(exactly: value.st_mtimespec.tv_sec),
              let modificationNanoseconds = Int64(exactly: value.st_mtimespec.tv_nsec),
              let statusChangeSeconds = Int64(exactly: value.st_ctimespec.tv_sec),
              let statusChangeNanoseconds = Int64(exactly: value.st_ctimespec.tv_nsec),
              modificationSeconds >= 0,
              modificationNanoseconds >= 0,
              statusChangeSeconds >= 0,
              statusChangeNanoseconds >= 0 else {
            throw ContainmentError.identityChanged
        }

        self.device = device
        self.inode = inode
        self.size = size
        self.mode = mode
        self.modificationSeconds = modificationSeconds
        self.modificationNanoseconds = modificationNanoseconds
        self.statusChangeSeconds = statusChangeSeconds
        self.statusChangeNanoseconds = statusChangeNanoseconds
    }
}

// Descriptor-bearing owners release this marker only after their descriptor is closed.
protocol DescriptorLifetime: AnyObject, Sendable {}

fileprivate final class OwnedFileDescriptor: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32
    private let accounting: DescriptorAccounting?
    private var descriptorLifetime: (any DescriptorLifetime)?

    init(
        taking value: Int32,
        accounting: DescriptorAccounting? = nil,
        descriptorLifetime: (any DescriptorLifetime)? = nil
    ) throws {
        guard value >= 0 else { throw ContainmentError.openFailed }
        self.value = value
        self.accounting = accounting
        self.descriptorLifetime = descriptorLifetime
        accounting?.retain()
    }

    deinit {
        closeIfNeeded()
    }

    func duplicate(accounting: DescriptorAccounting? = nil) throws -> OwnedFileDescriptor {
        try lock.withLock {
            guard value >= 0 else { throw ContainmentError.closedCapability }
            let duplicate = fcntl(value, F_DUPFD_CLOEXEC, 0)
            guard duplicate >= 0 else { throw ContainmentError.openFailed }
            return try OwnedFileDescriptor(
                taking: duplicate,
                accounting: accounting,
                descriptorLifetime: descriptorLifetime
            )
        }
    }

    func bindDescriptorLifetime(_ lifetime: any DescriptorLifetime) {
        lock.withLock {
            precondition(value >= 0)
            precondition(descriptorLifetime == nil)
            descriptorLifetime = lifetime
        }
    }

    func withFileDescriptor<T>(_ body: (Int32) throws -> T) throws -> T {
        try lock.withLock {
            guard value >= 0 else { throw ContainmentError.closedCapability }
            return try body(value)
        }
    }

    func take() throws -> Int32 {
        try lock.withLock {
            guard value >= 0 else { throw ContainmentError.closedCapability }
            defer { value = -1 }
            return value
        }
    }

    func closeIfNeeded() {
        let releasedLifetime = lock.withLock { () -> (any DescriptorLifetime)? in
            guard value >= 0 else { return nil }
            Darwin.close(value)
            value = -1
            accounting?.release()
            defer { descriptorLifetime = nil }
            return descriptorLifetime
        }
        withExtendedLifetime(releasedLifetime) {}
    }
}

fileprivate final class DescriptorAccounting: @unchecked Sendable {
    private let lock = NSLock()
    private var openCount: UInt64 = 0

    func retain() {
        lock.withLock { openCount += 1 }
    }

    func release() {
        lock.withLock {
            precondition(openCount > 0)
            openCount -= 1
        }
    }

    func snapshot() -> UInt64 {
        lock.withLock { openCount }
    }
}

enum FileBrokerError: Error, Sendable, Equatable {
    case traversalAlreadyIssued
}

enum CandidateRevalidation: Sendable, Equatable {
    case valid
    case rejected(CoverageReasonCode)
}

struct TraversalSummary: Sendable, Equatable {
    let entriesVisited: UInt64
    let directoriesOpened: UInt64
    let candidatesProduced: UInt64
    let skipsProduced: UInt64
    let openDirectoryDescriptorCount: UInt64
    let cancelled: Bool
    let finished: Bool
}

fileprivate struct LinkProof: Sendable, Equatable, Hashable {
    let logicalLocation: VerifiedRelativePath
    let physicalComponents: [Data]
    let inspectedIdentity: FileIdentity
    let targetBytes: Data
}

fileprivate struct FileAccessToken: Sendable, Equatable, Hashable {
    let brokerNonce: UUID
    let physicalComponents: [Data]
    let expectedIdentity: FileIdentity
    let linkProof: [LinkProof]
}

struct FileCandidate: Sendable, Equatable {
    let logicalPath: VerifiedRelativePath
    let identity: FileIdentity
    let byteCount: UInt64
    fileprivate let accessToken: FileAccessToken

    fileprivate init(
        logicalPath: VerifiedRelativePath,
        identity: FileIdentity,
        byteCount: UInt64,
        accessToken: FileAccessToken
    ) {
        self.logicalPath = logicalPath
        self.identity = identity
        self.byteCount = byteCount
        self.accessToken = accessToken
    }
}

enum TraversalEvent: Sendable, Equatable {
    case candidate(FileCandidate)
    case skipped(location: SkippedTraversalLocation, reason: CoverageReasonCode)
}

enum SkippedTraversalLocation: Sendable, Equatable {
    case verified(VerifiedRelativePath)
    case unrepresentable(parent: VerifiedRelativePath?, escapedLeaf: EscapedDisplayPath?)
}

enum FileBrokerTestPoint: Sendable, Hashable {
    case afterDirectoryEntryRead
    case afterEntryInspection
    case afterSymlinkInspection
    case afterSymlinkTargetRead
    case afterProofReplay
}

actor FileBrokerTestControl {
    private var armed: [FileBrokerTestPoint: UInt64]
    private var occurrences: [FileBrokerTestPoint: UInt64] = [:]
    private var reached: Set<FileBrokerTestPoint> = []
    private var waiters: [FileBrokerTestPoint: [CheckedContinuation<Void, Never>]] = [:]
    private var resumes: [FileBrokerTestPoint: CheckedContinuation<Void, Never>] = [:]

    init(pausingAt points: Set<FileBrokerTestPoint>) {
        armed = Dictionary(uniqueKeysWithValues: points.map { ($0, 1) })
    }

    init(pausingAt point: FileBrokerTestPoint, occurrence: UInt64) {
        precondition(occurrence > 0)
        armed = [point: occurrence]
    }

    func waitUntilReached(_ point: FileBrokerTestPoint) async {
        guard !reached.contains(point) else { return }
        await withCheckedContinuation { continuation in
            waiters[point, default: []].append(continuation)
        }
    }

    func resume(_ point: FileBrokerTestPoint) {
        armed.removeValue(forKey: point)
        resumes.removeValue(forKey: point)?.resume()
    }

    fileprivate func pauseIfArmed(at point: FileBrokerTestPoint) async {
        let occurrence = occurrences[point, default: 0] + 1
        occurrences[point] = occurrence
        guard armed[point] == occurrence else { return }
        reached.insert(point)
        waiters.removeValue(forKey: point)?.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            resumes[point] = continuation
        }
    }
}

enum FileSystemNodeKind: Sendable, Equatable {
    case regular
    case directory
    case symbolicLink
    case unsupported
}

enum LinkProbeDecoding: Sendable, Equatable {
    case accepted(Data)
    case rejected(CoverageReasonCode)
}

enum FileBrokerPlatform {
    static func nestedLinkProofLogicalLocation(
        initiating location: VerifiedRelativePath
    ) -> VerifiedRelativePath {
        location
    }

    static func classify(mode: mode_t) -> FileSystemNodeKind {
        switch mode & S_IFMT {
        case S_IFREG: .regular
        case S_IFDIR: .directory
        case S_IFLNK: .symbolicLink
        default: .unsupported
        }
    }

    static func deviceBoundaryReason(
        rootDevice: UInt64,
        childDevice: UInt64
    ) -> CoverageReasonCode? {
        rootDevice == childDevice ? nil : .mountBoundary
    }

    static func linkTargetLengthRejection(byteCount: Int) -> CoverageReasonCode? {
        byteCount <= 4_096 ? nil : .pathTooLong
    }

    static func decodeLinkProbe(
        returnedCount: Int,
        buffer: [UInt8]
    ) -> LinkProbeDecoding {
        guard returnedCount >= 0, returnedCount <= 4_096, returnedCount <= buffer.count else {
            return .rejected(.pathTooLong)
        }
        return .accepted(Data(buffer.prefix(returnedCount)))
    }

    static func safeLocation(
        parent: VerifiedRelativePath?,
        rawLeaf: Data
    ) -> SkippedTraversalLocation {
        if let component = try? VerifiedPathComponent(bytes: rawLeaf),
           let path = try? VerifiedRelativePath(components: (parent?.components ?? []) + [component]) {
            return .verified(path)
        }
        return .unrepresentable(
            parent: parent,
            escapedLeaf: EscapedDisplayPath(text: escapedLeaf(Data(rawLeaf.prefix(255))))
        )
    }

    private static func escapedLeaf(_ bytes: Data) -> String {
        bytes.map { byte in
            switch byte {
            case 0: return "\\u{0}"
            case 0x20...0x7E: return String(UnicodeScalar(byte))
            default: return String(format: "\\x%02X", byte)
            }
        }.joined()
    }
}

fileprivate final class OpenedReadFile: @unchecked Sendable {
    private let descriptor: OwnedFileDescriptor

    init(descriptor: OwnedFileDescriptor) {
        self.descriptor = descriptor
    }

    func close() {
        descriptor.closeIfNeeded()
    }

    func withFileDescriptor<T>(_ body: (Int32) throws -> T) throws -> T {
        try descriptor.withFileDescriptor(body)
    }
}

enum ContentPurpose: Sendable, Equatable, Hashable {
    case secretInspection
    case nodeLockfileParsing
    case packageManifestParsing
}

enum ContentReadError: Error, Sendable, Equatable {
    case purposeTooLarge(CoverageReasonCode)
    case globalByteBudget
    case reservationClosed
    case unreadable
    case identityChanged
    case cancelled
}

final class InputBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let limits: ScanLimits
    private var admittedInputBytes: UInt64 = 0
    private var pendingInputBytes: UInt64 = 0
    private var retainedBytes: UInt64 = 0

    init(limits: ScanLimits) {
        self.limits = limits
    }

    func reserve(
        admittedFileBytes: UInt64,
        for purpose: ContentPurpose
    ) throws -> BudgetReservation {
        try lock.withLock {
            let (admittedAndPending, pendingOverflow) = admittedInputBytes
                .addingReportingOverflow(pendingInputBytes)
            let (nextInput, inputOverflow) = admittedAndPending
                .addingReportingOverflow(admittedFileBytes)
            let (nextRetained, retainedOverflow) = retainedBytes
                .addingReportingOverflow(admittedFileBytes)
            guard !pendingOverflow,
                  !inputOverflow,
                  nextInput <= limits.inputBytes,
                  !retainedOverflow,
                  nextRetained <= limits.retainedInputBytes else {
                throw ContentReadError.globalByteBudget
            }
            guard admittedFileBytes <= limit(for: purpose) else {
                throw ContentReadError.purposeTooLarge(purpose.oversizedReason)
            }
            pendingInputBytes += admittedFileBytes
            retainedBytes = nextRetained
            return BudgetReservation(budget: self, byteCount: admittedFileBytes)
        }
    }

    fileprivate func commit(byteCount: UInt64) -> RetainedBudgetLease {
        lock.withLock {
            precondition(pendingInputBytes >= byteCount)
            pendingInputBytes -= byteCount
            let (nextAdmitted, overflow) = admittedInputBytes.addingReportingOverflow(byteCount)
            precondition(!overflow && nextAdmitted <= limits.inputBytes)
            admittedInputBytes = nextAdmitted
        }
        return RetainedBudgetLease(budget: self, byteCount: byteCount)
    }

    fileprivate func cancel(byteCount: UInt64) {
        lock.withLock {
            precondition(pendingInputBytes >= byteCount)
            precondition(retainedBytes >= byteCount)
            pendingInputBytes -= byteCount
            retainedBytes -= byteCount
        }
    }

    fileprivate func releaseRetained(byteCount: UInt64) {
        lock.withLock {
            precondition(retainedBytes >= byteCount)
            retainedBytes -= byteCount
        }
    }

    fileprivate func authorizedPurposes(for byteCount: UInt64) -> Set<ContentPurpose> {
        Set(ContentPurpose.allCases.filter { byteCount <= limit(for: $0) })
    }

    private func limit(for purpose: ContentPurpose) -> UInt64 {
        switch purpose {
        case .secretInspection: limits.secretFileBytes
        case .nodeLockfileParsing: limits.lockfileBytes
        case .packageManifestParsing: limits.manifestBytes
        }
    }
}

final class BudgetReservation: @unchecked Sendable {
    private final class WeakRetainedLease {
        weak var value: RetainedBudgetLease?

        init(_ value: RetainedBudgetLease) {
            self.value = value
        }
    }

    private enum State {
        case pending
        case committed(WeakRetainedLease)
        case cancelled
    }

    private let lock = NSLock()
    private let budget: InputBudget
    private let byteCount: UInt64
    private var state = State.pending

    fileprivate init(budget: InputBudget, byteCount: UInt64) {
        self.budget = budget
        self.byteCount = byteCount
    }

    func commit() throws -> RetainedBudgetLease {
        try lock.withLock {
            switch state {
            case .pending:
                let lease = budget.commit(byteCount: byteCount)
                state = .committed(WeakRetainedLease(lease))
                return lease
            case let .committed(reference):
                guard let lease = reference.value else {
                    throw ContentReadError.reservationClosed
                }
                return lease
            case .cancelled:
                throw ContentReadError.reservationClosed
            }
        }
    }

    func cancel() {
        lock.withLock {
            guard case .pending = state else { return }
            budget.cancel(byteCount: byteCount)
            state = .cancelled
        }
    }

    deinit {
        cancel()
    }
}

final class RetainedBudgetLease: @unchecked Sendable {
    private let budget: InputBudget
    private let byteCount: UInt64

    fileprivate init(budget: InputBudget, byteCount: UInt64) {
        self.budget = budget
        self.byteCount = byteCount
    }

    deinit {
        budget.releaseRetained(byteCount: byteCount)
    }
}

final class ContentLease: @unchecked Sendable {
    private let bytes: Data
    private let retainedBudgetLease: RetainedBudgetLease
    private let authorizedPurposes: Set<ContentPurpose>

    var byteCount: UInt64 { UInt64(bytes.count) }

    fileprivate init(
        bytes: Data,
        retainedBudgetLease: RetainedBudgetLease,
        authorizedPurposes: Set<ContentPurpose>
    ) {
        self.bytes = bytes
        self.retainedBudgetLease = retainedBudgetLease
        self.authorizedPurposes = authorizedPurposes
    }

    func withBytes<T>(
        for purpose: ContentPurpose,
        _ body: (UnsafeRawBufferPointer) throws -> T
    ) throws -> T {
        _ = retainedBudgetLease
        guard authorizedPurposes.contains(purpose) else {
            throw ContentReadError.purposeTooLarge(purpose.oversizedReason)
        }
        return try bytes.withUnsafeBytes(body)
    }
}

enum ContentAdmission: Sendable {
    case admitted(ContentLease)
    case skipped(reason: CoverageReasonCode, bytes: UInt64)
}

enum ContentBrokerTestMode: Sendable, Equatable {
    case pauseAfterFirstChunk
    case failRead(chunk: UInt64)
}

actor ContentBrokerTestControl {
    private let mode: ContentBrokerTestMode
    private var firstChunkReached = false
    private var firstChunkWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstChunkResume: CheckedContinuation<Void, Never>?

    init(_ mode: ContentBrokerTestMode) {
        if case let .failRead(chunk) = mode {
            precondition(chunk > 0)
        }
        self.mode = mode
    }

    func waitUntilFirstChunkRead() async {
        guard !firstChunkReached else { return }
        await withCheckedContinuation { continuation in
            firstChunkWaiters.append(continuation)
        }
    }

    func resumeAfterFirstChunk() {
        firstChunkResume?.resume()
        firstChunkResume = nil
    }

    fileprivate func pauseAfterFirstChunkIfNeeded() async {
        guard mode == .pauseAfterFirstChunk else { return }
        firstChunkReached = true
        firstChunkWaiters.forEach { $0.resume() }
        firstChunkWaiters.removeAll(keepingCapacity: false)
        await withCheckedContinuation { continuation in
            firstChunkResume = continuation
        }
    }

    fileprivate func shouldFail(readChunk chunk: UInt64) -> Bool {
        mode == .failRead(chunk: chunk)
    }
}

actor ContentBroker {
    private let fileBroker: FileBroker
    private let budget: InputBudget
    private let testControl: ContentBrokerTestControl?

    fileprivate init(
        fileBroker: FileBroker,
        budget: InputBudget,
        testControl: ContentBrokerTestControl?
    ) {
        self.fileBroker = fileBroker
        self.budget = budget
        self.testControl = testControl
    }

    func read(
        _ candidate: FileCandidate,
        for purpose: ContentPurpose
    ) async -> ContentAdmission {
        let reservation: BudgetReservation
        do {
            reservation = try budget.reserve(
                admittedFileBytes: candidate.byteCount,
                for: purpose
            )
        } catch let error as ContentReadError {
            return .skipped(reason: error.coverageReason, bytes: candidate.byteCount)
        } catch {
            return .skipped(reason: .unreadable, bytes: candidate.byteCount)
        }

        var buffer = Data()
        do {
            try Task.checkCancellation()
            let opened = try await fileBroker.openForRead(candidate)
            defer { opened.close() }
            try Task.checkCancellation()
            guard let allocationSize = Int(exactly: candidate.byteCount) else {
                throw ContentReadError.unreadable
            }
            buffer = Data(count: allocationSize)
            var offset = 0
            var chunk: UInt64 = 0
            while offset < allocationSize {
                try Task.checkCancellation()
                chunk += 1
                if await testControl?.shouldFail(readChunk: chunk) == true {
                    throw ContentReadError.unreadable
                }
                let requested = min(64 * 1_024, allocationSize - offset)
                let readCount = try buffer.withUnsafeMutableBytes { bytes in
                    guard let baseAddress = bytes.baseAddress else { return 0 }
                    return try opened.withFileDescriptor { descriptor in
                        try readRetryingInterrupts(
                            descriptor,
                            into: baseAddress.advanced(by: offset),
                            byteCount: requested
                        )
                    }
                }
                guard readCount > 0 else {
                    throw ContentReadError.identityChanged
                }
                offset += readCount
                if chunk == 1, readCount == 64 * 1_024 {
                    await testControl?.pauseAfterFirstChunkIfNeeded()
                }
            }

            try Task.checkCancellation()
            var extraByte: UInt8 = 0
            let extraCount = try opened.withFileDescriptor { descriptor in
                try readRetryingInterrupts(descriptor, into: &extraByte, byteCount: 1)
            }
            guard extraCount == 0 else {
                throw ContentReadError.identityChanged
            }
            let finalIdentity = try opened.withFileDescriptor(status)
            guard finalIdentity == candidate.identity,
                  FileBrokerPlatform.classify(mode: mode_t(finalIdentity.mode)) == .regular else {
                throw ContentReadError.identityChanged
            }
            try Task.checkCancellation()
            let retainedLease = try reservation.commit()
            return .admitted(ContentLease(
                bytes: buffer,
                retainedBudgetLease: retainedLease,
                authorizedPurposes: budget.authorizedPurposes(for: candidate.byteCount)
            ))
        } catch let failure as FileAccessFailure {
            buffer.removeAll(keepingCapacity: false)
            reservation.cancel()
            return .skipped(reason: failure.reason, bytes: candidate.byteCount)
        } catch is CancellationError {
            buffer.removeAll(keepingCapacity: false)
            reservation.cancel()
            return .skipped(reason: .cancelled, bytes: candidate.byteCount)
        } catch let error as ContentReadError {
            buffer.removeAll(keepingCapacity: false)
            reservation.cancel()
            return .skipped(reason: error.coverageReason, bytes: candidate.byteCount)
        } catch {
            buffer.removeAll(keepingCapacity: false)
            reservation.cancel()
            return .skipped(reason: .unreadable, bytes: candidate.byteCount)
        }
    }
}

private extension ContentPurpose {
    var oversizedReason: CoverageReasonCode {
        switch self {
        case .secretInspection: .ordinaryFileTooLarge
        case .nodeLockfileParsing: .lockfileTooLarge
        case .packageManifestParsing: .manifestTooLarge
        }
    }

    static let allCases: [ContentPurpose] = [
        .secretInspection,
        .nodeLockfileParsing,
        .packageManifestParsing,
    ]
}

private extension ContentReadError {
    var coverageReason: CoverageReasonCode {
        switch self {
        case let .purposeTooLarge(reason): reason
        case .globalByteBudget: .globalByteBudget
        case .reservationClosed: .unreadable
        case .unreadable: .unreadable
        case .identityChanged: .identityChanged
        case .cancelled: .cancelled
        }
    }
}

actor FileBroker {
    private let rootDescriptor: OwnedFileDescriptor
    private let descriptorLifetime: (any DescriptorLifetime)?
    nonisolated let rootIdentity: FileIdentity
    nonisolated let limits: ScanLimits
    nonisolated private let inputBudget: InputBudget
    private let nonce = UUID()
    private let testControl: FileBrokerTestControl?
    private let descriptorAccounting = DescriptorAccounting()
    private var traversalIssued = false

    fileprivate init(
        rootDescriptor: OwnedFileDescriptor,
        rootIdentity: FileIdentity,
        limits: ScanLimits,
        testControl: FileBrokerTestControl?,
        descriptorLifetime: (any DescriptorLifetime)?
    ) {
        self.rootDescriptor = rootDescriptor
        self.descriptorLifetime = descriptorLifetime
        self.rootIdentity = rootIdentity
        self.limits = limits
        inputBudget = InputBudget(limits: limits)
        self.testControl = testControl
    }

    nonisolated func makeContentBroker() -> ContentBroker {
        ContentBroker(fileBroker: self, budget: inputBudget, testControl: nil)
    }

    nonisolated func makeContentBroker(
        testControl: ContentBrokerTestControl
    ) -> ContentBroker {
        ContentBroker(fileBroker: self, budget: inputBudget, testControl: testControl)
    }

    func makeTraversal() throws -> FileTraversal {
        guard !traversalIssued else { throw FileBrokerError.traversalAlreadyIssued }
        traversalIssued = true
        return try FileTraversal(
            rootDescriptor: rootDescriptor.duplicate(accounting: descriptorAccounting),
            rootIdentity: rootIdentity,
            limits: limits,
            brokerNonce: nonce,
            testControl: testControl,
            descriptorAccounting: descriptorAccounting,
            descriptorLifetime: descriptorLifetime
        )
    }

    func openTraversalDirectoryDescriptorCount() -> UInt64 {
        descriptorAccounting.snapshot()
    }

    func revalidate(_ candidate: FileCandidate) async -> CandidateRevalidation {
        do {
            let opened = try await openForRead(candidate)
            opened.close()
            return .valid
        } catch let failure as FileAccessFailure {
            return .rejected(failure.reason)
        } catch {
            return .rejected(.unreadable)
        }
    }

    fileprivate func makeGitPreflightSession() throws -> GitPreflightSession {
        GitPreflightSession(
            rootDescriptor: try rootDescriptor.duplicate(accounting: descriptorAccounting),
            rootIdentity: rootIdentity,
            limits: limits
        )
    }

    func gitPreflight() async -> GitPreflightOutcome {
        do {
            let session = try makeGitPreflightSession()
            defer { session.close() }
            return try session.run()
        } catch let failure as GitPreflightFailure {
            return .rejected(failure.reason)
        } catch {
            return .rejected(.unreadable)
        }
    }

    func openGitMetadataTransfers(
        for descriptors: [GitMetadataDescriptor]
    ) throws -> [GitMetadataOpenedTransfer] {
        let access = try makeGitMetadataAccess()
        return try access.openTransfers(for: descriptors)
    }

    func revalidateGitMetadataManifest(_ manifest: GitMetadataDescriptorManifest) -> Bool {
        do {
            let access = try makeGitMetadataAccess()
            defer { access.close() }
            return access.revalidate(manifest)
        } catch {
            return false
        }
    }

    func readBoundedGitMetadataFile(
        at path: VerifiedRelativePath,
        maxBytes: UInt64
    ) throws -> Data {
        let access = try makeGitMetadataAccess()
        defer { access.close() }
        return try access.readFile(at: path, maxBytes: maxBytes)
    }

    fileprivate func makeGitMetadataAccess() throws -> GitMetadataAccess {
        let duplicate = try rootDescriptor.duplicate(accounting: descriptorAccounting)
        let descriptor = try duplicate.take()
        return GitMetadataAccess(
            rootDescriptor: descriptor,
            rootIdentity: rootIdentity,
            limits: limits
        )
    }

    fileprivate func openForRead(_ candidate: FileCandidate) async throws -> OpenedReadFile {
        guard candidate.accessToken.brokerNonce == nonce else {
            throw FileAccessFailure(reason: .identityChanged)
        }
        for proof in candidate.accessToken.linkProof {
            try replay(proof)
        }
        await testControl?.pauseIfArmed(at: .afterProofReplay)
        if Task.isCancelled {
            throw FileAccessFailure(reason: .cancelled)
        }
        let descriptor = try openRegularFile(
            physicalComponents: candidate.accessToken.physicalComponents,
            expectedIdentity: candidate.accessToken.expectedIdentity
        )
        for proof in candidate.accessToken.linkProof {
            try replay(proof)
        }
        if Task.isCancelled {
            throw FileAccessFailure(reason: .cancelled)
        }
        return OpenedReadFile(descriptor: descriptor)
    }

    private func replay(_ proof: LinkProof) throws {
        guard let leaf = proof.physicalComponents.last else {
            throw FileAccessFailure(reason: .identityChanged)
        }
        let parent = try openDirectory(
            physicalComponents: Array(proof.physicalComponents.dropLast())
        )
        let inspected = try parent.withFileDescriptor { descriptor in
            try inspect(leaf, relativeTo: descriptor)
        }
        guard inspected == proof.inspectedIdentity,
              FileBrokerPlatform.classify(mode: mode_t(inspected.mode)) == .symbolicLink else {
            throw FileAccessFailure(reason: .identityChanged)
        }
        let target = try parent.withFileDescriptor { descriptor in
            try readLink(leaf, relativeTo: descriptor)
        }
        let reinspected = try parent.withFileDescriptor { descriptor in
            try inspect(leaf, relativeTo: descriptor)
        }
        let reread = try parent.withFileDescriptor { descriptor in
            try readLink(leaf, relativeTo: descriptor)
        }
        guard target == proof.targetBytes,
              reinspected == proof.inspectedIdentity,
              reread == proof.targetBytes else {
            throw FileAccessFailure(reason: .identityChanged)
        }
    }

    private func openDirectory(physicalComponents: [Data]) throws -> OwnedFileDescriptor {
        var current = try rootDescriptor.duplicate(accounting: descriptorAccounting)
        for component in physicalComponents {
            let inspected = try current.withFileDescriptor { descriptor in
                try inspect(component, relativeTo: descriptor)
            }
            let opened = try current.withFileDescriptor { descriptor in
                try openOwned(
                    component,
                    relativeTo: descriptor,
                    flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
                    accounting: descriptorAccounting,
                    descriptorLifetime: descriptorLifetime
                )
            }
            let identity = try opened.withFileDescriptor(status)
            guard sameObjectAndType(inspected, identity),
                  FileBrokerPlatform.classify(mode: mode_t(identity.mode)) == .directory else {
                throw FileAccessFailure(reason: .identityChanged)
            }
            guard identity.device == rootIdentity.device else {
                throw FileAccessFailure(reason: .mountBoundary)
            }
            current = opened
        }
        return current
    }

    private func openRegularFile(
        physicalComponents: [Data],
        expectedIdentity: FileIdentity
    ) throws -> OwnedFileDescriptor {
        guard let leaf = physicalComponents.last else {
            throw FileAccessFailure(reason: .identityChanged)
        }
        let parent = try openDirectory(
            physicalComponents: Array(physicalComponents.dropLast())
        )
        let opened = try parent.withFileDescriptor { descriptor in
            try openOwned(
                leaf,
                relativeTo: descriptor,
                flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
                accounting: descriptorAccounting,
                descriptorLifetime: descriptorLifetime
            )
        }
        let identity = try opened.withFileDescriptor(status)
        guard identity == expectedIdentity,
              FileBrokerPlatform.classify(mode: mode_t(identity.mode)) == .regular else {
            throw FileAccessFailure(reason: .identityChanged)
        }
        guard identity.device == rootIdentity.device else {
            throw FileAccessFailure(reason: .mountBoundary)
        }
        return opened
    }
}

actor FileTraversal {
    private var stack: [DirectoryFrame]
    private let descriptorLifetime: (any DescriptorLifetime)?
    private let rootIdentity: FileIdentity
    private let limits: ScanLimits
    private let brokerNonce: UUID
    private let testControl: FileBrokerTestControl?
    private let descriptorAccounting: DescriptorAccounting
    private var entriesVisited: UInt64 = 0
    private var directoriesOpened: UInt64 = 1
    private var candidatesProduced: UInt64 = 0
    private var skipsProduced: UInt64 = 0
    private var isCancelled = false
    private var isFinished = false

    fileprivate init(
        rootDescriptor: OwnedFileDescriptor,
        rootIdentity: FileIdentity,
        limits: ScanLimits,
        brokerNonce: UUID,
        testControl: FileBrokerTestControl?,
        descriptorAccounting: DescriptorAccounting,
        descriptorLifetime: (any DescriptorLifetime)?
    ) throws {
        self.descriptorLifetime = descriptorLifetime
        self.rootIdentity = rootIdentity
        self.limits = limits
        self.brokerNonce = brokerNonce
        self.testControl = testControl
        self.descriptorAccounting = descriptorAccounting
        stack = [try DirectoryFrame(
            descriptor: rootDescriptor,
            logicalComponents: [],
            physicalComponents: [],
            ancestry: [DirectoryIdentity(rootIdentity)],
            linkProof: [],
            linkHops: 0,
            descriptorAccounting: descriptorAccounting,
            descriptorLifetime: descriptorLifetime
        )]
    }

    func next() async throws -> TraversalEvent? {
        guard !isCancelled, !isFinished else { return nil }
        if Task.isCancelled {
            cancel()
            return nil
        }

        while let frame = stack.last {
            let rawName: Data
            do {
                guard let entry = try frame.nextEntry() else {
                    stack.removeLast().close()
                    continue
                }
                rawName = entry
            } catch {
                let location = verifiedPath(frame.logicalComponents)
                    .map(SkippedTraversalLocation.verified)
                    ?? .unrepresentable(parent: nil, escapedLeaf: nil)
                return stop(with: location, reason: .unreadable)
            }

            let parentPath = verifiedPath(frame.logicalComponents)
            let safeLocation = FileBrokerPlatform.safeLocation(parent: parentPath, rawLeaf: rawName)
            let (nextCount, overflow) = entriesVisited.addingReportingOverflow(1)
            guard !overflow, nextCount <= limits.directoryEntries else {
                return stop(with: safeLocation, reason: .entryBudget)
            }
            entriesVisited = nextCount

            await testControl?.pauseIfArmed(at: .afterDirectoryEntryRead)
            if isCancelled || Task.isCancelled {
                cancel()
                return nil
            }

            guard let component = try? VerifiedPathComponent(bytes: rawName) else {
                return emitSkip(safeLocation, reason: rawName.count > 255 ? .pathTooLong : .unreadable)
            }
            let logicalComponents = frame.logicalComponents + [component]
            guard logicalComponents.count <= Int(limits.traversalDepth),
                  let logicalPath = try? VerifiedRelativePath(components: logicalComponents),
                  logicalPath.rawByteCount <= limits.relativePathBytes else {
                return emitSkip(safeLocation, reason: .pathTooLong)
            }

            let inspected: FileIdentity
            do {
                inspected = try frame.withFileDescriptor { descriptor in
                    try inspect(rawName, relativeTo: descriptor)
                }
            } catch let failure as FileAccessFailure {
                return emitSkip(.verified(logicalPath), reason: failure.reason)
            } catch {
                return emitSkip(.verified(logicalPath), reason: .unreadable)
            }

            if let reason = FileBrokerPlatform.deviceBoundaryReason(
                rootDevice: rootIdentity.device,
                childDevice: inspected.device
            ) {
                return emitSkip(.verified(logicalPath), reason: reason)
            }

            switch FileBrokerPlatform.classify(mode: mode_t(inspected.mode)) {
            case .regular:
                await testControl?.pauseIfArmed(at: .afterEntryInspection)
                if stopForCancellationIfNeeded() { return nil }
                return await admitRegular(
                    name: rawName,
                    logicalPath: logicalPath,
                    inspected: inspected,
                    frame: frame
                )
            case .directory:
                await testControl?.pauseIfArmed(at: .afterEntryInspection)
                if stopForCancellationIfNeeded() { return nil }
                if let event = await pushDirectory(
                    name: rawName,
                    logicalComponents: logicalComponents,
                    logicalPath: logicalPath,
                    inspected: inspected,
                    frame: frame
                ) {
                    return event
                }
            case .symbolicLink:
                await testControl?.pauseIfArmed(at: .afterSymlinkInspection)
                if stopForCancellationIfNeeded() { return nil }
                if let event = await resolveLink(
                    name: rawName,
                    logicalComponents: logicalComponents,
                    logicalPath: logicalPath,
                    inspected: inspected,
                    frame: frame
                ) {
                    return event
                }
            case .unsupported:
                return emitSkip(.verified(logicalPath), reason: .specialFile)
            }
        }

        isFinished = true
        return nil
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        closeStack()
    }

    func summary() -> TraversalSummary {
        TraversalSummary(
            entriesVisited: entriesVisited,
            directoriesOpened: directoriesOpened,
            candidatesProduced: candidatesProduced,
            skipsProduced: skipsProduced,
            openDirectoryDescriptorCount: UInt64(stack.count),
            cancelled: isCancelled,
            finished: isFinished
        )
    }

    private func admitRegular(
        name: Data,
        logicalPath: VerifiedRelativePath,
        inspected: FileIdentity,
        frame: DirectoryFrame
    ) async -> TraversalEvent {
        do {
            let opened = try frame.withFileDescriptor { descriptor in
                try openOwned(
                    name,
                    relativeTo: descriptor,
                    flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
                    accounting: descriptorAccounting,
                    descriptorLifetime: descriptorLifetime
                )
            }
            let identity = try opened.withFileDescriptor(status)
            guard sameObjectAndType(inspected, identity),
                  FileBrokerPlatform.classify(mode: mode_t(identity.mode)) == .regular else {
                return emitSkip(.verified(logicalPath), reason: .identityChanged)
            }
            guard identity.device == rootIdentity.device else {
                return emitSkip(.verified(logicalPath), reason: .mountBoundary)
            }
            candidatesProduced += 1
            return .candidate(FileCandidate(
                logicalPath: logicalPath,
                identity: identity,
                byteCount: identity.size,
                accessToken: FileAccessToken(
                    brokerNonce: brokerNonce,
                    physicalComponents: frame.physicalComponents + [name],
                    expectedIdentity: identity,
                    linkProof: frame.linkProof
                )
            ))
        } catch let failure as FileAccessFailure {
            let current = try? frame.withFileDescriptor { descriptor in
                try inspect(name, relativeTo: descriptor)
            }
            let reason = current.map { sameObjectAndType(inspected, $0) } == true
                ? failure.reason
                : .identityChanged
            return emitSkip(.verified(logicalPath), reason: reason)
        } catch {
            return emitSkip(.verified(logicalPath), reason: .unreadable)
        }
    }

    private func pushDirectory(
        name: Data,
        logicalComponents: [VerifiedPathComponent],
        logicalPath: VerifiedRelativePath,
        inspected: FileIdentity,
        frame: DirectoryFrame
    ) async -> TraversalEvent? {
        guard directoriesOpened < limits.directories else {
            return stop(with: .verified(logicalPath), reason: .directoryBudget)
        }
        do {
            let opened = try frame.withFileDescriptor { descriptor in
                try openOwned(
                    name,
                    relativeTo: descriptor,
                    flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
                    accounting: descriptorAccounting,
                    descriptorLifetime: descriptorLifetime
                )
            }
            let identity = try opened.withFileDescriptor(status)
            guard sameObjectAndType(inspected, identity),
                  FileBrokerPlatform.classify(mode: mode_t(identity.mode)) == .directory else {
                return emitSkip(.verified(logicalPath), reason: .identityChanged)
            }
            guard identity.device == rootIdentity.device else {
                return emitSkip(.verified(logicalPath), reason: .mountBoundary)
            }
            stack.append(try DirectoryFrame(
                descriptor: opened,
                logicalComponents: logicalComponents,
                physicalComponents: frame.physicalComponents + [name],
                ancestry: frame.ancestry + [DirectoryIdentity(identity)],
                linkProof: frame.linkProof,
                linkHops: frame.linkHops,
                descriptorAccounting: descriptorAccounting,
                descriptorLifetime: descriptorLifetime
            ))
            directoriesOpened += 1
            return nil
        } catch let failure as FileAccessFailure {
            return emitSkip(.verified(logicalPath), reason: failure.reason)
        } catch {
            return emitSkip(.verified(logicalPath), reason: .unreadable)
        }
    }

    private func resolveLink(
        name: Data,
        logicalComponents: [VerifiedPathComponent],
        logicalPath: VerifiedRelativePath,
        inspected: FileIdentity,
        frame: DirectoryFrame
    ) async -> TraversalEvent? {
        let target: Data
        do {
            target = try frame.withFileDescriptor { descriptor in
                try readLink(name, relativeTo: descriptor)
            }
        } catch let failure as FileAccessFailure {
            return emitSkip(.verified(logicalPath), reason: failure.reason)
        } catch {
            return emitSkip(.verified(logicalPath), reason: .unreadable)
        }
        guard FileBrokerPlatform.linkTargetLengthRejection(byteCount: target.count) == nil else {
            return emitSkip(.verified(logicalPath), reason: .pathTooLong)
        }
        guard target.first != UInt8(ascii: "/") else {
            return emitSkip(.verified(logicalPath), reason: .externalBoundary)
        }

        let nextHops = frame.linkHops + 1
        guard nextHops <= limits.maximumLinkHops else {
            return emitSkip(.verified(logicalPath), reason: .linkHopLimit)
        }
        let proof = LinkProof(
            logicalLocation: logicalPath,
            physicalComponents: frame.physicalComponents + [name],
            inspectedIdentity: inspected,
            targetBytes: target
        )
        let result = await resolveTarget(
            target,
            from: frame,
            initiatingLogicalLocation: logicalPath,
            proofs: frame.linkProof + [proof],
            linkHops: nextHops
        )
        if stopForCancellationIfNeeded() { return nil }

        do {
            for proof in result.proofs {
                try replay(proof)
            }
        } catch let failure as FileAccessFailure {
            return emitSkip(.verified(logicalPath), reason: failure.reason)
        } catch {
            return emitSkip(.verified(logicalPath), reason: .identityChanged)
        }

        do {
            let currentIdentity = try frame.withFileDescriptor { descriptor in
                try inspect(name, relativeTo: descriptor)
            }
            let currentTarget = try frame.withFileDescriptor { descriptor in
                try readLink(name, relativeTo: descriptor)
            }
            guard currentIdentity == inspected, currentTarget == target else {
                return emitSkip(.verified(logicalPath), reason: .identityChanged)
            }
        } catch {
            return emitSkip(.verified(logicalPath), reason: .identityChanged)
        }

        switch result {
        case let .regular(identity, physicalComponents, proofs):
            candidatesProduced += 1
            return .candidate(FileCandidate(
                logicalPath: logicalPath,
                identity: identity,
                byteCount: identity.size,
                accessToken: FileAccessToken(
                    brokerNonce: brokerNonce,
                    physicalComponents: physicalComponents,
                    expectedIdentity: identity,
                    linkProof: proofs
                )
            ))
        case let .directory(descriptor, identity, physicalComponents, ancestry, proofs, hops):
            guard !frame.ancestry.contains(DirectoryIdentity(identity)) else {
                return emitSkip(.verified(logicalPath), reason: .symlinkCycle)
            }
            guard directoriesOpened < limits.directories else {
                return stop(with: .verified(logicalPath), reason: .directoryBudget)
            }
            do {
                stack.append(try DirectoryFrame(
                    descriptor: descriptor,
                    logicalComponents: logicalComponents,
                    physicalComponents: physicalComponents,
                    ancestry: ancestry,
                    linkProof: proofs,
                    linkHops: hops,
                    descriptorAccounting: descriptorAccounting,
                    descriptorLifetime: descriptorLifetime
                ))
                directoriesOpened += 1
                return nil
            } catch {
                return emitSkip(.verified(logicalPath), reason: .unreadable)
            }
        case let .skipped(reason):
            return emitSkip(.verified(logicalPath), reason: reason)
        }
    }

    private func resolveTarget(
        _ target: Data,
        from frame: DirectoryFrame,
        initiatingLogicalLocation: VerifiedRelativePath,
        proofs initialProofs: [LinkProof],
        linkHops initialHops: UInt32
    ) async -> ResolvedTarget {
        var pending = splitLinkTarget(target)
        var current: OwnedFileDescriptor
        do {
            current = try frame.duplicateOwnedDescriptor(accounting: descriptorAccounting)
        } catch {
            return .skipped(.unreadable)
        }
        var physicalComponents = frame.physicalComponents
        var ancestry = frame.ancestry
        var proofs = initialProofs
        var hops = initialHops

        while !pending.isEmpty {
            if stopForCancellationIfNeeded() { return .skipped(.cancelled) }
            let component = pending.removeFirst()
            if component.isEmpty || component == Data(".".utf8) { continue }
            if component == Data("..".utf8) {
                guard !physicalComponents.isEmpty, ancestry.count > 1 else {
                    return .skipped(.externalBoundary)
                }
                do {
                    let parent = try current.withFileDescriptor { descriptor in
                        try openOwned(
                            Data("..".utf8),
                            relativeTo: descriptor,
                            flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
                            accounting: descriptorAccounting,
                            descriptorLifetime: descriptorLifetime
                        )
                    }
                    let identity = try parent.withFileDescriptor(status)
                    guard DirectoryIdentity(identity) == ancestry[ancestry.count - 2] else {
                        return .skipped(.identityChanged)
                    }
                    current = parent
                    physicalComponents.removeLast()
                    ancestry.removeLast()
                    continue
                } catch {
                    return .skipped(.identityChanged)
                }
            }
            guard (try? VerifiedPathComponent(bytes: component)) != nil else {
                return .skipped(.pathTooLong)
            }
            guard physicalComponents.count < Int(limits.traversalDepth),
                  physicalPathByteCount(physicalComponents + [component]) <= limits.relativePathBytes else {
                return .skipped(.pathTooLong)
            }

            let inspected: FileIdentity
            do {
                inspected = try current.withFileDescriptor { descriptor in
                    try inspect(component, relativeTo: descriptor)
                }
            } catch let failure as FileAccessFailure {
                return .skipped(failure.reason)
            } catch {
                return .skipped(.unreadable)
            }
            guard inspected.device == rootIdentity.device else {
                return .skipped(.mountBoundary)
            }

            if proofs.count == initialProofs.count {
                await testControl?.pauseIfArmed(at: .afterSymlinkTargetRead)
                if stopForCancellationIfNeeded() { return .skipped(.cancelled) }
            }

            switch FileBrokerPlatform.classify(mode: mode_t(inspected.mode)) {
            case .symbolicLink:
                hops += 1
                guard hops <= limits.maximumLinkHops else {
                    return .skipped(.linkHopLimit)
                }
                let nestedTarget: Data
                do {
                    nestedTarget = try current.withFileDescriptor { descriptor in
                        try readLink(component, relativeTo: descriptor)
                    }
                    let reinspected = try current.withFileDescriptor { descriptor in
                        try inspect(component, relativeTo: descriptor)
                    }
                    let reread = try current.withFileDescriptor { descriptor in
                        try readLink(component, relativeTo: descriptor)
                    }
                    guard reinspected == inspected, reread == nestedTarget else {
                        return .skipped(.identityChanged)
                    }
                } catch let failure as FileAccessFailure {
                    return .skipped(failure.reason)
                } catch {
                    return .skipped(.unreadable)
                }
                guard nestedTarget.first != UInt8(ascii: "/") else {
                    return .skipped(.externalBoundary)
                }
                let linkComponents = physicalComponents + [component]
                proofs.append(LinkProof(
                    logicalLocation: FileBrokerPlatform.nestedLinkProofLogicalLocation(
                        initiating: initiatingLogicalLocation
                    ),
                    physicalComponents: linkComponents,
                    inspectedIdentity: inspected,
                    targetBytes: nestedTarget
                ))
                await testControl?.pauseIfArmed(at: .afterSymlinkTargetRead)
                if stopForCancellationIfNeeded() { return .skipped(.cancelled) }
                do {
                    let afterPauseIdentity = try current.withFileDescriptor { descriptor in
                        try inspect(component, relativeTo: descriptor)
                    }
                    let afterPauseTarget = try current.withFileDescriptor { descriptor in
                        try readLink(component, relativeTo: descriptor)
                    }
                    guard afterPauseIdentity == inspected,
                          afterPauseTarget == nestedTarget else {
                        return .skipped(.identityChanged)
                    }
                } catch let failure as FileAccessFailure {
                    return .skipped(failure.reason)
                } catch {
                    return .skipped(.identityChanged)
                }
                pending = splitLinkTarget(nestedTarget) + pending
            case .directory:
                do {
                    let opened = try current.withFileDescriptor { descriptor in
                        try openOwned(
                            component,
                            relativeTo: descriptor,
                            flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
                            accounting: descriptorAccounting,
                            descriptorLifetime: descriptorLifetime
                        )
                    }
                    let identity = try opened.withFileDescriptor(status)
                    guard sameObjectAndType(inspected, identity) else {
                        return .skipped(.identityChanged)
                    }
                    current = opened
                    physicalComponents.append(component)
                    ancestry.append(DirectoryIdentity(identity))
                    if pending.isEmpty {
                        return .directory(
                            current,
                            identity,
                            physicalComponents,
                            ancestry,
                            proofs,
                            hops
                        )
                    }
                } catch let failure as FileAccessFailure {
                    return .skipped(failure.reason)
                } catch {
                    return .skipped(.unreadable)
                }
            case .regular:
                guard pending.isEmpty else { return .skipped(.externalBoundary) }
                do {
                    let opened = try current.withFileDescriptor { descriptor in
                        try openOwned(
                            component,
                            relativeTo: descriptor,
                            flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
                            accounting: descriptorAccounting,
                            descriptorLifetime: descriptorLifetime
                        )
                    }
                    let identity = try opened.withFileDescriptor(status)
                    guard sameObjectAndType(inspected, identity),
                          FileBrokerPlatform.classify(mode: mode_t(identity.mode)) == .regular else {
                        return .skipped(.identityChanged)
                    }
                    return .regular(identity, physicalComponents + [component], proofs)
                } catch let failure as FileAccessFailure {
                    return .skipped(failure.reason)
                } catch {
                    return .skipped(.unreadable)
                }
            case .unsupported:
                return .skipped(.specialFile)
            }
        }
        do {
            let identity = try current.withFileDescriptor(status)
            guard FileBrokerPlatform.classify(mode: mode_t(identity.mode)) == .directory,
                  identity.device == rootIdentity.device else {
                return .skipped(.identityChanged)
            }
            return .directory(
                current,
                identity,
                physicalComponents,
                ancestry,
                proofs,
                hops
            )
        } catch let failure as FileAccessFailure {
            return .skipped(failure.reason)
        } catch {
            return .skipped(.unreadable)
        }
    }

    private func emitSkip(
        _ location: SkippedTraversalLocation,
        reason: CoverageReasonCode
    ) -> TraversalEvent {
        skipsProduced += 1
        return .skipped(location: location, reason: reason)
    }

    private func stop(
        with location: SkippedTraversalLocation,
        reason: CoverageReasonCode
    ) -> TraversalEvent {
        isFinished = true
        closeStack()
        return emitSkip(location, reason: reason)
    }

    private func closeStack() {
        let frames = stack
        stack.removeAll(keepingCapacity: false)
        frames.forEach { $0.close() }
    }

    private func stopForCancellationIfNeeded() -> Bool {
        guard isCancelled || Task.isCancelled else { return false }
        cancel()
        return true
    }

    private func replay(_ proof: LinkProof) throws {
        guard let leaf = proof.physicalComponents.last else {
            throw FileAccessFailure(reason: .identityChanged)
        }
        guard let rootFrame = stack.first else {
            throw FileAccessFailure(reason: .unreadable)
        }
        var current = try rootFrame.duplicateOwnedDescriptor(accounting: descriptorAccounting)
        for component in proof.physicalComponents.dropLast() {
            let inspected = try current.withFileDescriptor { descriptor in
                try inspect(component, relativeTo: descriptor)
            }
            let opened = try current.withFileDescriptor { descriptor in
                try openOwned(
                    component,
                    relativeTo: descriptor,
                    flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
                    accounting: descriptorAccounting,
                    descriptorLifetime: descriptorLifetime
                )
            }
            let identity = try opened.withFileDescriptor(status)
            guard sameObjectAndType(inspected, identity),
                  FileBrokerPlatform.classify(mode: mode_t(identity.mode)) == .directory else {
                throw FileAccessFailure(reason: .identityChanged)
            }
            current = opened
        }
        let inspected = try current.withFileDescriptor { descriptor in
            try inspect(leaf, relativeTo: descriptor)
        }
        let target = try current.withFileDescriptor { descriptor in
            try readLink(leaf, relativeTo: descriptor)
        }
        let reinspected = try current.withFileDescriptor { descriptor in
            try inspect(leaf, relativeTo: descriptor)
        }
        let reread = try current.withFileDescriptor { descriptor in
            try readLink(leaf, relativeTo: descriptor)
        }
        guard inspected == proof.inspectedIdentity,
              target == proof.targetBytes,
              reinspected == proof.inspectedIdentity,
              reread == proof.targetBytes else {
            throw FileAccessFailure(reason: .identityChanged)
        }
    }
}

fileprivate struct DirectoryIdentity: Sendable, Equatable, Hashable {
    let device: UInt64
    let inode: UInt64

    init(_ identity: FileIdentity) {
        device = identity.device
        inode = identity.inode
    }
}

fileprivate final class DirectoryFrame: @unchecked Sendable {
    let logicalComponents: [VerifiedPathComponent]
    let physicalComponents: [Data]
    let ancestry: [DirectoryIdentity]
    let linkProof: [LinkProof]
    let linkHops: UInt32
    private let descriptorAccounting: DescriptorAccounting
    private let lock = NSLock()
    private var cursor: UnsafeMutablePointer<DIR>?
    private var descriptorLifetime: (any DescriptorLifetime)?

    init(
        descriptor: OwnedFileDescriptor,
        logicalComponents: [VerifiedPathComponent],
        physicalComponents: [Data],
        ancestry: [DirectoryIdentity],
        linkProof: [LinkProof],
        linkHops: UInt32,
        descriptorAccounting: DescriptorAccounting,
        descriptorLifetime: (any DescriptorLifetime)?
    ) throws {
        let raw = try descriptor.take()
        guard let opened = fdopendir(raw) else {
            Darwin.close(raw)
            descriptorAccounting.release()
            throw FileAccessFailure(reason: .unreadable)
        }
        cursor = opened
        self.logicalComponents = logicalComponents
        self.physicalComponents = physicalComponents
        self.ancestry = ancestry
        self.linkProof = linkProof
        self.linkHops = linkHops
        self.descriptorAccounting = descriptorAccounting
        self.descriptorLifetime = descriptorLifetime
    }

    deinit {
        close()
    }

    func nextEntry() throws -> Data? {
        try lock.withLock { () throws -> Data? in
            guard let cursor else { return nil }
            while true {
                errno = 0
                guard let entry = readdir(cursor) else {
                    guard errno == 0 else { throw FileAccessFailure(reason: .unreadable) }
                    return nil
                }
                var name = entry.pointee.d_name
                let bytes = withUnsafeBytes(of: &name) { raw -> Data in
                    let count = raw.firstIndex(of: 0) ?? raw.count
                    return Data(raw.prefix(count))
                }
                if bytes == Data(".".utf8) || bytes == Data("..".utf8) { continue }
                return bytes
            }
        }
    }

    func withFileDescriptor<T>(_ body: (Int32) throws -> T) throws -> T {
        try lock.withLock {
            guard let cursor else { throw FileAccessFailure(reason: .unreadable) }
            return try body(dirfd(cursor))
        }
    }

    func duplicateOwnedDescriptor(accounting: DescriptorAccounting) throws -> OwnedFileDescriptor {
        try withFileDescriptor { descriptor in
            let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
            guard duplicate >= 0 else { throw FileAccessFailure(reason: .unreadable) }
            return try OwnedFileDescriptor(
                taking: duplicate,
                accounting: accounting,
                descriptorLifetime: descriptorLifetime
            )
        }
    }

    func close() {
        let releasedLifetime = lock.withLock { () -> (any DescriptorLifetime)? in
            guard let cursor else { return nil }
            closedir(cursor)
            self.cursor = nil
            descriptorAccounting.release()
            defer { descriptorLifetime = nil }
            return descriptorLifetime
        }
        withExtendedLifetime(releasedLifetime) {}
    }
}

fileprivate enum ResolvedTarget {
    case regular(FileIdentity, [Data], [LinkProof])
    case directory(
        OwnedFileDescriptor,
        FileIdentity,
        [Data],
        [DirectoryIdentity],
        [LinkProof],
        UInt32
    )
    case skipped(CoverageReasonCode)

    var proofs: [LinkProof] {
        switch self {
        case let .regular(_, _, proofs): proofs
        case let .directory(_, _, _, _, proofs, _): proofs
        case .skipped: []
        }
    }
}

fileprivate struct FileAccessFailure: Error {
    let reason: CoverageReasonCode
}

fileprivate func verifiedPath(_ components: [VerifiedPathComponent]) -> VerifiedRelativePath? {
    guard !components.isEmpty else { return nil }
    return try? VerifiedRelativePath(components: components)
}

fileprivate func sameObjectAndType(_ first: FileIdentity, _ second: FileIdentity) -> Bool {
    first.device == second.device
        && first.inode == second.inode
        && (mode_t(first.mode) & S_IFMT) == (mode_t(second.mode) & S_IFMT)
}

fileprivate func status(_ descriptor: Int32) throws -> FileIdentity {
    var value = stat()
    guard fstat(descriptor, &value) == 0 else {
        throw FileAccessFailure(reason: .unreadable)
    }
    do {
        return try FileIdentity(value)
    } catch {
        throw FileAccessFailure(reason: .identityChanged)
    }
}

fileprivate func inspect(_ name: Data, relativeTo descriptor: Int32) throws -> FileIdentity {
    try name.withNullTerminatedBytes { pointer in
        var value = stat()
        guard fstatat(descriptor, pointer, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
            let reason: CoverageReasonCode = (errno == ENOENT || errno == ENOTDIR)
                ? .identityChanged
                : .unreadable
            throw FileAccessFailure(reason: reason)
        }
        do {
            return try FileIdentity(value)
        } catch {
            throw FileAccessFailure(reason: .identityChanged)
        }
    }
}

fileprivate func openOwned(
    _ name: Data,
    relativeTo descriptor: Int32,
    flags: Int32,
    accounting: DescriptorAccounting? = nil,
    descriptorLifetime: (any DescriptorLifetime)? = nil
) throws -> OwnedFileDescriptor {
    try name.withNullTerminatedBytes { pointer in
        let opened = openat(descriptor, pointer, flags)
        guard opened >= 0 else {
            let reason: CoverageReasonCode
            switch errno {
            case ENOENT, ENOTDIR, ELOOP, ENXIO, ENODEV:
                reason = .identityChanged
            default:
                reason = .unreadable
            }
            throw FileAccessFailure(reason: reason)
        }
        return try OwnedFileDescriptor(
            taking: opened,
            accounting: accounting,
            descriptorLifetime: descriptorLifetime
        )
    }
}

fileprivate func readLink(_ name: Data, relativeTo descriptor: Int32) throws -> Data {
    try name.withNullTerminatedBytes { pointer in
        var buffer = [UInt8](repeating: 0, count: 4_097)
        let count = readlinkat(descriptor, pointer, &buffer, buffer.count)
        guard count >= 0 else {
            let reason: CoverageReasonCode = errno == ENOENT ? .identityChanged : .unreadable
            throw FileAccessFailure(reason: reason)
        }
        switch FileBrokerPlatform.decodeLinkProbe(returnedCount: count, buffer: buffer) {
        case let .accepted(target):
            return target
        case let .rejected(reason):
            throw FileAccessFailure(reason: reason)
        }
    }
}

fileprivate func readRetryingInterrupts(
    _ descriptor: Int32,
    into buffer: UnsafeMutableRawPointer,
    byteCount: Int
) throws -> Int {
    while true {
        let count = Darwin.read(descriptor, buffer, byteCount)
        if count >= 0 {
            return count
        }
        if errno == EINTR {
            continue
        }
        throw ContentReadError.unreadable
    }
}

fileprivate func splitLinkTarget(_ target: Data) -> [Data] {
    let components: [ArraySlice<UInt8>] = target.split(
        separator: UInt8(ascii: "/"),
        omittingEmptySubsequences: false
    )
    return components.map { Data(bytes: $0) }
}

fileprivate func physicalPathByteCount(_ components: [Data]) -> UInt64 {
    guard !components.isEmpty else { return 0 }
    let bytes = components.reduce(UInt64(components.count - 1)) { partial, component in
        partial + UInt64(component.count)
    }
    return bytes
}

fileprivate extension Data {
    func withNullTerminatedBytes<T>(_ body: (UnsafePointer<CChar>) throws -> T) throws -> T {
        guard !isEmpty, !contains(0) else { throw FileAccessFailure(reason: .unreadable) }
        var terminated = map(CChar.init(bitPattern:))
        terminated.append(0)
        return try terminated.withUnsafeBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }
}


fileprivate func gitPreflightInspect(_ name: Data, relativeTo descriptor: Int32) throws -> FileIdentity {
    do {
        return try inspect(name, relativeTo: descriptor)
    } catch {
        throw GitPreflightFailure(.unreadable)
    }
}

fileprivate final class GitPreflightSession: @unchecked Sendable {
    private let rootDescriptor: OwnedFileDescriptor
    private let rootIdentity: FileIdentity
    private let limits: ScanLimits

    init(rootDescriptor: OwnedFileDescriptor, rootIdentity: FileIdentity, limits: ScanLimits) {
        self.rootDescriptor = rootDescriptor
        self.rootIdentity = rootIdentity
        self.limits = limits
    }

    deinit {
        close()
    }

    func close() {
        rootDescriptor.closeIfNeeded()
    }

    private func withRootDescriptor<T>(_ body: (Int32) throws -> T) throws -> T {
        try rootDescriptor.withFileDescriptor(body)
    }

    func run() throws -> GitPreflightOutcome {
        let gitPointer = try resolveGitPreflightPointer()
        let layout = try resolveLayout(pointer: gitPointer)
        let config = try readAndValidateConfiguration(
            gitDirComponents: layout.gitDirComponents,
            commonDirComponents: layout.commonDirComponents
        )
        let headObjectID = try resolveHead(
            gitDirComponents: layout.gitDirComponents,
            commonDirComponents: layout.commonDirComponents,
            algorithm: config.objectHashAlgorithm
        )
        let manifest = try buildManifest(
            layout: layout,
            algorithm: config.objectHashAlgorithm
        )
        guard let gitDir = try verifiedPath(from: layout.gitDirComponents),
              let commonDir = try verifiedPath(from: layout.commonDirComponents) else {
            return .rejected(.unreadable)
        }
        let worktreeRoot = try verifiedPath(from: layout.worktreeRootComponents)
        return .accepted(GitRepositoryContext(
            worktreeRoot: worktreeRoot,
            gitDir: gitDir,
            commonDir: commonDir,
            headObjectID: headObjectID,
            repositoryFormatVersion: config.repositoryFormatVersion,
            objectHashAlgorithm: config.objectHashAlgorithm,
            manifest: manifest
        ))
    }

    private func resolveGitPreflightPointer() throws -> GitPreflightPointer {
        let dotGit = Data(".git".utf8)
        return try withRootDescriptor { rootFD in
            guard entryExists(named: dotGit, relativeTo: rootFD) else {
                throw GitPreflightFailure(.noRepository)
            }
            let inspected = try inspect(dotGit, relativeTo: rootFD)
            switch FileBrokerPlatform.classify(mode: mode_t(inspected.mode)) {
            case .directory:
                return GitPreflightPointer(
                    worktreeRootComponents: [],
                    gitDirComponents: [dotGit]
                )
            case .regular:
                let contents = try readRegularFile(
                    named: dotGit,
                    relativeTo: rootFD,
                    maxBytes: GitPreflightLimits.maxPointerFileBytes
                )
                guard let gitDirComponents = try parseGitDirPointer(contents, anchor: []) else {
                    throw GitPreflightFailure(.externalGitDir)
                }
                return GitPreflightPointer(
                    worktreeRootComponents: [],
                    gitDirComponents: gitDirComponents
                )
            default:
                throw GitPreflightFailure(.noRepository)
            }
        }
    }

    private func resolveLayout(pointer: GitPreflightPointer) throws -> GitPreflightLayout {
        let gitDirComponents = pointer.gitDirComponents
        var commonDirComponents = pointer.gitDirComponents

        if entryExists(at: gitDirComponents + [Data("commondir".utf8)]) {
            guard let commondirRelative = try readOptionalPointerFile(
                name: Data("commondir".utf8),
                parentComponents: gitDirComponents
            ) else {
                throw GitPreflightFailure(.externalCommonDir)
            }
            guard let resolved = try resolveInRootRelativePath(
                commondirRelative,
                anchor: gitDirComponents
            ) else {
                throw GitPreflightFailure(.externalCommonDir)
            }
            commonDirComponents = resolved
        }

        try rejectIfPresent(
            name: Data("alternates".utf8),
            parentComponents: commonDirComponents + [Data("objects".utf8), Data("info".utf8)],
            reason: .objectAlternates
        )
        try rejectIfPresent(
            name: Data("replace".utf8),
            parentComponents: commonDirComponents + [Data("refs".utf8)],
            reason: .replacementReferences
        )

        return GitPreflightLayout(
            worktreeRootComponents: pointer.worktreeRootComponents,
            gitDirComponents: gitDirComponents,
            commonDirComponents: commonDirComponents
        )
    }

    private func readAndValidateConfiguration(
        gitDirComponents: [Data],
        commonDirComponents: [Data]
    ) throws -> ParsedGitConfiguration {
        var combined = ParsedGitConfiguration.empty
        if gitDirComponents != commonDirComponents {
            let commonConfig = try readConfiguration(at: commonDirComponents + [Data("config".utf8)])
            try combined.merge(commonConfig)
        }
        let gitConfig = try readConfiguration(at: gitDirComponents + [Data("config".utf8)])
        try combined.merge(gitConfig)
        try combined.validateForPreflight()
        return combined
    }

    private func readConfiguration(at components: [Data]) throws -> ParsedGitConfiguration {
        guard !components.isEmpty else {
            throw GitPreflightFailure(.malformedConfiguration)
        }
        let parent = Array(components.dropLast())
        let leaf = components.last!
        let parentDescriptor = try openDirectory(components: parent)
        defer { Darwin.close(parentDescriptor) }
        guard entryExists(named: leaf, relativeTo: parentDescriptor) else {
            return .empty
        }
        let bytes = try readRegularFile(
            named: leaf,
            relativeTo: parentDescriptor,
            maxBytes: GitPreflightLimits.maxConfigBytes
        )
        guard bytes.count <= Int(GitPreflightLimits.maxConfigBytes) else {
            throw GitPreflightFailure(.oversizeConfiguration)
        }
        return try ParsedGitConfiguration.parse(bytes)
    }

    private func resolveHead(
        gitDirComponents: [Data],
        commonDirComponents: [Data],
        algorithm: GitObjectHashAlgorithm
    ) throws -> GitObjectID {
        let headComponents = gitDirComponents + [Data("HEAD".utf8)]
        let headBytes = try readFile(at: headComponents, maxBytes: GitPreflightLimits.maxHeadBytes)
        guard let text = decodeGitText(headBytes)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw GitPreflightFailure(.malformedHead)
        }
        if text.hasPrefix("ref: ") {
            let refPath = String(text.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !refPath.isEmpty, !refPath.contains("\\") else {
                throw GitPreflightFailure(.malformedHead)
            }
            let refComponents = refPath.split(separator: "/").map {
                Data($0.utf8)
            }
            guard !refComponents.isEmpty else {
                throw GitPreflightFailure(.malformedHead)
            }
            return try resolveRefChain(
                refComponents: commonDirComponents + refComponents,
                algorithm: algorithm,
                depth: 0
            )
        }
        guard let objectID = GitObjectID(algorithm: algorithm, hex: text.lowercased()) else {
            throw GitPreflightFailure(.malformedHead)
        }
        return objectID
    }

    private func resolveRefChain(
        refComponents: [Data],
        algorithm: GitObjectHashAlgorithm,
        depth: UInt32
    ) throws -> GitObjectID {
        guard depth < GitPreflightLimits.maxRefChainDepth else {
            throw GitPreflightFailure(.refChainLimit)
        }
        let bytes = try readFile(at: refComponents, maxBytes: GitPreflightLimits.maxRefFileBytes)
        guard let text = decodeGitText(bytes)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw GitPreflightFailure(.malformedHead)
        }
        if text.hasPrefix("ref: ") {
            let refPath = String(text.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            let nextComponents = refPath.split(separator: "/").map { Data($0.utf8) }
            guard !nextComponents.isEmpty else {
                throw GitPreflightFailure(.malformedHead)
            }
            let gitDirPrefix: [Data]
            if let refsIndex = refComponents.firstIndex(of: Data("refs".utf8)) {
                gitDirPrefix = Array(refComponents.prefix(refsIndex))
            } else {
                gitDirPrefix = []
            }
            return try resolveRefChain(
                refComponents: gitDirPrefix + nextComponents,
                algorithm: algorithm,
                depth: depth + 1
            )
        }
        guard let objectID = GitObjectID(algorithm: algorithm, hex: text.lowercased()) else {
            throw GitPreflightFailure(.malformedHead)
        }
        return objectID
    }

    private func buildManifest(
        layout: GitPreflightLayout,
        algorithm: GitObjectHashAlgorithm
    ) throws -> GitMetadataDescriptorManifest {
        var collected: [GitMetadataDescriptor] = []

        func append(_ descriptor: GitMetadataDescriptor) throws {
            guard collected.count < Int(limits.gitMetadataDescriptors) else {
                throw GitPreflightFailure(.descriptorBudgetExceeded)
            }
            collected.append(descriptor)
        }

        let indexComponents = layout.gitDirComponents + [Data("index".utf8)]
        if (try? inspectIdentity(at: indexComponents)) != nil {
            try append(try openMetadataDescriptor(
                components: indexComponents,
                role: .index
            ))
        }

        let objectsRoot = layout.commonDirComponents + [Data("objects".utf8)]
        try collectLooseObjects(
            under: objectsRoot,
            algorithm: algorithm,
            append: { try append($0) }
        )
        try collectPackFiles(
            under: objectsRoot + [Data("pack".utf8)],
            algorithm: algorithm,
            append: { try append($0) }
        )

        return try GitMetadataDescriptorManifest(
            descriptors: collected,
            descriptorLimit: limits.gitMetadataDescriptors
        )
    }

    private func collectLooseObjects(
        under components: [Data],
        algorithm: GitObjectHashAlgorithm,
        append: (GitMetadataDescriptor) throws -> Void
    ) throws {
        guard entryExists(at: components) else { return }
        let directoryDescriptor = try openDirectory(components: components)
        guard let cursor = fdopendir(directoryDescriptor) else {
            throw GitPreflightFailure(.unreadable)
        }

        while let entry = readdir(cursor) {
            var name = entry.pointee.d_name
            let prefixBytes = withUnsafeBytes(of: &name) { raw -> Data in
                let count = raw.firstIndex(of: 0) ?? raw.count
                return Data(raw.prefix(count))
            }
            guard prefixBytes != Data(".".utf8), prefixBytes != Data("..".utf8) else { continue }
            guard GitObjectNaming.isLooseObjectPrefix(prefixBytes, algorithm: algorithm) else {
                continue
            }
            let prefixDescriptor = try openDirectory(
                components: components + [prefixBytes]
            )
            guard let objectCursor = fdopendir(prefixDescriptor) else {
                throw GitPreflightFailure(.unreadable)
            }
            while let objectEntry = readdir(objectCursor) {
                var objectName = objectEntry.pointee.d_name
                let suffixBytes = withUnsafeBytes(of: &objectName) { raw -> Data in
                    let count = raw.firstIndex(of: 0) ?? raw.count
                    return Data(raw.prefix(count))
                }
                guard suffixBytes != Data(".".utf8), suffixBytes != Data("..".utf8) else { continue }
                guard let objectID = GitObjectNaming.looseObjectID(
                    prefix: prefixBytes,
                    suffix: suffixBytes,
                    algorithm: algorithm
                ) else {
                    continue
                }
                let objectComponents = components + [prefixBytes, suffixBytes]
                let descriptor = try openMetadataDescriptor(
                    components: objectComponents,
                    role: .looseObject,
                    objectID: objectID
                )
                try append(descriptor)
            }
            closedir(objectCursor)
        }
        closedir(cursor)
    }

    private func collectPackFiles(
        under components: [Data],
        algorithm: GitObjectHashAlgorithm,
        append: (GitMetadataDescriptor) throws -> Void
    ) throws {
        guard entryExists(at: components) else { return }
        let directoryDescriptor = try openDirectory(components: components)
        guard let cursor = fdopendir(directoryDescriptor) else {
            throw GitPreflightFailure(.unreadable)
        }

        while let entry = readdir(cursor) {
            var name = entry.pointee.d_name
            let nameBytes = withUnsafeBytes(of: &name) { raw -> Data in
                let count = raw.firstIndex(of: 0) ?? raw.count
                return Data(raw.prefix(count))
            }
            guard nameBytes != Data(".".utf8), nameBytes != Data("..".utf8) else { continue }
            guard let role = GitObjectNaming.packFileRole(nameBytes, algorithm: algorithm) else {
                continue
            }
            let descriptor = try openMetadataDescriptor(
                components: components + [nameBytes],
                role: role
            )
            try append(descriptor)
        }
        closedir(cursor)
    }

    private func openMetadataDescriptor(
        components: [Data],
        role: GitMetadataDescriptorRole,
        objectID: GitObjectID? = nil
    ) throws -> GitMetadataDescriptor {
        let before = try inspectIdentity(at: components)
        let parent = Array(components.dropLast())
        let leaf = components.last!
        let parentDescriptor = try openDirectory(components: parent)
        defer { Darwin.close(parentDescriptor) }
        let opened = try openRegularFile(named: leaf, relativeTo: parentDescriptor)
        defer { Darwin.close(opened) }
        let after = try fstatIdentity(opened)
        guard before == after,
              FileBrokerPlatform.classify(mode: mode_t(after.mode)) == .regular,
              after.device == rootIdentity.device else {
            throw GitPreflightFailure(.identityChangedDuringPreflight)
        }
        guard let relativePath = try verifiedPath(from: components) else {
            throw GitPreflightFailure(.unreadable)
        }
        return GitMetadataDescriptor(
            role: role,
            relativePath: relativePath,
            identity: after,
            objectID: objectID
        )
    }

    private func parseGitDirPointer(_ contents: Data, anchor: [Data]) throws -> [Data]? {
        guard let text = decodeGitText(contents) else { return nil }
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("gitdir:") else { continue }
            let value = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return nil }
            if value.hasPrefix("/") {
                return nil
            }
            return try resolveInRootRelativePath(Data(value.utf8), anchor: anchor)
        }
        return nil
    }

    private func readOptionalPointerFile(name: Data, parentComponents: [Data]) throws -> Data? {
        let components = parentComponents + [name]
        guard entryExists(at: components) else { return nil }
        let bytes = try readFile(at: components, maxBytes: GitPreflightLimits.maxPointerFileBytes)
        guard let text = decodeGitText(bytes)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw GitPreflightFailure(.malformedConfiguration)
        }
        if text.hasPrefix("/") {
            return nil
        }
        return Data(text.utf8)
    }

    private func resolveInRootRelativePath(_ target: Data, anchor: [Data]) throws -> [Data]? {
        var components = anchor
        for piece in splitRelativePath(target) {
            if piece == Data(".".utf8) { continue }
            if piece == Data("..".utf8) {
                guard !components.isEmpty else { return nil }
                components.removeLast()
                continue
            }
            guard (try? VerifiedPathComponent(bytes: piece)) != nil else { return nil }
            components.append(piece)
            guard components.count <= Int(limits.traversalDepth) else { return nil }
        }
        return components
    }

    private func rejectIfPresent(
        name: Data,
        parentComponents: [Data],
        reason: GitPreflightRejectionReason
    ) throws {
        if entryExists(at: parentComponents + [name]) {
            throw GitPreflightFailure(reason)
        }
    }

    private func readFile(at components: [Data], maxBytes: UInt64) throws -> Data {
        guard !components.isEmpty else {
            throw GitPreflightFailure(.unreadable)
        }
        let parent = Array(components.dropLast())
        let leaf = components.last!
        let parentDescriptor = try openDirectory(components: parent)
        defer { Darwin.close(parentDescriptor) }
        return try readRegularFile(
            named: leaf,
            relativeTo: parentDescriptor,
            maxBytes: maxBytes
        )
    }

    private func entryExists(at components: [Data]) -> Bool {
        guard !components.isEmpty else {
            return false
        }
        let parent = Array(components.dropLast())
        let leaf = components.last!
        guard let parentDescriptor = try? openDirectory(components: parent) else {
            return false
        }
        defer { Darwin.close(parentDescriptor) }
        return entryExists(named: leaf, relativeTo: parentDescriptor)
    }

    private func inspectIdentity(at components: [Data]) throws -> FileIdentity {
        guard !components.isEmpty else {
            throw GitPreflightFailure(.unreadable)
        }
        let parent = Array(components.dropLast())
        let leaf = components.last!
        let parentDescriptor = try openDirectory(components: parent)
        defer { Darwin.close(parentDescriptor) }
        return try inspect(leaf, relativeTo: parentDescriptor)
    }

    private func openDirectory(components: [Data]) throws -> Int32 {
        try withRootDescriptor { rootFD in
            var current = rootFD
            var ownsCurrent = false
            defer {
                if ownsCurrent { Darwin.close(current) }
            }
            for component in components {
                let inspected = try inspect(component, relativeTo: current)
                guard FileBrokerPlatform.classify(mode: mode_t(inspected.mode)) == .directory else {
                    throw GitPreflightFailure(.identityChangedDuringPreflight)
                }
                guard inspected.device == rootIdentity.device else {
                    throw GitPreflightFailure(.mountBoundary)
                }
                let opened = try openDirectoryEntry(named: component, relativeTo: current)
                if ownsCurrent { Darwin.close(current) }
                current = opened
                ownsCurrent = true
                let openedIdentity = try fstatIdentity(opened)
                guard sameObjectAndType(inspected, openedIdentity),
                      openedIdentity.device == rootIdentity.device else {
                    throw GitPreflightFailure(.identityChangedDuringPreflight)
                }
            }
            let duplicate: Int32
            if ownsCurrent {
                duplicate = fcntl(current, F_DUPFD_CLOEXEC, 0)
                Darwin.close(current)
            } else {
                duplicate = fcntl(rootFD, F_DUPFD_CLOEXEC, 0)
            }
            guard duplicate >= 0 else { throw GitPreflightFailure(.unreadable) }
            return duplicate
        }
    }

    private func inspect(_ name: Data, relativeTo descriptor: Int32) throws -> FileIdentity {
        do {
            return try gitPreflightInspect(name, relativeTo: descriptor)
        } catch let failure as GitPreflightFailure {
            throw failure
        } catch {
            throw GitPreflightFailure(.unreadable)
        }
    }

    private func openDirectoryEntry(named name: Data, relativeTo descriptor: Int32) throws -> Int32 {
        try name.withNullTerminatedBytes { pointer in
            let opened = openat(descriptor, pointer, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard opened >= 0 else { throw GitPreflightFailure(.unreadable) }
            return opened
        }
    }

    private func openRegularFile(named name: Data, relativeTo descriptor: Int32) throws -> Int32 {
        try name.withNullTerminatedBytes { pointer in
            let opened = openat(
                descriptor,
                pointer,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
            guard opened >= 0 else { throw GitPreflightFailure(.unreadable) }
            var value = stat()
            guard fstat(opened, &value) == 0,
                  value.st_mode & S_IFMT == S_IFREG else {
                Darwin.close(opened)
                throw GitPreflightFailure(.identityChangedDuringPreflight)
            }
            return opened
        }
    }

    private func readRegularFile(
        named name: Data,
        relativeTo descriptor: Int32,
        maxBytes: UInt64
    ) throws -> Data {
        let opened = try openRegularFile(named: name, relativeTo: descriptor)
        defer { Darwin.close(opened) }
        let identity = try fstatIdentity(opened)
        guard identity.size <= maxBytes else {
            throw GitPreflightFailure(.oversizeConfiguration)
        }
        guard let allocationSize = Int(exactly: identity.size) else {
            throw GitPreflightFailure(.unreadable)
        }
        var buffer = Data(count: allocationSize)
        var offset = 0
        while offset < allocationSize {
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return Darwin.read(
                    opened,
                    baseAddress.advanced(by: offset),
                    allocationSize - offset
                )
            }
            guard count > 0 else { throw GitPreflightFailure(.unreadable) }
            offset += count
        }
        var extra: UInt8 = 0
        let extraCount = Darwin.read(opened, &extra, 1)
        guard extraCount == 0 else {
            throw GitPreflightFailure(.oversizeConfiguration)
        }
        return buffer
    }

    private func entryExists(named name: Data, relativeTo descriptor: Int32) -> Bool {
        (try? inspect(name, relativeTo: descriptor)) != nil
    }

    private func fstatIdentity(_ descriptor: Int32) throws -> FileIdentity {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else {
            throw GitPreflightFailure(.unreadable)
        }
        return try FileIdentity(value)
    }

    private func verifiedPath(from components: [Data]) throws -> VerifiedRelativePath? {
        let verified = try components.map { try VerifiedPathComponent(bytes: $0) }
        guard !verified.isEmpty else { return nil }
        return try VerifiedRelativePath(components: verified)
    }
}

fileprivate struct GitPreflightPointer {
    let worktreeRootComponents: [Data]
    let gitDirComponents: [Data]
}

fileprivate struct GitPreflightLayout {
    let worktreeRootComponents: [Data]
    let gitDirComponents: [Data]
    let commonDirComponents: [Data]
}

fileprivate struct ParsedGitConfiguration {
    var repositoryFormatVersion: Int
    var objectHashAlgorithm: GitObjectHashAlgorithm
    private var rejectedKeys: Set<String>
    private var extensions: Set<String>

    static let empty = ParsedGitConfiguration(
        repositoryFormatVersion: 0,
        objectHashAlgorithm: .sha1,
        rejectedKeys: [],
        extensions: []
    )

    mutating func merge(_ other: ParsedGitConfiguration) throws {
        if other.repositoryFormatVersion > repositoryFormatVersion {
            repositoryFormatVersion = other.repositoryFormatVersion
        }
        if other.objectHashAlgorithm == .sha256 {
            objectHashAlgorithm = .sha256
        }
        rejectedKeys.formUnion(other.rejectedKeys)
        extensions.formUnion(other.extensions)
    }

    func validateForPreflight() throws {
        if !rejectedKeys.isEmpty {
            if rejectedKeys.contains(where: { $0.hasPrefix("include") }) {
                throw GitPreflightFailure(.configurationInclude)
            }
            if rejectedKeys.contains(where: {
                $0.contains("alternate") || $0.contains("promisor") || $0.contains("partialclone")
            }) {
                throw GitPreflightFailure(.promisorConfiguration)
            }
            if rejectedKeys.contains(where: { $0.contains("replace") }) {
                throw GitPreflightFailure(.replacementReferences)
            }
            if rejectedKeys.contains(where: { $0.contains("safe.directory") }) {
                throw GitPreflightFailure(.unsafeOwnershipMarker)
            }
            throw GitPreflightFailure(.malformedConfiguration)
        }
        let unsupported = extensions.subtracting(["objectformat"])
        if !unsupported.isEmpty {
            throw GitPreflightFailure(.unsupportedExtension)
        }
        if repositoryFormatVersion > 1 {
            throw GitPreflightFailure(.unsupportedExtension)
        }
    }

    static func parse(_ bytes: Data) throws -> ParsedGitConfiguration {
        guard let text = decodeGitText(bytes) else {
            throw GitPreflightFailure(.malformedConfiguration)
        }
        var config = ParsedGitConfiguration.empty
        var section: String?
        var subsection: String?

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") {
                continue
            }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else {
                    throw GitPreflightFailure(.malformedConfiguration)
                }
                let body = String(line.dropFirst().dropLast())
                if body.lowercased().hasPrefix("include") {
                    config.rejectedKeys.insert(body.lowercased())
                    section = nil
                    subsection = nil
                    continue
                }
                if let quote = body.firstIndex(of: "\"") {
                    let sectionName = String(body[..<quote])
                    guard body.hasSuffix("\"") else {
                        throw GitPreflightFailure(.malformedConfiguration)
                    }
                    section = sectionName
                    subsection = String(body[body.index(after: quote)..<body.index(before: body.endIndex)])
                } else {
                    section = body
                    subsection = nil
                }
                continue
            }
            guard let equals = line.firstIndex(of: "=") else {
                throw GitPreflightFailure(.malformedConfiguration)
            }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else {
                throw GitPreflightFailure(.malformedConfiguration)
            }
            let qualified = [section, subsection, key]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: ".")
                .lowercased()

            if qualified.hasPrefix("include") || qualified.contains(".include") {
                config.rejectedKeys.insert(qualified)
            } else if qualified.contains("alternates") || qualified.contains("promisor")
                        || qualified.contains("partialclone") || qualified.contains("extensions.partialclone") {
                config.rejectedKeys.insert(qualified)
            } else if qualified.contains("replace") {
                config.rejectedKeys.insert(qualified)
            } else if qualified == "safe.directory" {
                config.rejectedKeys.insert(qualified)
            } else if qualified == "core.repositoryformatversion" {
                guard let version = Int(value) else {
                    throw GitPreflightFailure(.malformedConfiguration)
                }
                config.repositoryFormatVersion = max(config.repositoryFormatVersion, version)
            } else if qualified == "extensions.objectformat" {
                switch value.lowercased() {
                case "sha1":
                    config.objectHashAlgorithm = .sha1
                case "sha256":
                    config.objectHashAlgorithm = .sha256
                default:
                    throw GitPreflightFailure(.unsupportedExtension)
                }
                config.extensions.insert("objectformat")
            } else if qualified.hasPrefix("extensions.") {
                let name = String(qualified.dropFirst("extensions.".count))
                config.extensions.insert(name)
            }
        }
        return config
    }
}

fileprivate enum GitObjectNaming {
    static func isLooseObjectPrefix(_ bytes: Data, algorithm: GitObjectHashAlgorithm) -> Bool {
        guard bytes.count == 2, let text = String(data: bytes, encoding: .utf8) else { return false }
        return text.allSatisfy(isLowerHexDigit)
    }

    static func looseObjectID(
        prefix: Data,
        suffix: Data,
        algorithm: GitObjectHashAlgorithm
    ) -> GitObjectID? {
        guard let prefixText = String(data: prefix, encoding: .utf8),
              let suffixText = String(data: suffix, encoding: .utf8) else {
            return nil
        }
        return GitObjectID(algorithm: algorithm, hex: prefixText + suffixText)
    }

    static func packFileRole(
        _ nameBytes: Data,
        algorithm: GitObjectHashAlgorithm
    ) -> GitMetadataDescriptorRole? {
        guard let name = String(data: nameBytes, encoding: .utf8) else { return nil }
        let hashLength = algorithm == .sha1 ? 40 : 64
        let idxPrefix = "pack-"
        let idxSuffix = ".idx"
        let packSuffix = ".pack"
        let revSuffix = ".rev"
        if name.hasPrefix(idxPrefix), name.hasSuffix(idxSuffix) {
            let hash = String(name.dropFirst(idxPrefix.count).dropLast(idxSuffix.count))
            guard hash.count == hashLength, hash.allSatisfy(isLowerHexDigit) else { return nil }
            return .packIndex
        }
        if name.hasPrefix(idxPrefix), name.hasSuffix(packSuffix) {
            let hash = String(name.dropFirst(idxPrefix.count).dropLast(packSuffix.count))
            guard hash.count == hashLength, hash.allSatisfy(isLowerHexDigit) else { return nil }
            return .packData
        }
        if name.hasPrefix(idxPrefix), name.hasSuffix(revSuffix) {
            let hash = String(name.dropFirst(idxPrefix.count).dropLast(revSuffix.count))
            guard hash.count == hashLength, hash.allSatisfy(isLowerHexDigit) else { return nil }
            return .packReverseIndex
        }
        return nil
    }
}

fileprivate struct GitPreflightFailure: Error {
    let reason: GitPreflightRejectionReason

    init(_ reason: GitPreflightRejectionReason) {
        self.reason = reason
    }
}

private func decodeGitText(_ bytes: Data) -> String? {
    String(data: bytes, encoding: .utf8)?
        .replacingOccurrences(of: "\u{0}", with: "")
}

private func splitRelativePath(_ target: Data) -> [Data] {
    target.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
        .map { Data($0) }
}

private func isLowerHexDigit(_ character: Character) -> Bool {
    guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
        return false
    }
    switch scalar.value {
    case 48...57, 97...102: return true
    default: return false
    }
}

public final class RootCapability: @unchecked Sendable {
    private enum Disposition {
        case available
        case closed
        case brokerIssued
    }

    public let identity: FileIdentity
    private let lock = NSLock()
    private var descriptor: OwnedFileDescriptor?
    private var disposition = Disposition.available

    private init(descriptor: OwnedFileDescriptor, identity: FileIdentity) {
        self.descriptor = descriptor
        self.identity = identity
    }

    public static func open(selectedURL: URL) throws -> RootCapability {
        try selectedURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw ContainmentError.invalidSelection }

            var inspected = stat()
            guard lstat(path, &inspected) == 0 else { throw ContainmentError.openFailed }
            guard inspected.st_mode & S_IFMT != S_IFLNK else {
                throw ContainmentError.rootIsLink
            }
            guard inspected.st_mode & S_IFMT == S_IFDIR else {
                throw ContainmentError.notDirectory
            }

            let descriptorValue = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptorValue >= 0 else { throw ContainmentError.openFailed }
            let owned = try OwnedFileDescriptor(taking: descriptorValue)

            var opened = stat()
            guard fstat(descriptorValue, &opened) == 0 else {
                throw ContainmentError.openFailed
            }
            guard inspected.st_dev == opened.st_dev,
                  inspected.st_ino == opened.st_ino,
                  opened.st_mode & S_IFMT == S_IFDIR else {
                throw ContainmentError.identityChanged
            }

            return RootCapability(descriptor: owned, identity: try FileIdentity(opened))
        }
    }

    func makeFileBroker(limits: ScanLimits) throws -> FileBroker {
        try makeFileBroker(
            limits: limits,
            testControl: nil,
            descriptorLifetime: nil
        )
    }

    func makeFileBroker(
        limits: ScanLimits,
        testControl: FileBrokerTestControl?
    ) throws -> FileBroker {
        try makeFileBroker(
            limits: limits,
            testControl: testControl,
            descriptorLifetime: nil
        )
    }

    func makeFileBroker(
        limits: ScanLimits,
        descriptorLifetime: any DescriptorLifetime
    ) throws -> FileBroker {
        try makeFileBroker(
            limits: limits,
            testControl: nil,
            descriptorLifetime: descriptorLifetime
        )
    }

    private func makeFileBroker(
        limits: ScanLimits,
        testControl: FileBrokerTestControl?,
        descriptorLifetime: (any DescriptorLifetime)?
    ) throws -> FileBroker {
        let transferred = try lock.withLock { () throws -> OwnedFileDescriptor in
            switch disposition {
            case .available:
                guard let descriptor else { throw ContainmentError.closedCapability }
                self.descriptor = nil
                disposition = .brokerIssued
                return descriptor
            case .closed:
                throw ContainmentError.closedCapability
            case .brokerIssued:
                throw ContainmentError.brokerAlreadyIssued
            }
        }
        if let descriptorLifetime {
            transferred.bindDescriptorLifetime(descriptorLifetime)
        }
        return FileBroker(
            rootDescriptor: transferred,
            rootIdentity: identity,
            limits: limits,
            testControl: testControl,
            descriptorLifetime: descriptorLifetime
        )
    }

    public func close() {
        let removed = lock.withLock { () -> OwnedFileDescriptor? in
            guard disposition == .available else { return nil }
            disposition = .closed
            defer { descriptor = nil }
            return descriptor
        }
        removed?.closeIfNeeded()
    }

    deinit {
        close()
    }
}
