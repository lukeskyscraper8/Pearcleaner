import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import ProjectScannerCore

final class MountBoundaryIntegrationTests: XCTestCase {
    func testMountedDeviceIsSkippedWithoutReadingItsCanary() async throws {
        let environment = ProcessInfo.processInfo.environment
        let harnessKeys = MountHarnessConfiguration.environmentKeys
        let configuredValues = harnessKeys.compactMap { environment[$0] }
        guard !configuredValues.isEmpty else {
            throw XCTSkip("Real mount fixture is not configured")
        }
        guard configuredValues.count == harnessKeys.count else {
            throw MountHarnessError.invalidEnvironment
        }

        let configuration = try MountHarnessConfiguration(environment: environment)
        let before = try mountAwareSnapshot(at: configuration.root)

        let capability = try RootCapability.open(selectedURL: configuration.root)
        let broker = try capability.makeFileBroker(limits: .defaults)
        let traversal = try await broker.makeTraversal()
        let contentBroker = broker.makeContentBroker()
        var events: [TraversalEvent] = []
        var candidates: [FileCandidate] = []
        while let event = try await traversal.next() {
            events.append(event)
            if case let .candidate(candidate) = event {
                candidates.append(candidate)
            }
        }
        guard try await traversal.next() == nil else {
            return XCTFail("Traversal did not remain exhausted")
        }

        let mountBoundaryPaths = events.compactMap { event -> String? in
            guard case let .skipped(location, .mountBoundary) = event,
                  case let .verified(path) = location else {
                return nil
            }
            return path.escapedForDisplay().text
        }
        guard mountBoundaryPaths == [MountHarnessConfiguration.mountedDirectoryName] else {
            return XCTFail("Expected exactly one mount-boundary skip at the mounted directory")
        }

        let candidatePaths = candidates.map { $0.logicalPath.escapedForDisplay().text }.sorted()
        guard candidatePaths == [MountHarnessConfiguration.benignFileName] else {
            return XCTFail("Expected exactly the benign same-device file to be admitted")
        }

        var admittedBenignFile = false
        for candidate in candidates {
            let path = candidate.logicalPath.escapedForDisplay().text
            let admission = await contentBroker.read(candidate, for: .secretInspection)
            guard case let .admitted(lease) = admission else {
                return XCTFail("Expected content admission for same-device candidate")
            }
            let bytes = try lease.withBytes(for: .secretInspection) { Data($0) }
            guard bytes.range(of: configuration.canary) == nil else {
                return XCTFail("An admitted content lease contained the mounted canary")
            }
            if path == MountHarnessConfiguration.benignFileName {
                guard bytes == MountHarnessConfiguration.benignContents else {
                    return XCTFail("The benign admission did not contain the fixed local bytes")
                }
                admittedBenignFile = true
            }
        }
        guard admittedBenignFile else {
            return XCTFail("The benign same-device file was not admitted through ContentBroker")
        }

        let after = try mountAwareSnapshot(at: configuration.root)
        guard after == before else {
            return XCTFail("Traversal changed the same-device project tree")
        }

        try writeAndVerifyResultMarker(at: configuration.resultMarker)
    }
}

private struct MountHarnessConfiguration {
    static let harnessTokenKey = "PROJECT_SCANNER_MOUNT_HARNESS_TOKEN"
    static let fixtureRootKey = "PROJECT_SCANNER_MOUNT_FIXTURE_ROOT"
    static let canaryKey = "PROJECT_SCANNER_MOUNT_CANARY"
    static let resultMarkerKey = "PROJECT_SCANNER_MOUNT_RESULT_MARKER"
    static let environmentKeys = [harnessTokenKey, fixtureRootKey, canaryKey, resultMarkerKey]

    static let harnessToken = "PROJECT_SCANNER_MOUNT_HARNESS_V1_6D5A8C31"
    static let canaryText = "PROJECT_SCANNER_EXTERNAL_MOUNT_CANARY_7F6B9A2D"
    static let resultMarkerText = "PROJECT_SCANNER_MOUNT_BOUNDARY_OK_V1"
    static let fixtureRootName = "root"
    static let mountedDirectoryName = "mounted"
    static let benignFileName = "benign-local.txt"
    static let resultMarkerName = "mount-boundary.result"
    static let benignContents = Data("PROJECT_SCANNER_LOCAL_ADMISSION_CONTROL_V1".utf8)

    let root: URL
    let canary: Data
    let resultMarker: URL

