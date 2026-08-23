import Darwin
import Foundation
import XCTest
@testable import ProjectScannerCore

final class PrivateStateParentCapabilityTests: XCTestCase {
    func testPrivateStateParentCapabilityRejectsSymlinkAndIdentityRace() throws {
        let fixture = try PrivateParentFixture()
        defer { fixture.remove() }
        let target = try fixture.directory("target")
        let link = fixture.parent.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try PrivateStateParentCapability.open(applicationSupportURL: link)) {
            XCTAssertEqual($0 as? PrivateStateParentError, .symlink)
        }

        let raced = try fixture.directory("raced")
        let moved = fixture.parent.appendingPathComponent("moved", isDirectory: true)
        let pause = PrivateStateParentOpenPause()
        let finished = expectation(description: "open finished")
        let result = LockedPrivateParentResult()
        DispatchQueue.global().async {
            result.store(Result {
                try PrivateStateParentCapability.open(
                    applicationSupportURL: raced,
                    testPause: pause
                )
            })
            finished.fulfill()
        }
        XCTAssertTrue(pause.waitUntilPaused(timeout: 2))
        try FileManager.default.moveItem(at: raced, to: moved)
        try FileManager.default.createDirectory(at: raced, withIntermediateDirectories: false)
        _ = chmod(raced.path, 0o700)
        pause.resume()
        wait(for: [finished], timeout: 2)

        guard case let .failure(error) = result.value else {
            return XCTFail("Identity replacement was accepted")
        }
        XCTAssertEqual(error as? PrivateStateParentError, .identityChanged)
    }

    func testRegularFileIsRejectedAsNotDirectory() throws {
        let fixture = try PrivateParentFixture()
        defer { fixture.remove() }
        let file = fixture.parent.appendingPathComponent("file")
        try Data([0]).write(to: file)

        XCTAssertThrowsError(try PrivateStateParentCapability.open(applicationSupportURL: file)) {
            XCTAssertEqual($0 as? PrivateStateParentError, .notDirectory)
        }
    }

    func testWrongOwnerHasClosedClassification() throws {
        let fixture = try PrivateParentFixture()
        defer { fixture.remove() }
        let directory = try fixture.directory("owned")
        let inspected = try status(of: directory)
        var opened = inspected
        opened.st_uid = inspected.st_uid == 0 ? 1 : 0

        XCTAssertThrowsError(
            try PrivateStateParentCapability.validate(
                inspected: inspected,
                opened: opened,
                effectiveUserID: inspected.st_uid
            )
        ) {
            XCTAssertEqual($0 as? PrivateStateParentError, .wrongOwner)
        }
    }

    func testGroupAndWorldWritableDirectoriesAreRejected() throws {
        let fixture = try PrivateParentFixture()
        defer { fixture.remove() }
        for (name, mode) in [("group", 0o720), ("world", 0o702)] {
            let directory = try fixture.directory(name)
            XCTAssertEqual(chmod(directory.path, mode_t(mode)), 0)
            XCTAssertThrowsError(
                try PrivateStateParentCapability.open(applicationSupportURL: directory)
            ) {
                XCTAssertEqual($0 as? PrivateStateParentError, .unsafePermissions)
            }
        }
    }

    func testValidatedDuplicationRejectsPostOpenUnsafeMode() throws {
        let fixture = try PrivateParentFixture()
        defer { fixture.remove() }
        let directory = try fixture.directory("safe")
        let capability = try PrivateStateParentCapability.open(applicationSupportURL: directory)
        defer { capability.close() }
        XCTAssertEqual(chmod(directory.path, 0o722), 0)

        XCTAssertThrowsError(try capability.duplicateValidatedDescriptor()) {
            XCTAssertEqual($0 as? PrivateStateParentError, .unsafePermissions)
        }
    }

    func testValidatedDuplicationProducesReadOnlyCloseOnExecDirectoryDescriptor() throws {
        let fixture = try PrivateParentFixture()
        defer { fixture.remove() }
        let directory = try fixture.directory("safe")
        let capability = try PrivateStateParentCapability.open(applicationSupportURL: directory)
        defer { capability.close() }

        let descriptor = try capability.duplicateValidatedDescriptor()
        defer { Darwin.close(descriptor) }

        XCTAssertGreaterThanOrEqual(fcntl(descriptor, F_GETFD), 0)
        XCTAssertNotEqual(fcntl(descriptor, F_GETFD) & FD_CLOEXEC, 0)
        XCTAssertEqual(fcntl(descriptor, F_GETFL) & O_ACCMODE, O_RDONLY)
    }

    private func status(of url: URL) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw PrivateStateParentError.openFailed }
        return value
    }
}

private final class LockedPrivateParentResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<PrivateStateParentCapability, Error>?

    var value: Result<PrivateStateParentCapability, Error>? {
        lock.withLock { result }
    }

    func store(_ result: Result<PrivateStateParentCapability, Error>) {
        lock.withLock { self.result = result }
    }
}

private final class PrivateParentFixture {
    let parent: URL

    init() throws {
        parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        _ = chmod(parent.path, 0o700)
    }

    func directory(_ name: String) throws -> URL {
        let url = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        _ = chmod(url.path, 0o700)
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: parent)
    }
}
