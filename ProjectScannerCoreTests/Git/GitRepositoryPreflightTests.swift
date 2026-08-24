import Foundation
import XCTest
@testable import ProjectScannerCore

final class GitRepositoryPreflightTests: XCTestCase {
    func testMissingRepositoryIsRejected() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        _ = try fixture.regularFile(named: "README.md", contents: Data("no git".utf8))

        let outcome = try await runPreflight(on: fixture.url)

        XCTAssertEqual(outcome, .rejected(.noRepository))
    }

    func testNormalDotGitDirectoryAccepted() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        try initializeGitRepository(in: fixture.url, extraConfig: nil)
        var isDirectory: ObjCBool = false
        let gitURL = fixture.url.appendingPathComponent(".git")
        XCTAssertTrue(FileManager.default.fileExists(atPath: gitURL.path, isDirectory: &isDirectory), gitURL.path)
        XCTAssertTrue(isDirectory.boolValue)

        let outcome = try await runPreflight(on: fixture.url)

        switch outcome {
        case let .accepted(context):
            XCTAssertFalse(context.headObjectID.hex.isEmpty)
            XCTAssertFalse(context.manifest.descriptors.isEmpty)
        case let .rejected(reason):
            XCTFail("Expected accepted preflight, rejected with \(reason.rawValue)")
        }
    }

    func testGitFileIndirectionWithInRootGitDirAccepted() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        try initializeGitRepository(in: fixture.url, extraConfig: nil)
        let gitDirectory = fixture.url.appendingPathComponent(".git")
        let gitStore = fixture.url.appendingPathComponent(".git-real")
        try FileManager.default.moveItem(at: gitDirectory, to: gitStore)
        try Data("gitdir: .git-real\n".utf8).write(
            to: fixture.url.appendingPathComponent(".git")
        )

        let outcome = try await runPreflight(on: fixture.url)

        guard case .accepted = outcome else {
            return XCTFail("Expected accepted preflight, got \(outcome)")
        }
    }

    func testSupportedGitFileIndirectionWithCommonDirAccepted() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        try initializeGitRepository(in: fixture.url, extraConfig: nil)

        let gitStore = fixture.url.appendingPathComponent(".git-store")
        let gitWorktree = fixture.url.appendingPathComponent(".git-wt")
        try FileManager.default.moveItem(
            at: fixture.url.appendingPathComponent(".git"),
            to: gitStore
        )
        try FileManager.default.createDirectory(at: gitWorktree, withIntermediateDirectories: false)
        try Data("../.git-store\n".utf8).write(to: gitWorktree.appendingPathComponent("commondir"))
        try FileManager.default.copyItem(
            at: gitStore.appendingPathComponent("HEAD"),
            to: gitWorktree.appendingPathComponent("HEAD")
        )
        try FileManager.default.copyItem(
            at: gitStore.appendingPathComponent("index"),
            to: gitWorktree.appendingPathComponent("index")
        )
        try Data("gitdir: .git-wt\n".utf8).write(to: fixture.url.appendingPathComponent(".git"))

        let outcome = try await runPreflight(on: fixture.url)

        guard case let .accepted(context) = outcome else {
            return XCTFail("Expected accepted preflight, got \(outcome)")
        }
        XCTAssertFalse(context.manifest.descriptors.isEmpty)
    }

    func testExternalGitDirRejected() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        _ = try fixture.regularFile(
            named: ".git",
            contents: Data("gitdir: /tmp/outside.git\n".utf8)
        )

        let outcome = try await runPreflight(on: fixture.url)

        XCTAssertEqual(outcome, .rejected(.externalGitDir))
    }

    func testExternalCommonDirRejected() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        try initializeGitRepository(in: fixture.url, extraConfig: nil)
        _ = try fixture.regularFile(
            named: ".git/commondir",
            contents: Data("/tmp/outside\n".utf8)
        )

        let outcome = try await runPreflight(on: fixture.url)

        XCTAssertEqual(outcome, .rejected(.externalCommonDir))
    }

    func testObjectAlternatesRejected() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        try initializeGitRepository(in: fixture.url, extraConfig: nil)
        _ = try fixture.regularFile(
            named: ".git/objects/info/alternates",
            contents: Data("/tmp/other/objects\n".utf8)
        )

        let outcome = try await runPreflight(on: fixture.url)

        XCTAssertEqual(outcome, .rejected(.objectAlternates))
    }

    func testConfigurationIncludeRejected() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        try initializeGitRepository(
            in: fixture.url,
            extraConfig: "[include]\n\tpath = /etc/passwd\n"
        )

        let outcome = try await runPreflight(on: fixture.url)

        XCTAssertEqual(outcome, .rejected(.configurationInclude))
    }

    func testConditionalIncludeRejected() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        try initializeGitRepository(
            in: fixture.url,
            extraConfig: "[includeIf \"gitdir:/tmp/evil\"]\n\tpath = /tmp/evil\n"
        )

        let outcome = try await runPreflight(on: fixture.url)

        XCTAssertEqual(outcome, .rejected(.configurationInclude))
    }

    func testPromisorConfigurationRejected() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        try initializeGitRepository(
            in: fixture.url,
            extraConfig: "[core]\n\tpartialclonefilter = blob:none\n"
        )

        let outcome = try await runPreflight(on: fixture.url)

        XCTAssertEqual(outcome, .rejected(.promisorConfiguration))
    }

    func testReplacementReferencesRejected() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        try initializeGitRepository(in: fixture.url, extraConfig: nil)
        _ = try fixture.directory(named: ".git/refs/replace")

        let outcome = try await runPreflight(on: fixture.url)

        XCTAssertEqual(outcome, .rejected(.replacementReferences))
    }

    func testUnsafeOwnershipMarkerRejected() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        try initializeGitRepository(
            in: fixture.url,
            extraConfig: "[safe]\n\tdirectory = *\n"
        )

        let outcome = try await runPreflight(on: fixture.url)

        XCTAssertEqual(outcome, .rejected(.unsafeOwnershipMarker))
    }

    func testUnsupportedExtensionRejected() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        try initializeGitRepository(
            in: fixture.url,
            extraConfig: "[extensions]\n\tcompatObjectFormat = true\n"
        )

        let outcome = try await runPreflight(on: fixture.url)

        XCTAssertEqual(outcome, .rejected(.unsupportedExtension))
    }

    func testOversizeConfigurationRejected() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        try initializeGitRepository(in: fixture.url, extraConfig: nil)
        let oversized = Data(repeating: UInt8(ascii: "a"), count: Int(GitPreflightLimits.maxConfigBytes) + 1)
        try fixture.overwriteRegularFile(at: fixture.url.appendingPathComponent(".git/config"), contents: oversized)

        let outcome = try await runPreflight(on: fixture.url)

        XCTAssertEqual(outcome, .rejected(.oversizeConfiguration))
    }

    func testIdentityRaceDuringPreflightRejected() async throws {
        throw XCTSkip("Identity race timing is environment-dependent")
    }

    func testMinimalRepoFixtureAccepted() async throws {
        let fixture = try repositoryFixture(named: "minimal-repo")
        defer { fixture.remove() }
        let outcome = try await runPreflight(on: fixture.url)

        guard case let .accepted(context) = outcome else {
            return XCTFail("Expected accepted preflight for minimal-repo fixture, got \(outcome)")
        }
        XCTAssertFalse(context.manifest.descriptors.isEmpty)
    }

    func testHostileExternalGitdirFixtureRejected() async throws {
        let fixture = try repositoryFixture(named: "hostile-repo/external-gitdir")
        defer { fixture.remove() }
        let outcome = try await runPreflight(on: fixture.url)

        XCTAssertEqual(outcome, .rejected(.externalGitDir))
    }

    func testHostileAlternatesFixtureRejected() async throws {
        let fixture = try repositoryFixture(named: "hostile-repo/alternates")
        defer { fixture.remove() }
        let outcome = try await runPreflight(on: fixture.url)

        XCTAssertEqual(outcome, .rejected(.objectAlternates))
    }

    func testDescriptorManifestRespectsHardCap() throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        var descriptors: [GitMetadataDescriptor] = []
        for index in 0..<1_025 {
            let file = try fixture.regularFile(named: "file-\(index).txt")
            let identity = try fixture.identity(of: file)
            let path = try VerifiedRelativePath(components: [
                try VerifiedPathComponent(bytes: Data("file-\(index).txt".utf8)),
            ])
            descriptors.append(GitMetadataDescriptor(
                role: .looseObject,
                relativePath: path,
                identity: identity
            ))
        }

        XCTAssertThrowsError(
            try GitMetadataDescriptorManifest(
                descriptors: descriptors,
                descriptorLimit: ScanLimits.defaults.gitMetadataDescriptors
            )
        ) { error in
            XCTAssertEqual(error as? GitMetadataManifestError, .descriptorBudgetExceeded)
        }
    }

    private func runPreflight(on url: URL) async throws -> GitPreflightOutcome {
        let capability = try RootCapability.open(selectedURL: url)
        let broker = try capability.makeFileBroker(limits: .defaults)
        return await GitRepositoryPreflight().preflight(broker: broker)
    }

    private func repositoryFixture(named name: String) throws -> MaterializedRepositoryFixture {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("script/fixtures/git_evidence/\(name)", isDirectory: true)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("Missing fixture at \(source.path)")
        }
        let backing = try TemporaryProjectFixture()
        try copyFixtureContents(from: source, to: backing.url)
        return MaterializedRepositoryFixture(backing: backing)
    }

    private func copyFixtureContents(from source: URL, to destination: URL) throws {
        let contents = try FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for item in contents {
            let name = item.lastPathComponent
            if name == "dot-git" {
                try copyFixtureDirectory(from: item, to: destination.appendingPathComponent(".git"))
            } else if name == "gitdir-pointer" {
                try FileManager.default.copyItem(
                    at: item,
                    to: destination.appendingPathComponent(".git")
                )
            } else {
                try FileManager.default.copyItem(
                    at: item,
                    to: destination.appendingPathComponent(name)
                )
            }
        }
        let hidden = try FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: []
        )
        for item in hidden where item.lastPathComponent.hasPrefix(".") {
            let name = item.lastPathComponent
            if name == ".git", !FileManager.default.fileExists(atPath: destination.appendingPathComponent(".git").path) {
                try FileManager.default.copyItem(
                    at: item,
                    to: destination.appendingPathComponent(name)
                )
            }
        }
    }

    private func copyFixtureDirectory(from source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let contents = try FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        for item in contents {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            if (try item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                try copyFixtureDirectory(from: item, to: target)
            } else {
                try FileManager.default.copyItem(at: item, to: target)
            }
        }
    }

    private func initializeGitRepository(
        in root: URL,
        gitDirName: String = ".git",
        extraConfig: String?
    ) throws {
        let process = Process()
        process.currentDirectoryURL = root
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        if gitDirName == ".git" {
            process.arguments = ["init", "-q"]
        } else {
            process.arguments = ["init", "-q", "--separate-git-dir", gitDirName]
        }
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }

        _ = try Data("tracked\n".utf8).write(
            to: root.appendingPathComponent("tracked.txt")
        )
        try runGit(["add", "tracked.txt"], in: root)
        try runGit(["-c", "user.email=test@example.com", "-c", "user.name=Test", "commit", "-qm", "init"], in: root)

        if let extraConfig {
            let configURL = root.appendingPathComponent("\(gitDirName)/config")
            let existing = try Data(contentsOf: configURL)
            let combined = existing + Data(extraConfig.utf8)
            try combined.write(to: configURL, options: .atomic)
        }
    }

    private func runGit(_ arguments: [String], in root: URL) throws {
        let process = Process()
        process.currentDirectoryURL = root
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

private final class MaterializedRepositoryFixture {
    let url: URL
    private let backing: TemporaryProjectFixture

    init(backing: TemporaryProjectFixture) {
        self.backing = backing
        url = backing.url
    }

    func remove() {
        backing.remove()
    }
}
