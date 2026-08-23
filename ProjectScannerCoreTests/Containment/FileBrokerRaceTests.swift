import Darwin
import Foundation
import XCTest
@testable import ProjectScannerCore

final class FileBrokerRaceTests: XCTestCase {
    func testCandidateReplacementBeforeReopenIsRejected() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let file = try fixture.regularFile(named: "candidate", contents: Data("old".utf8))
        guard let (broker, _, candidate) = try await operationalCandidate(fixture, file: file) else { return }
        try FileManager.default.removeItem(at: file)
        _ = try fixture.regularFile(named: "candidate", contents: Data("new".utf8))

        let revalidation = await broker.revalidate(candidate)
        XCTAssertEqual(revalidation, .rejected(.identityChanged))
    }

    func testRegularEntryReplacedByFIFOBeforeOpenIsRejectedWithoutBlocking() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let file = try fixture.regularFile(named: "race")
        guard try await traversalIsOperational(fixture) else { return }
        let control = FileBrokerTestControl(pausingAt: [.afterEntryInspection])
        let rootURL = fixture.url
        let task = Task { try await traverseWithControl(rootURL, control: control) }
        await control.waitUntilReached(.afterEntryInspection)
        try FileManager.default.removeItem(at: file)
        try fixture.fifo(at: file)
        let clock = ContinuousClock()
        let started = clock.now
        await control.resume(.afterEntryInspection)
        let events = try await task.value

        XCTAssertLessThan(started.duration(to: clock.now), .milliseconds(500))
        XCTAssertTrue(skips(in: events).contains { $0.1 == .identityChanged })
    }

    func testRegularEntryReplacedBySocketBeforeOpenIsRejectedWithoutBlocking() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let file = try fixture.regularFile(named: "race")
        guard try await traversalIsOperational(fixture) else { return }
        let control = FileBrokerTestControl(pausingAt: [.afterEntryInspection])
        let rootURL = fixture.url
        let task = Task { try await traverseWithControl(rootURL, control: control) }
        await control.waitUntilReached(.afterEntryInspection)
        try FileManager.default.removeItem(at: file)
        try fixture.unixSocket(at: file)
        let clock = ContinuousClock()
        let started = clock.now
        await control.resume(.afterEntryInspection)
        let events = try await task.value

        XCTAssertLessThan(started.duration(to: clock.now), .milliseconds(500))
        XCTAssertTrue(skips(in: events).contains { $0.1 == .identityChanged })
    }

    func testRelativeLinkTargetReplacementBeforeOpenIsRejected() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let target = try fixture.regularFile(named: "target", contents: Data("old".utf8))
        try fixture.symbolicLink(at: fixture.url.appendingPathComponent("link"), target: "target")
        guard try await traversalIsOperational(fixture) else { return }
        let control = FileBrokerTestControl(pausingAt: [.afterSymlinkTargetRead])
        let rootURL = fixture.url
        let task = Task { try await traverseWithControl(rootURL, control: control) }
        await control.waitUntilReached(.afterSymlinkTargetRead)
        try FileManager.default.removeItem(at: target)
        _ = try fixture.regularFile(named: "target", contents: Data("new".utf8))
        await control.resume(.afterSymlinkTargetRead)
        let events = try await task.value

        XCTAssertTrue(skips(in: events).contains {
            path(of: $0.0) == "link" && $0.1 == .identityChanged
        })
    }

    func testRetargetedLinkIsRejectedEvenWhenOriginalTargetStillExists() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        _ = try fixture.regularFile(named: "first")
        _ = try fixture.regularFile(named: "second")
        let link = fixture.url.appendingPathComponent("link")
        try fixture.symbolicLink(at: link, target: "first")
        guard try await traversalIsOperational(fixture) else { return }
        let control = FileBrokerTestControl(pausingAt: [.afterSymlinkTargetRead])
        let rootURL = fixture.url
        let task = Task { try await traverseWithControl(rootURL, control: control) }
        await control.waitUntilReached(.afterSymlinkTargetRead)
        try FileManager.default.removeItem(at: link)
        try fixture.symbolicLink(at: link, target: "second")
        await control.resume(.afterSymlinkTargetRead)
        let events = try await task.value

        XCTAssertTrue(skips(in: events).contains {
            path(of: $0.0) == "link" && $0.1 == .identityChanged
        })
    }

    func testEntryVanishingAfterReaddirProducesTypedSkip() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let file = try fixture.regularFile(named: "vanish")
        guard try await traversalIsOperational(fixture) else { return }
        let control = FileBrokerTestControl(pausingAt: [.afterDirectoryEntryRead])
        let rootURL = fixture.url
        let task = Task { try await traverseWithControl(rootURL, control: control) }
        await control.waitUntilReached(.afterDirectoryEntryRead)
        try FileManager.default.removeItem(at: file)
        await control.resume(.afterDirectoryEntryRead)
        let events = try await task.value

        XCTAssertTrue(skips(in: events).contains {
            path(of: $0.0) == "vanish" && $0.1 == .identityChanged
        })
    }

    func testUnreadableSubtreeProducesTypedCoverageWithoutStoppingPeers() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let unreadable = try fixture.directory(named: "unreadable")
        _ = try fixture.regularFile(named: "peer")
        guard chmod(unreadable.path, 0) == 0 else { return XCTFail("chmod failed") }
        defer { _ = chmod(unreadable.path, S_IRUSR | S_IWUSR | S_IXUSR) }

        let events = try await traverse(fixture.url)

        XCTAssertTrue(candidatePaths(in: events).contains("peer"))
        XCTAssertTrue(skips(in: events).contains {
            path(of: $0.0) == "unreadable" && $0.1 == .unreadable
        })
    }

    func testRenamingParentThenReplacingItsPathCannotRedirectBroker() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let parent = try fixture.directory(named: "parent")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: parent.appendingPathComponent("inside").path,
            contents: Data("inside".utf8)
        ))
        guard try await traversalIsOperational(fixture) else { return }
        let control = FileBrokerTestControl(pausingAt: [.afterEntryInspection])
        let rootURL = fixture.url
        let task = Task { try await traverseWithControl(rootURL, control: control) }
        await control.waitUntilReached(.afterEntryInspection)
        let moved = fixture.url.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.moveItem(at: parent, to: moved)
        try fixture.symbolicLink(at: parent, target: fixture.outsideCanaryURL.path)
        await control.resume(.afterEntryInspection)
        let events = try await task.value
        let outsideIdentity = try fixture.identity(of: fixture.outsideCanaryURL)

        XCTAssertFalse(candidateEvents(in: events).contains { $0.identity.inode == outsideIdentity.inode })
    }

    func testOutsideCanaryIsNeverReturnedDuringBoundedRenameRace() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let stable = try fixture.regularFile(named: "stable", contents: Data("inside".utf8))
        guard try await traversalIsOperational(fixture) else { return }
        let outsideIdentity = try fixture.identity(of: fixture.outsideCanaryURL)

        let stableURL = stable
        let outsideURL = fixture.outsideCanaryURL
        for _ in 0..<1_000 {
            let capability = try RootCapability.open(selectedURL: fixture.url)
            let broker = try capability.makeFileBroker(limits: .defaults)
            let traversal = try await broker.makeTraversal()
            let replacement = fixture.url.appendingPathComponent("replacement")
            let race = Task {
                try? FileManager.default.removeItem(at: replacement)
                try? FileManager.default.moveItem(at: stableURL, to: replacement)
                try? FileManager.default.createSymbolicLink(at: stableURL, withDestinationURL: outsideURL)
                try? FileManager.default.removeItem(at: stableURL)
                try? FileManager.default.moveItem(at: replacement, to: stableURL)
            }
            let event = try await traversal.next()
            _ = await race.result
            if case let .candidate(candidate)? = event {
                XCTAssertNotEqual(candidate.identity.inode, outsideIdentity.inode)
            }
            await traversal.cancel()
        }
    }

    func testConcurrentTraversalVendsAllowExactlyOneTraversalPerBroker() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let capability = try RootCapability.open(selectedURL: fixture.url)
        let broker = try capability.makeFileBroker(limits: .defaults)

        async let first = traversalVend(from: broker)
        async let second = traversalVend(from: broker)
        let results = await [first, second]

        XCTAssertEqual(results.filter { $0 == .success }.count, 1)
        XCTAssertEqual(results.filter { $0 == .alreadyIssued }.count, 1)
    }

    func testEarlyTraversalCancellationClosesItsDirectoryStack() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        _ = try fixture.regularFile(named: "peer")
        let control = FileBrokerTestControl(pausingAt: [.afterDirectoryEntryRead])
        let capability = try RootCapability.open(selectedURL: fixture.url)
        let broker = try capability.makeFileBroker(limits: .defaults, testControl: control)
        let traversal = try await broker.makeTraversal()
        let next = Task { try await traversal.next() }
        await control.waitUntilReached(.afterDirectoryEntryRead)
        let activeSummary = await traversal.summary()
        XCTAssertGreaterThan(activeSummary.openDirectoryDescriptorCount, 0)

        await traversal.cancel()
        await traversal.cancel()
        await control.resume(.afterDirectoryEntryRead)

        let nextEvent = try await next.value
        XCTAssertNil(nextEvent)
        let cancelledSummary = await traversal.summary()
        XCTAssertEqual(cancelledSummary.openDirectoryDescriptorCount, 0)
        XCTAssertTrue(cancelledSummary.cancelled)
    }

    private func operationalCandidate(
        _ fixture: TemporaryProjectFixture,
        file: URL
    ) async throws -> (FileBroker, FileTraversal, FileCandidate)? {
        let capability = try RootCapability.open(selectedURL: fixture.url)
        let broker = try capability.makeFileBroker(limits: .defaults)
        let traversal = try await broker.makeTraversal()
        guard case let .candidate(candidate)? = try await traversal.next() else {
            XCTFail("Traversal scaffold has not produced its first candidate")
            return nil
        }
        XCTAssertEqual(candidate.logicalPath.escapedForDisplay().text, file.lastPathComponent)
        return (broker, traversal, candidate)
    }

    private func traversalIsOperational(_ fixture: TemporaryProjectFixture) async throws -> Bool {
        let probe = fixture.url.appendingPathComponent("operational-probe")
        guard FileManager.default.createFile(atPath: probe.path, contents: Data()) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: probe) }
        let events = try await traverse(fixture.url)
        guard candidatePaths(in: events).contains("operational-probe") else {
            XCTFail("Traversal scaffold has not produced a regular-file candidate")
            return false
        }
        return true
    }
}

private func traverseWithControl(
    _ root: URL,
    control: FileBrokerTestControl
) async throws -> [TraversalEvent] {
    let capability = try RootCapability.open(selectedURL: root)
    let broker = try capability.makeFileBroker(limits: .defaults, testControl: control)
    let traversal = try await broker.makeTraversal()
    var events: [TraversalEvent] = []
    while let event = try await traversal.next() {
        events.append(event)
    }
    return events
}

private enum TraversalVendResult: Equatable {
    case success
    case alreadyIssued
    case unexpected
}

private func traversalVend(from broker: FileBroker) async -> TraversalVendResult {
    do {
        _ = try await broker.makeTraversal()
        return .success
    } catch FileBrokerError.traversalAlreadyIssued {
        return .alreadyIssued
    } catch {
        return .unexpected
    }
}
