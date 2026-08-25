import Darwin
import Foundation

enum GitMetadataAccessError: Error, Sendable {
    case unreadable
    case identityChanged
    case mountBoundary
}

final class GitMetadataAccess: @unchecked Sendable {
    private let rootDescriptor: Int32
    private let rootIdentity: FileIdentity
    private let limits: ScanLimits
    private var closed = false

    init(rootDescriptor: Int32, rootIdentity: FileIdentity, limits: ScanLimits) {
        self.rootDescriptor = rootDescriptor
        self.rootIdentity = rootIdentity
        self.limits = limits
    }

    deinit {
        close()
    }

    func close() {
        guard !closed else { return }
        closed = true
        Darwin.close(rootDescriptor)
    }

    func openTransfers(for descriptors: [GitMetadataDescriptor]) throws -> [GitMetadataOpenedTransfer] {
        try descriptors.map { descriptor in
            let fileDescriptor = try openRegularFile(
                components: descriptor.relativePath.identityComponents,
                expectedIdentity: descriptor.identity
            )
            let transfer = GitMetadataDescriptorTransfer(
                descriptor: descriptor,
                fileDescriptor: fileDescriptor
            )
            return GitMetadataOpenedTransfer(transfer: transfer) {
                Darwin.close(fileDescriptor)
            }
        }
    }

    func revalidate(_ manifest: GitMetadataDescriptorManifest) -> Bool {
        manifest.descriptors.allSatisfy { descriptor in
            guard let current = try? inspectIdentity(
                components: descriptor.relativePath.identityComponents
            ) else {
                return false
            }
            return current == descriptor.identity
        }
    }

    func readFile(at path: VerifiedRelativePath, maxBytes: UInt64) throws -> Data {
        let identity = try inspectIdentity(components: path.identityComponents)
        let descriptor = try openRegularFile(
            components: path.identityComponents,
            expectedIdentity: identity
        )
        defer { Darwin.close(descriptor) }
        return try readAll(from: descriptor, maxBytes: maxBytes)
    }

    private func inspectIdentity(components: [Data]) throws -> FileIdentity {
        guard !components.isEmpty else { throw GitMetadataAccessError.unreadable }
        let parent = Array(components.dropLast())
        let leaf = components.last!
        let parentDescriptor = try openDirectory(components: parent)
        defer { Darwin.close(parentDescriptor) }
        return try inspect(leaf, relativeTo: parentDescriptor)
    }

    private func openRegularFile(
        components: [Data],
        expectedIdentity: FileIdentity
    ) throws -> Int32 {
        guard !components.isEmpty else { throw GitMetadataAccessError.unreadable }
        let parent = Array(components.dropLast())
        let leaf = components.last!
        let parentDescriptor = try openDirectory(components: parent)
        defer { Darwin.close(parentDescriptor) }
        let inspected = try inspect(leaf, relativeTo: parentDescriptor)
        let opened = try openOwned(
            leaf,
            relativeTo: parentDescriptor,
            flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        let identity = try fstatIdentity(opened)
        guard inspected == expectedIdentity,
              identity == expectedIdentity,
              FileBrokerPlatform.classify(mode: mode_t(identity.mode)) == .regular,
              identity.device == rootIdentity.device else {
            Darwin.close(opened)
            throw GitMetadataAccessError.identityChanged
        }
        return opened
    }

    private func openDirectory(components: [Data]) throws -> Int32 {
        var current = rootDescriptor
        var ownsCurrent = false
        defer {
            if ownsCurrent { Darwin.close(current) }
        }
        for component in components {
            let inspected = try inspect(component, relativeTo: current)
            guard FileBrokerPlatform.classify(mode: mode_t(inspected.mode)) == .directory,
                  inspected.device == rootIdentity.device else {
                throw GitMetadataAccessError.unreadable
            }
            let opened = try openDirectoryEntry(named: component, relativeTo: current)
            if ownsCurrent { Darwin.close(current) }
            current = opened
            ownsCurrent = true
            let openedIdentity = try fstatIdentity(opened)
            guard gitMetadataIdentityEqual(inspected, openedIdentity),
                  openedIdentity.device == rootIdentity.device else {
                throw GitMetadataAccessError.identityChanged
            }
        }
        let duplicate: Int32
        if ownsCurrent {
            duplicate = fcntl(current, F_DUPFD_CLOEXEC, 0)
            Darwin.close(current)
        } else {
            duplicate = fcntl(rootDescriptor, F_DUPFD_CLOEXEC, 0)
        }
        guard duplicate >= 0 else { throw GitMetadataAccessError.unreadable }
        return duplicate
    }

    private func inspect(_ name: Data, relativeTo descriptor: Int32) throws -> FileIdentity {
        var value = stat()
        let status: Int32 = try name.withNullTerminatedBytes { pathPointer in
            fstatat(descriptor, pathPointer, &value, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0 else {
            throw GitMetadataAccessError.unreadable
        }
        return try FileIdentity(value)
    }

    private func openDirectoryEntry(named name: Data, relativeTo descriptor: Int32) throws -> Int32 {
        try name.withNullTerminatedBytes { cName in
            let opened = openat(descriptor, cName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard opened >= 0 else { throw GitMetadataAccessError.unreadable }
            return opened
        }
    }

    private func openOwned(_ name: Data, relativeTo descriptor: Int32, flags: Int32) throws -> Int32 {
        try name.withNullTerminatedBytes { cName in
            let opened = openat(descriptor, cName, flags)
            guard opened >= 0 else { throw GitMetadataAccessError.unreadable }
            return opened
        }
    }

    private func fstatIdentity(_ descriptor: Int32) throws -> FileIdentity {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else {
            throw GitMetadataAccessError.unreadable
        }
        return try FileIdentity(value)
    }

    private func readAll(from descriptor: Int32, maxBytes: UInt64) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(descriptor, raw.baseAddress!, raw.count)
            }
            guard count > 0 else {
                if count == 0 { break }
                throw GitMetadataAccessError.unreadable
            }
            guard result.count + count <= Int(maxBytes) else {
                throw GitMetadataAccessError.unreadable
            }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
}

private func gitMetadataIdentityEqual(_ first: FileIdentity, _ second: FileIdentity) -> Bool {
    first.device == second.device
        && first.inode == second.inode
        && (mode_t(first.mode) & S_IFMT) == (mode_t(second.mode) & S_IFMT)
}

private extension Data {
    func withNullTerminatedBytes<T>(_ body: (UnsafePointer<CChar>) throws -> T) throws -> T {
        guard !isEmpty, !contains(0) else { throw GitMetadataAccessError.unreadable }
        var terminated = map(CChar.init(bitPattern:))
        terminated.append(0)
        return try terminated.withUnsafeBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }
}
