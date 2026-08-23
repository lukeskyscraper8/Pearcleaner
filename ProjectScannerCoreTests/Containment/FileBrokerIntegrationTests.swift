import Darwin
import Foundation
import XCTest
@testable import ProjectScannerCore

final class FileBrokerIntegrationTests: XCTestCase {
    func testEnumeratesNestedRegularFilesIncludingHiddenFiles() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let nested = try fixture.directory(named: "nested")
        _ = try fixture.regularFile(named: ".hidden", contents: Data("hidden".utf8))
        XCTAssertTrue(FileManager.default.createFile(
            atPath: nested.appendingPathComponent("child.txt").path,
            contents: Data("child".utf8)
        ))

        let events = try await traverse(fixture.url)

        XCTAssertEqual(candidatePaths(in: events), [".hidden", "nested/child.txt"])
    }

    func testRelativeFileSymlinkInsideRootProducesCandidate() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        _ = try fixture.regularFile(named: "target", contents: Data("value".utf8))
        try fixture.symbolicLink(at: fixture.url.appendingPathComponent("link"), target: "target")

        let events = try await traverse(fixture.url)

        XCTAssertTrue(candidatePaths(in: events).contains("link"))
    }

    func testRelativeDirectorySymlinkInsideRootCanBeTraversed() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let directory = try fixture.directory(named: "real")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: directory.appendingPathComponent("child").path,
            contents: Data("value".utf8)
        ))
        try fixture.symbolicLink(at: fixture.url.appendingPathComponent("alias"), target: "real")

        let events = try await traverse(fixture.url)

        XCTAssertTrue(candidatePaths(in: events).contains("alias/child"))
    }

    func testDotDotInLinkTargetIsAcceptedOnlyWhileStackStaysInRoot() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let first = try fixture.directory(named: "first")
        let second = try fixture.directory(named: "second")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: second.appendingPathComponent("target").path,
            contents: Data("inside".utf8)
        ))
        try fixture.symbolicLink(
            at: first.appendingPathComponent("inside-link"),
            target: "../second/target"
        )
        try fixture.symbolicLink(
            at: fixture.url.appendingPathComponent("escape-link"),
            target: "../\(fixture.outsideCanaryURL.lastPathComponent)"
        )

        let events = try await traverse(fixture.url)

        XCTAssertTrue(candidatePaths(in: events).contains("first/inside-link"))
        XCTAssertTrue(skips(in: events).contains {
            path(of: $0.0) == "escape-link" && $0.1 == .externalBoundary
        })
    }

    func testAbsoluteAndRelativeExternalLinksAreSkipped() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        try fixture.symbolicLink(
            at: fixture.url.appendingPathComponent("absolute"),
            target: fixture.outsideCanaryURL.path
        )
        try fixture.symbolicLink(
            at: fixture.url.appendingPathComponent("relative"),
            target: "../\(fixture.outsideCanaryURL.lastPathComponent)"
        )

        let events = try await traverse(fixture.url)

        XCTAssertEqual(
            skips(in: events).filter { $0.1 == .externalBoundary }.compactMap { path(of: $0.0) }.sorted(),
            ["absolute", "relative"]
        )
    }

    func testExactlySixteenLinkHopsAreAcceptedAndSeventeenAreSkipped() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        _ = try fixture.regularFile(named: "target")
        var previous = "target"
        for hop in 1...17 {
            let name = "link-\(hop)"
            try fixture.symbolicLink(at: fixture.url.appendingPathComponent(name), target: previous)
            previous = name
        }

        let events = try await traverse(fixture.url)

        XCTAssertTrue(candidatePaths(in: events).contains("link-16"))
        XCTAssertTrue(skips(in: events).contains {
            path(of: $0.0) == "link-17" && $0.1 == .linkHopLimit
        })
    }

    func testFourThousandNinetySixByteLinkTargetIsAcceptedButTruncationIsRejected() async throws {
        XCTAssertNil(FileBrokerPlatform.linkTargetLengthRejection(byteCount: 4_096))
        XCTAssertEqual(
            FileBrokerPlatform.linkTargetLengthRejection(byteCount: 4_097),
            .pathTooLong
        )
    }

    func testSymlinkCycleIsSkipped() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let directory = try fixture.directory(named: "directory")
        try fixture.symbolicLink(at: directory.appendingPathComponent("cycle"), target: "../directory")
        try fixture.symbolicLink(at: fixture.url.appendingPathComponent("self-cycle"), target: ".")

        let events = try await traverse(fixture.url)

        XCTAssertTrue(skips(in: events).contains {
            path(of: $0.0) == "directory/cycle" && $0.1 == .symlinkCycle
        })
        XCTAssertTrue(skips(in: events).contains {
            path(of: $0.0) == "self-cycle" && $0.1 == .symlinkCycle
        })
    }

    func testFinderAliasBytesAreTreatedAsARegularFile() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        _ = try fixture.regularFile(
            named: "Finder alias",
            contents: Data("book\0mark-alias-bytes".utf8)
        )

        let events = try await traverse(fixture.url)

        XCTAssertTrue(candidatePaths(in: events).contains("Finder alias"))
    }

    func testInRootHardlinkPathsProduceSeparateCandidates() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let original = try fixture.regularFile(named: "original", contents: Data("same".utf8))
        let linked = fixture.url.appendingPathComponent("linked")
        try fixture.hardLink(from: original, to: linked)

        let events = try await traverse(fixture.url)
        let candidates = candidateEvents(in: events).filter {
            ["original", "linked"].contains($0.logicalPath.escapedForDisplay().text)
        }

        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(Set(candidates.map(\.identity.inode)).count, 1)
    }

    func testFIFOAndUnixSocketAreSkippedBeforeRead() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        try fixture.fifo(at: fixture.url.appendingPathComponent("fifo"))
        try fixture.unixSocket(at: fixture.url.appendingPathComponent("socket"))

        let events = try await traverse(fixture.url)

        XCTAssertEqual(
            skips(in: events).filter { $0.1 == .specialFile }.compactMap { path(of: $0.0) }.sorted(),
            ["fifo", "socket"]
        )
    }

    func testCharacterAndBlockDeviceModesClassifyAsSpecialWithoutOpening() throws {
        XCTAssertEqual(FileBrokerPlatform.classify(mode: mode_t(S_IFCHR)), .unsupported)
        XCTAssertEqual(FileBrokerPlatform.classify(mode: mode_t(S_IFBLK)), .unsupported)
    }

    func testDifferentDeviceIdentityMapsToMountBoundary() throws {
        XCTAssertEqual(
            FileBrokerPlatform.deviceBoundaryReason(rootDevice: 1, childDevice: 2),
            .mountBoundary
        )
        XCTAssertNil(FileBrokerPlatform.deviceBoundaryReason(rootDevice: 1, childDevice: 1))
    }

    func testDepthPathEntryAndDirectoryBudgetsStopWithoutSampling() async throws {
        let entryFixture = try TemporaryProjectFixture()
        defer { entryFixture.remove() }
        _ = try entryFixture.regularFile(named: "one")
        _ = try entryFixture.regularFile(named: "two")
        let entryLimits = try ScanLimitOverrides(directoryEntries: 1).applying(to: .defaults)
        let entryEvents = try await traverse(entryFixture.url, limits: entryLimits)
        XCTAssertEqual(candidateEvents(in: entryEvents).count, 1)
        XCTAssertEqual(skips(in: entryEvents).last?.1, .entryBudget)

        let directoryFixture = try TemporaryProjectFixture()
        defer { directoryFixture.remove() }
        _ = try directoryFixture.directory(named: "child")
        let directoryLimits = try ScanLimitOverrides(directories: 1).applying(to: .defaults)
        let directoryEvents = try await traverse(directoryFixture.url, limits: directoryLimits)
        XCTAssertEqual(skips(in: directoryEvents).last?.1, .directoryBudget)

        let depthFixture = try TemporaryProjectFixture()
        defer { depthFixture.remove() }
        var parent = depthFixture.url
        for index in 0..<129 {
            parent.appendPathComponent("d\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        }
        let depthEvents = try await traverse(depthFixture.url)
        XCTAssertTrue(skips(in: depthEvents).contains { $0.1 == .pathTooLong })
    }

    func testOverlongTotalPathProducesSafeSkipWithoutConstructingInvalidPath() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let components: [Data] = (0..<17).map { index in
            let name = String(repeating: Character(UnicodeScalar(97 + index)!), count: 255)
            return Data(name.utf8)
        }
        try fixture.rawDirectoryChain(components)

        let events = try await traverse(fixture.url)
        let overlong = skips(in: events).first { $0.1 == .pathTooLong }

        guard case let .unrepresentable(parent, escapedLeaf)? = overlong?.0 else {
            return XCTFail("Expected an unrepresentable bounded skip")
        }
        XCTAssertNotNil(parent)
        XCTAssertEqual(escapedLeaf?.text.count, 255)
    }

    func testMalformedEntryNameProducesSafeEscapedSkipLocation() async throws {
        let location = FileBrokerPlatform.safeLocation(parent: nil, rawLeaf: Data([0x61, 0, 0xFF]))

        guard case let .unrepresentable(parent, escapedLeaf) = location else {
            return XCTFail("Malformed bytes must not produce a verified path")
        }
        XCTAssertNil(parent)
        XCTAssertEqual(escapedLeaf?.text, "a\\u{0}\\xFF")
    }

    func testReadOnlyProjectTraversalNeedsNoWritePermission() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        _ = try fixture.regularFile(named: "read-only", contents: Data("value".utf8))
        guard chmod(fixture.url.path, S_IRUSR | S_IXUSR) == 0 else {
            return XCTFail("Could not make fixture read-only")
        }
        defer { _ = chmod(fixture.url.path, S_IRUSR | S_IWUSR | S_IXUSR) }

        let events = try await traverse(fixture.url)

        XCTAssertEqual(candidatePaths(in: events), ["read-only"])
    }

    func testTraversalDoesNotChangeProjectTreeSnapshot() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        let nested = try fixture.directory(named: "nested")
        _ = try fixture.regularFile(named: "root-file", contents: Data("root".utf8))
        XCTAssertTrue(FileManager.default.createFile(
            atPath: nested.appendingPathComponent("child").path,
            contents: Data("child".utf8)
        ))
        let before = try fixture.snapshot()

        _ = try await traverse(fixture.url)

        XCTAssertEqual(try fixture.snapshot(), before)
    }
}

