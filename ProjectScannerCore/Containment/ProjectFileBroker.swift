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

fileprivate final class OwnedFileDescriptor: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32
    private let accounting: DescriptorAccounting?

    init(taking value: Int32, accounting: DescriptorAccounting? = nil) throws {
        guard value >= 0 else { throw ContainmentError.openFailed }
        self.value = value
        self.accounting = accounting
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
            return try OwnedFileDescriptor(taking: duplicate, accounting: accounting)
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
        lock.withLock {
            if value >= 0 {
                Darwin.close(value)
                value = -1
                accounting?.release()
            }
        }
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
}

actor FileBroker {
    private let rootDescriptor: OwnedFileDescriptor
    nonisolated let rootIdentity: FileIdentity
    nonisolated let limits: ScanLimits
    private let nonce = UUID()
    private let testControl: FileBrokerTestControl?
    private let descriptorAccounting = DescriptorAccounting()
    private var traversalIssued = false

    fileprivate init(
        rootDescriptor: OwnedFileDescriptor,
        rootIdentity: FileIdentity,
        limits: ScanLimits,
        testControl: FileBrokerTestControl?
    ) {
        self.rootDescriptor = rootDescriptor
        self.rootIdentity = rootIdentity
        self.limits = limits
        self.testControl = testControl
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
            descriptorAccounting: descriptorAccounting
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
                    accounting: descriptorAccounting
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
                accounting: descriptorAccounting
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
        descriptorAccounting: DescriptorAccounting
    ) throws {
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
            descriptorAccounting: descriptorAccounting
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
                    accounting: descriptorAccounting
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
                accounting: descriptorAccounting
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
                descriptorAccounting: descriptorAccounting
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
                    descriptorAccounting: descriptorAccounting
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
                            accounting: descriptorAccounting
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
                            accounting: descriptorAccounting
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
                            accounting: descriptorAccounting
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
                    accounting: descriptorAccounting
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

    init(
        descriptor: OwnedFileDescriptor,
        logicalComponents: [VerifiedPathComponent],
        physicalComponents: [Data],
        ancestry: [DirectoryIdentity],
        linkProof: [LinkProof],
        linkHops: UInt32,
        descriptorAccounting: DescriptorAccounting
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
            return try OwnedFileDescriptor(taking: duplicate, accounting: accounting)
        }
    }

    func close() {
        lock.withLock {
            guard let cursor else { return }
            closedir(cursor)
            self.cursor = nil
            descriptorAccounting.release()
        }
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
    accounting: DescriptorAccounting? = nil
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
        return try OwnedFileDescriptor(taking: opened, accounting: accounting)
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

fileprivate func splitLinkTarget(_ target: Data) -> [Data] {
    target.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false).map(Data.init)
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
        try makeFileBroker(limits: limits, testControl: nil)
    }

    func makeFileBroker(
        limits: ScanLimits,
        testControl: FileBrokerTestControl?
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
        return FileBroker(
            rootDescriptor: transferred,
            rootIdentity: identity,
            limits: limits,
            testControl: testControl
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