    init(environment: [String: String]) throws {
        guard environment[Self.harnessTokenKey] == Self.harnessToken,
              environment[Self.canaryKey] == Self.canaryText,
              let rootPath = environment[Self.fixtureRootKey],
              let markerPath = environment[Self.resultMarkerKey],
              !rootPath.isEmpty,
              !markerPath.isEmpty else {
            throw MountHarnessError.invalidEnvironment
        }

        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        guard root.path == rootPath,
              root.lastPathComponent == Self.fixtureRootName,
              isValidatedMountWorkDirectory(root.deletingLastPathComponent().path) else {
            throw MountHarnessError.invalidFixture
        }
        let expectedMarker = root.deletingLastPathComponent()
            .appendingPathComponent(Self.resultMarkerName, isDirectory: false)
            .standardizedFileURL
        let resultMarker = URL(fileURLWithPath: markerPath, isDirectory: false).standardizedFileURL
        guard resultMarker.path == markerPath,
              resultMarker == expectedMarker,
              !resultMarker.path.hasPrefix(root.path + "/") else {
            throw MountHarnessError.invalidFixture
        }

        let rootStatus = try status(of: root)
        let mountedStatus = try status(
            of: root.appendingPathComponent(Self.mountedDirectoryName, isDirectory: true)
        )
        let benignStatus = try status(
            of: root.appendingPathComponent(Self.benignFileName, isDirectory: false)
        )
        guard rootStatus.st_mode & S_IFMT == S_IFDIR,
              mountedStatus.st_mode & S_IFMT == S_IFDIR,
              benignStatus.st_mode & S_IFMT == S_IFREG,
              rootStatus.st_uid == geteuid(),
              benignStatus.st_uid == geteuid(),
              mountedStatus.st_dev != rootStatus.st_dev,
              benignStatus.st_dev == rootStatus.st_dev else {
            throw MountHarnessError.invalidFixture
        }

        var markerStatus = stat()
        let markerResult = markerPath.withCString { lstat($0, &markerStatus) }
        guard markerResult == -1, errno == ENOENT else {
            throw MountHarnessError.invalidFixture
        }

        self.root = root
        canary = Data(Self.canaryText.utf8)
        self.resultMarker = resultMarker
    }
}

private struct MountAwareSnapshotEntry: Hashable {
    let relativeComponents: [Data]
    let identity: FileIdentity
    let contentHash: Data?
}

private enum MountHarnessError: Error {
    case invalidEnvironment
    case invalidFixture
    case snapshotFailed
    case markerFailed
}

private func isValidatedMountWorkDirectory(_ path: String) -> Bool {
    let prefix = "/tmp/project-scanner-mount."
    guard path.hasPrefix(prefix) else { return false }
    let suffix = path.dropFirst(prefix.count)
    return suffix.count == 6 && suffix.allSatisfy {
        ($0.isASCII && $0.isLetter) || $0.isNumber
    }
}

private func status(of url: URL) throws -> stat {
    try url.withUnsafeFileSystemRepresentation { path in
        guard let path else { throw MountHarnessError.invalidFixture }
        var value = stat()
        guard lstat(path, &value) == 0 else { throw MountHarnessError.invalidFixture }
        return value
    }
}

private func mountAwareSnapshot(at root: URL) throws -> Set<MountAwareSnapshotEntry> {
    let descriptor = try root.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else { throw MountHarnessError.snapshotFailed }
        let opened = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard opened >= 0 else { throw MountHarnessError.snapshotFailed }
        return opened
    }
    var rootStatus = stat()
    guard fstat(descriptor, &rootStatus) == 0,
          rootStatus.st_mode & S_IFMT == S_IFDIR else {
        Darwin.close(descriptor)
        throw MountHarnessError.snapshotFailed
    }
    var result = Set<MountAwareSnapshotEntry>()
    try snapshotDirectory(
        taking: descriptor,
        rootDevice: rootStatus.st_dev,
        relativeComponents: [],
        into: &result
    )
    return result
}