func traverse(
    _ root: URL,
    limits: ScanLimits = .defaults
) async throws -> [TraversalEvent] {
    let capability = try RootCapability.open(selectedURL: root)
    let broker = try capability.makeFileBroker(limits: limits)
    let traversal = try await broker.makeTraversal()
    var events: [TraversalEvent] = []
    while let event = try await traversal.next() {
        events.append(event)
    }
    return events
}

func candidateEvents(in events: [TraversalEvent]) -> [FileCandidate] {
    events.compactMap {
        guard case let .candidate(candidate) = $0 else { return nil }
        return candidate
    }
}

func candidatePaths(in events: [TraversalEvent]) -> [String] {
    candidateEvents(in: events).map { $0.logicalPath.escapedForDisplay().text }.sorted()
}

func skips(
    in events: [TraversalEvent]
) -> [(SkippedTraversalLocation, CoverageReasonCode)] {
    events.compactMap {
        guard case let .skipped(location, reason) = $0 else { return nil }
        return (location, reason)
    }
}

func path(of location: SkippedTraversalLocation) -> String? {
    switch location {
    case let .verified(path):
        return path.escapedForDisplay().text
    case let .unrepresentable(parent, escapedLeaf):
        let prefix = parent?.escapedForDisplay().text
        return [prefix, escapedLeaf?.text].compactMap { $0 }.joined(separator: "/")
    }
}
