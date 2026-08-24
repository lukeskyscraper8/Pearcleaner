import Darwin
import Foundation
import XCTest
@testable import ProjectScannerCore

final class RootCapabilityTests: XCTestCase {
    func testSelectedDirectoryPinsDeviceAndInode() throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let root = try fixture.directory(named: "root")
        let expected = try status(of: root)

        let capability = try RootCapability.open(selectedURL: root)
        defer { capability.close() }

        XCTAssertEqual(capability.identity.device, UInt64(expected.st_dev))
        XCTAssertEqual(capability.identity.inode, UInt64(expected.st_ino))
        XCTAssertEqual(capability.identity.mode, UInt16(expected.st_mode))
    }

    func testSelectedRootSymlinkIsRejected() throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let target = try fixture.directory(named: "target")
        let link = fixture.url.appendingPathComponent("link", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try RootCapability.open(selectedURL: link)) { error in
            XCTAssertEqual(error as? ContainmentError, .rootIsLink)
        }
    }

    func testSelectedRegularFileIsRejected() throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let file = try fixture.regularFile(named: "file")

        XCTAssertThrowsError(try RootCapability.open(selectedURL: file)) { error in
            XCTAssertEqual(error as? ContainmentError, .notDirectory)
        }
    }

    func testRenamingPinnedRootDoesNotChangeCapabilityIdentity() throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let root = try fixture.directory(named: "root")
        let moved = fixture.url.appendingPathComponent("root-moved", isDirectory: true)
        let capability = try RootCapability.open(selectedURL: root)
        let originalIdentity = capability.identity

        try FileManager.default.moveItem(at: root, to: moved)
        let broker = try capability.makeFileBroker(limits: .defaults)

        XCTAssertEqual(broker.rootIdentity, originalIdentity)
        XCTAssertEqual(broker.limits, .defaults)
    }

    func testReplacingOriginalPathDoesNotRetargetCapability() throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let root = try fixture.directory(named: "root")
        let moved = fixture.url.appendingPathComponent("root-moved", isDirectory: true)
        let capability = try RootCapability.open(selectedURL: root)
        let originalIdentity = capability.identity

        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let replacementCapability = try RootCapability.open(selectedURL: root)
        defer { replacementCapability.close() }
        let broker = try capability.makeFileBroker(limits: .defaults)

        XCTAssertEqual(broker.rootIdentity, originalIdentity)
        XCTAssertNotEqual(broker.rootIdentity, replacementCapability.identity)
    }

    func testFileIdentityIncludesStatusChangeTimestamp() throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let root = try fixture.directory(named: "root")
        let expected = try status(of: root)

        let capability = try RootCapability.open(selectedURL: root)
        defer { capability.close() }

        XCTAssertEqual(capability.identity.statusChangeSeconds, Int64(expected.st_ctimespec.tv_sec))
        XCTAssertEqual(
            capability.identity.statusChangeNanoseconds,
            Int64(expected.st_ctimespec.tv_nsec)
        )
        XCTAssertEqual(capability.identity.modificationSeconds, Int64(expected.st_mtimespec.tv_sec))
        XCTAssertEqual(
            capability.identity.modificationNanoseconds,
            Int64(expected.st_mtimespec.tv_nsec)
        )
    }

    func testClosingCapabilityPreventsNewBrokerCreation() throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let root = try fixture.directory(named: "root")
        let capability = try RootCapability.open(selectedURL: root)

        capability.close()
        capability.close()

        XCTAssertThrowsError(try capability.makeFileBroker(limits: .defaults)) { error in
            XCTAssertEqual(error as? ContainmentError, .closedCapability)
        }
    }

    func testConcurrentCloseAndBrokerCreationNeverUsesAClosedDescriptor() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let root = try fixture.directory(named: "root")

        for _ in 0..<100 {
            let capability = try RootCapability.open(selectedURL: root)
            let expectedIdentity = capability.identity
            let barrier = AsyncStartBarrier(participantCount: 2)

            async let close: Void = {
                await barrier.wait()
                capability.close()
            }()
            async let vend: BrokerOutcome = {
                await barrier.wait()
                do {
                    let broker = try capability.makeFileBroker(limits: .defaults)
                    return .success(broker.rootIdentity)
                } catch let error as ContainmentError {
                    return .failure(error)
                } catch {
                    XCTFail("Unexpected error type")
                    return .unexpectedFailure
                }
            }()

            let (_, outcome) = await (close, vend)
            switch outcome {
            case let .success(identity):
                XCTAssertEqual(identity, expectedIdentity)
            case let .failure(error):
                XCTAssertEqual(error, .closedCapability)
            case .unexpectedFailure:
                XCTFail("Broker creation produced a non-containment error")
            }
        }
    }

    func testConcurrentBrokerVendsAllowExactlyOneBrokerPerCapability() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let root = try fixture.directory(named: "root")

        for _ in 0..<100 {
            let capability = try RootCapability.open(selectedURL: root)
            let expectedIdentity = capability.identity
            let barrier = AsyncStartBarrier(participantCount: 2)

            async let first = vendBroker(from: capability, after: barrier)
            async let second = vendBroker(from: capability, after: barrier)
            let outcomes = await [first, second]

            XCTAssertEqual(
                outcomes.filter { $0 == .success(expectedIdentity) }.count,
                1
            )
            XCTAssertEqual(
                outcomes.filter { $0 == .failure(.brokerAlreadyIssued) }.count,
                1
            )
        }
    }

    func testContainmentErrorsContainOnlyClosedReasonCodes() throws {
        XCTAssertEqual(
            ContainmentError.allCases,
            [
                .invalidSelection,
                .rootIsLink,
                .notDirectory,
                .openFailed,
                .identityChanged,
                .mountBoundary,
                .closedCapability,
                .brokerAlreadyIssued,
                .pathTooLong,
            ]
        )
        for error in ContainmentError.allCases {
            XCTAssertTrue(Mirror(reflecting: error).children.isEmpty)
            XCTAssertTrue(CoverageReasonCode.allCases.contains(error.coverageReasonCode))
        }
    }

    private func status(of url: URL) throws -> stat {
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw ContainmentError.invalidSelection }
            var value = stat()
            guard lstat(path, &value) == 0 else { throw ContainmentError.openFailed }
            return value
        }
    }
}

private func vendBroker(
    from capability: RootCapability,
    after barrier: AsyncStartBarrier
) async -> BrokerOutcome {
    await barrier.wait()
    do {
        let broker = try capability.makeFileBroker(limits: .defaults)
        return .success(broker.rootIdentity)
    } catch let error as ContainmentError {
        return .failure(error)
    } catch {
        return .unexpectedFailure
    }
}

private enum BrokerOutcome: Sendable, Equatable {
    case success(FileIdentity)
    case failure(ContainmentError)
    case unexpectedFailure
}

private actor AsyncStartBarrier {
    private let participantCount: Int
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(participantCount: Int) {
        self.participantCount = participantCount
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
            guard continuations.count == participantCount else { return }
            let waiting = continuations
            continuations.removeAll(keepingCapacity: true)
            waiting.forEach { $0.resume() }
        }
    }
}
