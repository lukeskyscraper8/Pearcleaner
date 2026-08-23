import Darwin
import Foundation
import XCTest
@testable import ProjectScannerCore

final class ProjectBookmarkTests: XCTestCase {
    func testCreationUsesReadOnlySecurityScopeAndReturnsOpaqueValue() throws {
        let fixture = try BookmarkFixture()
        defer { fixture.remove() }
        let client = RecordingBookmarkClient(resolvedURL: fixture.root)
        let access = ProjectBookmarkAccess(client: client)

        let bookmark = try access.create(selectedURL: fixture.root)

        XCTAssertEqual(client.creationOptions, [.withSecurityScope, .securityScopeAllowOnlyReadAccess])
        XCTAssertNil(client.creationKeys)
        XCTAssertNil(client.creationRelativeURL)
        XCTAssertEqual(client.resolveOptions, .withSecurityScope)
        XCTAssertEqual(client.startCount, 1)
        XCTAssertEqual(client.stopCount, 1)
        XCTAssertFalse(ProjectBookmarkPersistence.encode(bookmark).isEmpty)
    }

    func testArbitraryDataCannotConstructABookmark() {
        let malformed: [Data] = [
            Data(),
            Data("arbitrary".utf8),
            Data([0x50, 0x53, 0x42, 0x4D, 0x01]),
        ]

        for storage in malformed {
            XCTAssertThrowsError(try ProjectBookmarkPersistence.decode(storage)) { error in
                XCTAssertEqual(error as? ProjectBookmarkError, .invalidBookmark)
            }
        }
    }

    func testRoundTripRequiresFreshRootCapabilityOpen() throws {
        let fixture = try BookmarkFixture()
        defer { fixture.remove() }
        let client = RecordingBookmarkClient(resolvedURL: fixture.root)
        let access = ProjectBookmarkAccess(client: client)
        let bookmark = try access.create(selectedURL: fixture.root)

        try FileManager.default.removeItem(at: fixture.root)
        try Data("not a directory".utf8).write(to: fixture.root)

        XCTAssertThrowsError(try access.resolve(bookmark)) { error in
            XCTAssertEqual(error as? ProjectBookmarkError, .rootUnavailable)
        }
        XCTAssertEqual(client.stopCount, 2)
    }

    func testStaleBookmarkIsReportedAndDoesNotAuthorizeRoot() throws {
        let fixture = try BookmarkFixture()
        defer { fixture.remove() }
        let client = RecordingBookmarkClient(resolvedURL: fixture.root)
        client.isStale = true
        let access = ProjectBookmarkAccess(client: client)

        XCTAssertThrowsError(try access.create(selectedURL: fixture.root)) { error in
            XCTAssertEqual(error as? ProjectBookmarkError, .staleBookmark)
        }
        XCTAssertEqual(client.startCount, 0)
        XCTAssertEqual(client.stopCount, 0)
    }

    func testMovedBookmarkedRootKeepsIdentityAfterFreshOpen() throws {
        let fixture = try BookmarkFixture()
        defer { fixture.remove() }
        let client = RecordingBookmarkClient(resolvedURL: fixture.root)
        let access = ProjectBookmarkAccess(client: client)
        let bookmark = try access.create(selectedURL: fixture.root)
        let moved = fixture.parent.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.root, to: moved)
        client.resolvedURL = moved

        let lease = try access.resolve(bookmark)
        defer { lease.close() }