private func snapshotDirectory(
    taking descriptor: Int32,
    rootDevice: dev_t,
    relativeComponents: [Data],
    into result: inout Set<MountAwareSnapshotEntry>
) throws {
    guard let cursor = fdopendir(descriptor) else {
        Darwin.close(descriptor)
        throw MountHarnessError.snapshotFailed
    }
    defer { closedir(cursor) }

    while true {
        errno = 0
        guard let entry = readdir(cursor) else {
            guard errno == 0 else { throw MountHarnessError.snapshotFailed }
            return
        }
        var nameStorage = entry.pointee.d_name
        let name = withUnsafeBytes(of: &nameStorage) { raw -> Data in
            let count = raw.firstIndex(of: 0) ?? raw.count
            return Data(raw.prefix(count))
        }
        guard name != Data(".".utf8), name != Data("..".utf8) else { continue }

        let inspected = try name.withNullTerminatedMountBytes { pointer -> stat in
            var value = stat()
            guard fstatat(dirfd(cursor), pointer, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw MountHarnessError.snapshotFailed
            }
            return value
        }
        let identity = try FileIdentity(inspected)
        let components = relativeComponents + [name]

        // The foreign-device identity is recorded, but its directory is never opened
        // and none of its entries or content are observed by this snapshot.
        guard inspected.st_dev == rootDevice else {
            result.insert(MountAwareSnapshotEntry(
                relativeComponents: components,
                identity: identity,
                contentHash: nil
            ))
            continue
        }

        var contentHash: Data?
        if inspected.st_mode & S_IFMT == S_IFREG {
            let file = try name.withNullTerminatedMountBytes { pointer -> Int32 in
                let opened = openat(
                    dirfd(cursor),
                    pointer,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
                guard opened >= 0 else { throw MountHarnessError.snapshotFailed }
                return opened
            }
            defer { Darwin.close(file) }
            _ = try verifiedStatus(
                of: file,
                expected: inspected,
                rootDevice: rootDevice,
                type: S_IFREG
            )
            var content = Data()
            var buffer = [UInt8](repeating: 0, count: 8_192)
            while true {
                let count = Darwin.read(file, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw MountHarnessError.snapshotFailed }
                guard count > 0 else { break }
                content.append(buffer, count: count)
            }
            contentHash = Data(SHA256.hash(data: content))
        }

        result.insert(MountAwareSnapshotEntry(
            relativeComponents: components,
            identity: identity,
            contentHash: contentHash
        ))

        if inspected.st_mode & S_IFMT == S_IFDIR {
            let child = try name.withNullTerminatedMountBytes { pointer -> Int32 in
                let opened = openat(
                    dirfd(cursor),
                    pointer,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard opened >= 0 else { throw MountHarnessError.snapshotFailed }
                return opened
            }
            do {
                _ = try verifiedStatus(
                    of: child,
                    expected: inspected,
                    rootDevice: rootDevice,
                    type: S_IFDIR
                )
            } catch {
                Darwin.close(child)
                throw error
            }
            try snapshotDirectory(
                taking: child,
                rootDevice: rootDevice,
                relativeComponents: components,
                into: &result
            )
        }
    }
}

private func verifiedStatus(
    of descriptor: Int32,
    expected: stat,
    rootDevice: dev_t,
    type: mode_t
) throws -> stat {
    var opened = stat()
    guard fstat(descriptor, &opened) == 0,
          opened.st_dev == rootDevice,
          opened.st_dev == expected.st_dev,
          opened.st_ino == expected.st_ino,
          opened.st_mode & S_IFMT == type else {
        throw MountHarnessError.snapshotFailed
    }
    return opened
}

private func writeAndVerifyResultMarker(at marker: URL) throws {
    let expected = Data(MountHarnessConfiguration.resultMarkerText.utf8)
    let descriptor = try marker.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else { throw MountHarnessError.markerFailed }
        let opened = Darwin.open(
            path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard opened >= 0 else { throw MountHarnessError.markerFailed }
        return opened
    }
    do {
        try expected.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw MountHarnessError.markerFailed }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw MountHarnessError.markerFailed }
        try verifyMarkerStatus(descriptor, byteCount: expected.count)
    } catch {
        Darwin.close(descriptor)
        throw error
    }
    guard Darwin.close(descriptor) == 0 else { throw MountHarnessError.markerFailed }

    let reader = try marker.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else { throw MountHarnessError.markerFailed }
        let opened = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard opened >= 0 else { throw MountHarnessError.markerFailed }
        return opened
    }
    defer { Darwin.close(reader) }
    try verifyMarkerStatus(reader, byteCount: expected.count)
    var received = Data()
    var buffer = [UInt8](repeating: 0, count: 128)
    while true {
        let count = Darwin.read(reader, &buffer, buffer.count)
        if count < 0, errno == EINTR { continue }
        guard count >= 0 else { throw MountHarnessError.markerFailed }
        guard count > 0 else { break }
        received.append(buffer, count: count)
    }
    guard received == expected else { throw MountHarnessError.markerFailed }
}

private func verifyMarkerStatus(_ descriptor: Int32, byteCount: Int) throws {
    var value = stat()
    guard fstat(descriptor, &value) == 0,
          value.st_mode & S_IFMT == S_IFREG,
          value.st_mode & 0o777 == (S_IRUSR | S_IWUSR),
          value.st_uid == geteuid(),
          value.st_nlink == 1,
          value.st_size == off_t(byteCount) else {
        throw MountHarnessError.markerFailed
    }
}

private extension Data {
    func withNullTerminatedMountBytes<T>(
        _ body: (UnsafePointer<CChar>) throws -> T
    ) throws -> T {
        guard !isEmpty, !contains(0) else { throw MountHarnessError.snapshotFailed }
        var terminated = map(CChar.init(bitPattern:))
        terminated.append(0)
        return try terminated.withUnsafeBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }
}
