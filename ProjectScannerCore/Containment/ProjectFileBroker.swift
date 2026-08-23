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

    init(taking value: Int32) throws {
        guard value >= 0 else { throw ContainmentError.openFailed }
        self.value = value
    }

    deinit {
        closeIfNeeded()
    }

    func duplicate() throws -> OwnedFileDescriptor {
        try lock.withLock {
            guard value >= 0 else { throw ContainmentError.closedCapability }
            let duplicate = fcntl(value, F_DUPFD_CLOEXEC, 0)
            guard duplicate >= 0 else { throw ContainmentError.openFailed }
            return try OwnedFileDescriptor(taking: duplicate)
        }
    }

    func withFileDescriptor<T>(_ body: (Int32) throws -> T) throws -> T {
        try lock.withLock {
            guard value >= 0 else { throw ContainmentError.closedCapability }
            return try body(value)
        }
    }

    func closeIfNeeded() {
        lock.withLock {
            if value >= 0 {
                Darwin.close(value)
                value = -1
            }
        }
    }
}

final class FileBroker: @unchecked Sendable {
    private let rootDescriptor: OwnedFileDescriptor
    let rootIdentity: FileIdentity
    let limits: ScanLimits

    fileprivate init(
        rootDescriptor: OwnedFileDescriptor,
        rootIdentity: FileIdentity,
        limits: ScanLimits
    ) {
        self.rootDescriptor = rootDescriptor
        self.rootIdentity = rootIdentity
        self.limits = limits
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
            limits: limits
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
