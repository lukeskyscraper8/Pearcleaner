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

    func testRegularEntryReplacedByDifferentRegularBeforeOpenIsRejected() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let file = try fixture.regularFile(named: "race", contents: Data("old".utf8))
        guard try await traversalIsOperational(fixture) else { return }
        let control = FileBrokerTestControl(pausingAt: [.afterEntryInspection])
        let rootURL = fixture.url
        let task = Task { try await traverseWithControl(rootURL, control: control) }
        await control.waitUntilReached(.afterEntryInspection)
        try FileManager.default.removeItem(at: file)
        _ = try fixture.regularFile(named: "race", contents: Data("different".utf8))
        await control.resume(.afterEntryInspection)

        let events = try await task.value

        XCTAssertTrue(skips(in: events).contains {
            path(of: $0.0) == "race" && $0.1 == .identityChanged
        })
        XCTAssertFalse(candidatePaths(in: events).contains("race"))
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

    func testNestedLinkRetargetBetweenProofAndFinalOpenIsRejected() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        _ = try fixture.regularFile(named: "first", contents: Data("first".utf8))
        _ = try fixture.regularFile(named: "second", contents: Data("second".utf8))
        let nested = fixture.url.appendingPathComponent("nested")
        try fixture.symbolicLink(at: fixture.url.appendingPathComponent("outer"), target: "nested")
        try fixture.symbolicLink(at: nested, target: "first")
        guard try await traversalIsOperational(fixture) else { return }
        let control = FileBrokerTestControl(
            pausingAt: .afterSymlinkTargetRead,
            occurrence: 2
        )
        let rootURL = fixture.url
        let task = Task { try await traverseWithControl(rootURL, control: control) }
        await control.waitUntilReached(.afterSymlinkTargetRead)
        try FileManager.default.removeItem(at: nested)
        try fixture.symbolicLink(at: nested, target: "second")
        await control.resume(.afterSymlinkTargetRead)

        let events = try await task.value

        XCTAssertTrue(skips(in: events).contains {
            path(of: $0.0) == "outer" && $0.1 == .identityChanged
        })
        XCTAssertFalse(candidatePaths(in: events).contains("outer"))
    }

    func testNestedLinkRetargetAfterFirstBrokerProofReplayIsRejected() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        _ = try fixture.regularFile(named: "first", contents: Data("first".utf8))
        _ = try fixture.regularFile(named: "second", contents: Data("second".utf8))
        let nested = fixture.url.appendingPathComponent("nested")
        try fixture.symbolicLink(at: nested, target: "first")
        try fixture.symbolicLink(at: fixture.url.appendingPathComponent("outer"), target: "nested")
        let control = FileBrokerTestControl(pausingAt: [.afterProofReplay])
        let capability = try RootCapability.open(selectedURL: fixture.url)
        let broker = try capability.makeFileBroker(limits: .defaults, testControl: control)
        let traversal = try await broker.makeTraversal()
        var outer: FileCandidate?
        while let event = try await traversal.next() {
            if case let .candidate(candidate) = event,
               candidate.logicalPath.escapedForDisplay().text == "outer" {
                outer = candidate
            }
        }
        guard let outer else { return XCTFail("Expected outer candidate") }

        let validation = Task { await broker.revalidate(outer) }
        await control.waitUntilReached(.afterProofReplay)
        try FileManager.default.removeItem(at: nested)
        try fixture.symbolicLink(at: nested, target: "second")
        await control.resume(.afterProofReplay)

        let result = await validation.value
        XCTAssertEqual(result, .rejected(.identityChanged))
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
        try fixture.symbolicLink(
            at: parent.appendingPathComponent("inside-link"),
            target: "inside"
        )
        guard try await traversalIsOperational(fixture) else { return }
        let control = FileBrokerTestControl(pausingAt: [.afterSymlinkInspection])
        let rootURL = fixture.url
        let task = Task { try await traverseWithControl(rootURL, control: control) }
        await control.waitUntilReached(.afterSymlinkInspection)
        let moved = fixture.url.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.moveItem(at: parent, to: moved)
        try fixture.symbolicLink(at: parent, target: fixture.outsideCanaryURL.path)
        await control.resume(.afterSymlinkInspection)
        let events = try await task.value
        let outsideIdentity = try fixture.identity(of: fixture.outsideCanaryURL)

        XCTAssertFalse(candidateEvents(in: events).contains { $0.identity == outsideIdentity })
        XCTAssertTrue(events.contains {
            switch $0 {
            case let .candidate(candidate):
                candidate.logicalPath.escapedForDisplay().text == "parent/inside-link"
            case let .skipped(location, _):
                path(of: location) == "parent/inside-link"
            }
        })
    }

    func testOutsideCanaryIsNeverReturnedDuringBoundedRenameRace() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let stable = try fixture.regularFile(named: "stable", contents: Data("inside".utf8))
        guard try await traversalIsOperational(fixture) else { return }
        let outsideIdentity = try fixture.identity(of: fixture.outsideCanaryURL)

        let outsideURL = fixture.outsideCanaryURL
        for _ in 0..<1_000 {
            let capability = try RootCapability.open(selectedURL: fixture.url)
            let control = FileBrokerTestControl(pausingAt: [.afterEntryInspection])
            let broker = try capability.makeFileBroker(limits: .defaults, testControl: control)
            let traversal = try await broker.makeTraversal()
            let replacement = fixture.url.appendingPathComponent("replacement")
            let next = Task { try await traversal.next() }
            await control.waitUntilReached(.afterEntryInspection)
            let replacementAttempt = Task {
                try FileManager.default.moveItem(at: stable, to: replacement)
                try FileManager.default.createSymbolicLink(at: stable, withDestinationURL: outsideURL)
            }
            try await replacementAttempt.value
            await control.resume(.afterEntryInspection)
            let event = try await next.value
            try FileManager.default.removeItem(at: stable)
            try FileManager.default.moveItem(at: replacement, to: stable)
            guard let event else {
                XCTFail("Every stress iteration must produce a candidate or typed skip")
                await traversal.cancel()
                continue
            }
            switch event {
            case let .candidate(candidate):
                XCTAssertNotEqual(candidate.identity, outsideIdentity)
            case let .skipped(location, reason):
                XCTAssertEqual(path(of: location), "stable")
                XCTAssertEqual(reason, .identityChanged)
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
        let next = Task {
            while try await traversal.next() != nil {}
            return Optional<TraversalEvent>.none
        }
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

    func testBrokerDescriptorAccountingReturnsToZeroAfterCompletionAndError() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        _ = try fixture.regularFile(named: "peer")
        let unreadable = try fixture.directory(named: "unreadable")
        guard chmod(unreadable.path, 0) == 0 else { return XCTFail("chmod failed") }
        defer { _ = chmod(unreadable.path, S_IRUSR | S_IWUSR | S_IXUSR) }
        let capability = try RootCapability.open(selectedURL: fixture.url)
        let broker = try capability.makeFileBroker(limits: .defaults)
        let traversal = try await broker.makeTraversal()
        let activeCount = await broker.openTraversalDirectoryDescriptorCount()
        XCTAssertGreaterThan(activeCount, 0)

        while try await traversal.next() != nil {}

        let finishedCount = await broker.openTraversalDirectoryDescriptorCount()
        XCTAssertEqual(finishedCount, 0)
    }

    func testBrokerDescriptorAccountingReturnsToZeroAfterExplicitCancellation() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        _ = try fixture.regularFile(named: "peer")
        let capability = try RootCapability.open(selectedURL: fixture.url)
        let broker = try capability.makeFileBroker(limits: .defaults)
        let traversal = try await broker.makeTraversal()
        let activeCount = await broker.openTraversalDirectoryDescriptorCount()
        XCTAssertGreaterThan(activeCount, 0)

        await traversal.cancel()

        let cancelledCount = await broker.openTraversalDirectoryDescriptorCount()
        XCTAssertEqual(cancelledCount, 0)
    }

    func testDroppingLiveTraversalClosesBrokerAccountedDescriptors() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        _ = try fixture.regularFile(named: "peer")
        let capability = try RootCapability.open(selectedURL: fixture.url)
        let broker = try capability.makeFileBroker(limits: .defaults)
        var traversal: FileTraversal? = try await broker.makeTraversal()
        XCTAssertNotNil(traversal)
        let activeCount = await broker.openTraversalDirectoryDescriptorCount()
        XCTAssertGreaterThan(activeCount, 0)

        traversal = nil
        for _ in 0..<100 {
            guard await broker.openTraversalDirectoryDescriptorCount() != 0 else { break }
            await Task.yield()
        }

        let abandonedCount = await broker.openTraversalDirectoryDescriptorCount()
        XCTAssertEqual(abandonedCount, 0)
    }

    func testExplicitCancellationAtEveryTraversalSuspensionStopsWithoutYielding() async throws {
        try await assertExplicitCancellation(
            point: .afterEntryInspection,
            setup: { fixture in _ = try fixture.regularFile(named: "regular") }
        )
        try await assertExplicitCancellation(
            point: .afterEntryInspection,
            setup: { fixture in _ = try fixture.directory(named: "directory") }
        )
        try await assertExplicitCancellation(
            point: .afterSymlinkInspection,
            setup: { fixture in
                _ = try fixture.regularFile(named: "target")
                try fixture.symbolicLink(at: fixture.url.appendingPathComponent("link"), target: "target")
            }
        )
        try await assertExplicitCancellation(
            point: .afterSymlinkTargetRead,
            setup: { fixture in
                _ = try fixture.regularFile(named: "target")
                try fixture.symbolicLink(at: fixture.url.appendingPathComponent("link"), target: "target")
            }
        )
    }

    func testTaskCancellationAfterEntryInspectionStopsWithoutYielding() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        _ = try fixture.regularFile(named: "regular")
        let control = FileBrokerTestControl(pausingAt: [.afterEntryInspection])
        let capability = try RootCapability.open(selectedURL: fixture.url)
        let broker = try capability.makeFileBroker(limits: .defaults, testControl: control)
        let traversal = try await broker.makeTraversal()
        let next = Task { try await traversal.next() }
        await control.waitUntilReached(.afterEntryInspection)

        next.cancel()
        await control.resume(.afterEntryInspection)

        let event = try await next.value
        let descriptorCount = await broker.openTraversalDirectoryDescriptorCount()
        XCTAssertNil(event)
        XCTAssertEqual(descriptorCount, 0)
    }

    func testCancellationDuringSymlinkResolutionClosesTransientDescriptor() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        _ = try fixture.regularFile(named: "target")
        try fixture.symbolicLink(at: fixture.url.appendingPathComponent("link"), target: "target")
        let control = FileBrokerTestControl(pausingAt: [.afterSymlinkTargetRead])
        let capability = try RootCapability.open(selectedURL: fixture.url)
        let broker = try capability.makeFileBroker(limits: .defaults, testControl: control)
        let traversal = try await broker.makeTraversal()
        let next = Task {
            while let event = try await traversal.next() {
                if case let .candidate(candidate) = event,
                   candidate.logicalPath.escapedForDisplay().text == "link" {
                    return Optional<TraversalEvent>.some(event)
                }
            }
            return nil
        }
        await control.waitUntilReached(.afterSymlinkTargetRead)
        let suspendedCount = await broker.openTraversalDirectoryDescriptorCount()
        XCTAssertGreaterThan(suspendedCount, 1)

        await traversal.cancel()
        await control.resume(.afterSymlinkTargetRead)

        let event = try await next.value
        let descriptorCount = await broker.openTraversalDirectoryDescriptorCount()
        XCTAssertNil(event)
        XCTAssertEqual(descriptorCount, 0)
    }

    func testTaskCancellationAtBrokerProofReplayRejectsAndCloses() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        _ = try fixture.regularFile(named: "target", contents: Data("value".utf8))
        try fixture.symbolicLink(at: fixture.url.appendingPathComponent("link"), target: "target")
        let control = FileBrokerTestControl(pausingAt: [.afterProofReplay])
        let capability = try RootCapability.open(selectedURL: fixture.url)
        let broker = try capability.makeFileBroker(limits: .defaults, testControl: control)
        let traversal = try await broker.makeTraversal()
        var link: FileCandidate?
        while let event = try await traversal.next() {
            if case let .candidate(candidate) = event,
               candidate.logicalPath.escapedForDisplay().text == "link" {
                link = candidate
            }
        }
        guard let link else { return XCTFail("Expected link candidate") }

        let validation = Task { await broker.revalidate(link) }
        await control.waitUntilReached(.afterProofReplay)
        validation.cancel()
        await control.resume(.afterProofReplay)

        let result = await validation.value
        let descriptorCount = await broker.openTraversalDirectoryDescriptorCount()
        XCTAssertEqual(result, .rejected(.cancelled))
        XCTAssertEqual(descriptorCount, 0)
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

    private func assertExplicitCancellation(
        point: FileBrokerTestPoint,
        setup: (TemporaryProjectFixture) throws -> Void
    ) async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        try setup(fixture)
        let control = FileBrokerTestControl(pausingAt: [point])
        let capability = try RootCapability.open(selectedURL: fixture.url)
        let broker = try capability.makeFileBroker(limits: .defaults, testControl: control)
        let traversal = try await broker.makeTraversal()
        let next = Task {
            while try await traversal.next() != nil {}
            return Optional<TraversalEvent>.none
        }
        await control.waitUntilReached(point)

        await traversal.cancel()
        await control.resume(point)

        let event = try await next.value
        let descriptorCount = await broker.openTraversalDirectoryDescriptorCount()
        XCTAssertNil(event)
        XCTAssertEqual(descriptorCount, 0)
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
