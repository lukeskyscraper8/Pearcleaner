import Darwin
import CryptoKit
import Foundation
@testable import ProjectScannerCore

final class TemporaryProjectFixture {
    let url: URL
    let outsideCanaryURL: URL

    init() throws {
        let templateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).XXXXXX", isDirectory: true)
        var template = templateURL.path.utf8CString
        let createdPath = try template.withUnsafeMutableBufferPointer { buffer -> String in
            guard let created = mkdtemp(buffer.baseAddress) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return String(cString: created)
        }
        url = URL(fileURLWithPath: createdPath, isDirectory: true)
        outsideCanaryURL = url.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: false)
        guard FileManager.default.createFile(
            atPath: outsideCanaryURL.path,
            contents: Data("outside-canary".utf8)
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func directory(named name: String) throws -> URL {
        let directory = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    func regularFile(named name: String) throws -> URL {
        try regularFile(named: name, contents: Data())
    }

    @discardableResult
    func regularFile(named name: String, contents: Data) throws -> URL {
        let file = url.appendingPathComponent(name, isDirectory: false)
        guard FileManager.default.createFile(atPath: file.path, contents: contents) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return file
    }

    @discardableResult
    func rawRegularFile(
        parent: URL? = nil,
        nameBytes: Data,
        contents: Data = Data()
    ) throws -> FileIdentity {
        let parent = parent ?? url
        let parentDescriptor = try openDirectory(parent)
        defer { Darwin.close(parentDescriptor) }
        return try nameBytes.withNullTerminatedFileSystemBytes { name in
            let descriptor = openat(
                parentDescriptor,
                name,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
            guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
            defer { Darwin.close(descriptor) }
            if !contents.isEmpty {
                try contents.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(
                        descriptor,
                        buffer.baseAddress!.advanced(by: offset),
                        buffer.count - offset
                    )
                    guard count > 0 else { throw CocoaError(.fileWriteUnknown) }
                    offset += count
                }
            }
            }
            var value = stat()
            guard fstat(descriptor, &value) == 0 else { throw CocoaError(.fileReadUnknown) }
            return try FileIdentity(value)
        }
    }

    func symbolicLink(at link: URL, target: String) throws {
        guard symlink(target, link.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    func rawSymbolicLink(parent: URL? = nil, nameBytes: Data, targetBytes: Data) throws {
        let parentDescriptor = try openDirectory(parent ?? url)
        defer { Darwin.close(parentDescriptor) }
        try nameBytes.withNullTerminatedFileSystemBytes { name in
            try targetBytes.withNullTerminatedFileSystemBytes { target in
                guard symlinkat(target, parentDescriptor, name) == 0 else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
        }
    }

    func rawDirectoryChain(_ componentNames: [Data]) throws {
        var current = try openDirectory(url)
        defer { Darwin.close(current) }
        for component in componentNames {
            let child = try component.withNullTerminatedFileSystemBytes { name -> Int32 in
                guard mkdirat(current, name, S_IRUSR | S_IWUSR | S_IXUSR) == 0 else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let opened = openat(current, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard opened >= 0 else { throw CocoaError(.fileReadUnknown) }
                return opened
            }
            Darwin.close(current)
            current = child
        }
    }

    func hardLink(from source: URL, to destination: URL) throws {
        guard link(source.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    func fifo(at path: URL) throws {
        guard mkfifo(path.path, S_IRUSR | S_IWUSR) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    func unixSocket(at path: URL) throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.path.utf8CString)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= capacity else { throw CocoaError(.fileWriteFileExists) }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: pathBytes.map(UInt8.init(bitPattern:)))
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, length)
            }
        }
        guard result == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    func identity(of path: URL, followLinks: Bool = false) throws -> FileIdentity {
        var value = stat()
        let result = followLinks ? stat(path.path, &value) : lstat(path.path, &value)
        guard result == 0 else { throw CocoaError(.fileReadUnknown) }
        return try FileIdentity(value)
    }

    func snapshot() throws -> Set<ProjectTreeSnapshotEntry> {
        var result = Set<ProjectTreeSnapshotEntry>()
        let descriptor = try openDirectory(url)
        try snapshotDirectory(descriptor, relativeComponents: [], into: &result)
        return result
    }

    func remove() {
        if let descriptor = try? openDirectory(url) {
            removeContents(of: descriptor)
            Darwin.close(descriptor)
            _ = rmdir(url.path)
        }
        try? FileManager.default.removeItem(at: outsideCanaryURL)
    }

    private func snapshotDirectory(
        _ descriptor: Int32,
        relativeComponents: [Data],
        into result: inout Set<ProjectTreeSnapshotEntry>
    ) throws {
        guard let cursor = fdopendir(descriptor) else {
            Darwin.close(descriptor)
            throw CocoaError(.fileReadUnknown)
        }
        defer { closedir(cursor) }

        while let entry = readdir(cursor) {
            var name = entry.pointee.d_name
            let bytes = withUnsafeBytes(of: &name) { raw -> Data in
                let count = raw.firstIndex(of: 0) ?? raw.count
                return Data(raw.prefix(count))
            }
            guard bytes != Data(".".utf8), bytes != Data("..".utf8) else { continue }
            var value = stat()
            try bytes.withNullTerminatedFileSystemBytes { name in
                guard fstatat(dirfd(cursor), name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw CocoaError(.fileReadUnknown)
                }
            }
            let identity = try FileIdentity(value)
            let components = relativeComponents + [bytes]
            var contentHash: Data?
            if value.st_mode & S_IFMT == S_IFREG {
                let child = try bytes.withNullTerminatedFileSystemBytes { name -> Int32 in
                    let opened = openat(dirfd(cursor), name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                    guard opened >= 0 else { throw CocoaError(.fileReadUnknown) }
                    return opened
                }
                defer { Darwin.close(child) }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 8_192)
                while true {
                    let count = Darwin.read(child, &buffer, buffer.count)
                    guard count >= 0 else { throw CocoaError(.fileReadUnknown) }
                    guard count > 0 else { break }
                    data.append(buffer, count: count)
                }
                contentHash = Data(SHA256.hash(data: data))
            }
            result.insert(ProjectTreeSnapshotEntry(
                relativeComponents: components,
                identity: identity,
                contentHash: contentHash
            ))
            if value.st_mode & S_IFMT == S_IFDIR {
                let child = try bytes.withNullTerminatedFileSystemBytes { name -> Int32 in
                    let opened = openat(
                        dirfd(cursor),
                        name,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                    guard opened >= 0 else { throw CocoaError(.fileReadUnknown) }
                    return opened
                }
                try snapshotDirectory(child, relativeComponents: components, into: &result)
            }
        }
    }

    private func removeContents(of descriptor: Int32) {
        let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0, let cursor = fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            return
        }
        defer { closedir(cursor) }
        while let entry = readdir(cursor) {
            var name = entry.pointee.d_name
            let bytes = withUnsafeBytes(of: &name) { raw -> Data in
                let count = raw.firstIndex(of: 0) ?? raw.count
                return Data(raw.prefix(count))
            }
            guard bytes != Data(".".utf8), bytes != Data("..".utf8) else { continue }
            try? bytes.withNullTerminatedFileSystemBytes { name in
                var value = stat()
                guard fstatat(descriptor, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { return }
                if value.st_mode & S_IFMT == S_IFDIR {
                    let child = openat(
                        descriptor,
                        name,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                    if child >= 0 {
                        removeContents(of: child)
                        Darwin.close(child)
                    }
                    _ = unlinkat(descriptor, name, AT_REMOVEDIR)
                } else {
                    _ = unlinkat(descriptor, name, 0)
                }
            }
        }
    }

    private func openDirectory(_ directory: URL) throws -> Int32 {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        return descriptor
    }
}

struct ProjectTreeSnapshotEntry: Hashable {
    let relativeComponents: [Data]
    let identity: FileIdentity
    let contentHash: Data?
}

private extension Data {
    func withNullTerminatedFileSystemBytes<T>(
        _ body: (UnsafePointer<CChar>) throws -> T
    ) throws -> T {
        guard !contains(0) else { throw CocoaError(.fileWriteInvalidFileName) }
        var bytes = map(CChar.init(bitPattern:))
        bytes.append(0)
        return try bytes.withUnsafeBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }
}