        XCTAssertEqual(lease.rootCapability.identity.device, try device(of: moved))
        XCTAssertEqual(lease.rootCapability.identity.inode, try inode(of: moved))
    }

    func testReplacementAtFormerBookmarkPathIsNotSilentlyAuthorized() throws {
        let fixture = try BookmarkFixture()
        defer { fixture.remove() }
        let client = RecordingBookmarkClient(resolvedURL: fixture.root)
        let access = ProjectBookmarkAccess(client: client)
        let bookmark = try access.create(selectedURL: fixture.root)
        let moved = fixture.parent.appendingPathComponent("original", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.root, to: moved)
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: false)

        XCTAssertThrowsError(try access.resolve(bookmark)) { error in
            XCTAssertEqual(error as? ProjectBookmarkError, .identityChanged)
        }
        XCTAssertEqual(client.stopCount, 2)
    }

    func testAccessFailureReturnsNoLease() throws {
        let fixture = try BookmarkFixture()
        defer { fixture.remove() }
        let client = RecordingBookmarkClient(resolvedURL: fixture.root)
        let access = ProjectBookmarkAccess(client: client)
        let bookmark = try access.create(selectedURL: fixture.root)
        client.shouldStart = false

        XCTAssertThrowsError(try access.resolve(bookmark)) { error in
            XCTAssertEqual(error as? ProjectBookmarkError, .accessDenied)
        }
        XCTAssertEqual(client.stopCount, 1)
    }

    func testStoredBookmarkBytesStillRequireResolutionValidation() throws {
        let fixture = try BookmarkFixture()
        defer { fixture.remove() }
        let client = RecordingBookmarkClient(resolvedURL: fixture.root)
        let access = ProjectBookmarkAccess(client: client)
        let bookmark = try access.create(selectedURL: fixture.root)
        var storage = ProjectBookmarkPersistence.encode(bookmark)
        storage[13] ^= 0x01
        let tampered = try ProjectBookmarkPersistence.decode(storage)

        XCTAssertThrowsError(try access.resolve(tampered)) { error in
            XCTAssertEqual(error as? ProjectBookmarkError, .identityChanged)
        }
        XCTAssertEqual(client.stopCount, 2)
    }

    func testConcurrentLeaseCloseStopsSecurityScopeExactlyOnce() async throws {
        let fixture = try BookmarkFixture()
        defer { fixture.remove() }
        let client = RecordingBookmarkClient(resolvedURL: fixture.root)
        let access = ProjectBookmarkAccess(client: client)
        let bookmark = try access.create(selectedURL: fixture.root)
        let lease = try access.resolve(bookmark)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask { lease.close() }
            }
        }

        XCTAssertEqual(client.stopCount, 2)
    }

    func testEnvelopeUsesGoldenBigEndianLayout() throws {
        let storage = Data([
            0x50, 0x53, 0x42, 0x4D, 0x01,
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
            0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
            0x40, 0x00,
            0x00, 0x00, 0x00, 0x03,
            0xAA, 0xBB, 0xCC,
        ])

        let bookmark = try ProjectBookmarkPersistence.decode(storage)

        XCTAssertEqual(ProjectBookmarkPersistence.encode(bookmark), storage)
    }

    func testPersistenceRejectsMalformedEnvelopeMatrix() throws {
        let valid = Data([
            0x50, 0x53, 0x42, 0x4D, 0x01,
            0, 0, 0, 0, 0, 0, 0, 1,
            0, 0, 0, 0, 0, 0, 0, 2,
            0x40, 0x00,
            0, 0, 0, 1,
            0xAA,
        ])
        var cases: [Data] = []
        cases.append(Data(valid.dropFirst()))
        var badMagic = valid; badMagic[0] = 0; cases.append(badMagic)
        var badVersion = valid; badVersion[4] = 2; cases.append(badVersion)
        var badType = valid; badType[21] = 0x80; cases.append(badType)
        cases.append(Data(valid.dropLast()))
        var zeroLength = valid; zeroLength[26] = 0; cases.append(zeroLength)
        var overflowLength = valid; overflowLength[23] = 0xFF; cases.append(overflowLength)
        cases.append(valid + Data([0]))
        cases.append(Data(repeating: 0, count: 1_048_577))

        for storage in cases {
            XCTAssertThrowsError(try ProjectBookmarkPersistence.decode(storage)) { error in
                XCTAssertEqual(error as? ProjectBookmarkError, .invalidBookmark)
            }
        }
    }

    func testDirectoryContentAndMetadataChangesDoNotInvalidateStableIdentity() throws {
        let fixture = try BookmarkFixture()
        defer { fixture.remove() }
        let client = RecordingBookmarkClient(resolvedURL: fixture.root)
        client.onResolve = {
            let child = fixture.root.appendingPathComponent("new-child")
            try? Data([0x01]).write(to: child)
            _ = chmod(fixture.root.path, 0o700)
        }
        let access = ProjectBookmarkAccess(client: client)

        let bookmark = try access.create(selectedURL: fixture.root)
        let lease = try access.resolve(bookmark)
        lease.close()

        XCTAssertEqual(client.stopCount, 2)
    }

    private func device(of url: URL) throws -> UInt64 {
        UInt64(try status(of: url).st_dev)
    }

    private func inode(of url: URL) throws -> UInt64 {
        UInt64(try status(of: url).st_ino)
    }

    private func status(of url: URL) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw ProjectBookmarkError.rootUnavailable }
        return value
    }
}

private final class RecordingBookmarkClient: BookmarkClient, @unchecked Sendable {
    private let lock = NSLock()
    private let bookmarkData = Data([0xA1, 0xB2, 0xC3])
    var resolvedURL: URL
    var isStale = false
    var shouldStart = true
    var onResolve: (() -> Void)?
    private(set) var creationOptions: URL.BookmarkCreationOptions?
    private(set) var creationKeys: Set<URLResourceKey>?
    private(set) var creationRelativeURL: URL?
    private(set) var resolveOptions: URL.BookmarkResolutionOptions?
    private var starts = 0
    private var stops = 0

    init(resolvedURL: URL) {
        self.resolvedURL = resolvedURL
    }

    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }

    func createBookmark(
        for url: URL,
        options: URL.BookmarkCreationOptions,
        resourceValuesForKeys keys: Set<URLResourceKey>?,
        relativeTo relativeURL: URL?
    ) throws -> Data {
        creationOptions = options
        creationKeys = keys
        creationRelativeURL = relativeURL
        return bookmarkData
    }

    func resolveBookmark(
        _ data: Data,
        options: URL.BookmarkResolutionOptions,
        relativeTo relativeURL: URL?,
        isStale: inout Bool
    ) throws -> URL {
        XCTAssertEqual(data, bookmarkData)
        XCTAssertNil(relativeURL)
        resolveOptions = options
        onResolve?()
        isStale = self.isStale
        return resolvedURL
    }

    func startAccessing(_ url: URL) -> Bool {
        lock.withLock { starts += 1 }
        return shouldStart
    }

    func stopAccessing(_ url: URL) {
        lock.withLock { stops += 1 }
    }
}

private final class BookmarkFixture {
    let parent: URL
    let root: URL

    init() throws {
        parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        root = parent.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: parent)
    }
}
