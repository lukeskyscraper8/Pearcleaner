import Foundation
import XCTest
@testable import ProjectScannerCore

final class GitIgnoreClassifierGoldenTests: XCTestCase {
    func testMatchesSystemGitForCommonPatterns() throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }

        try initializeRepository(in: fixture.url)
        _ = try fixture.regularFile(named: ".gitignore", contents: Data("*.log\nbuild/\n!important.log\n".utf8))
        _ = try fixture.regularFile(named: "app.log", contents: Data("secret".utf8))
        _ = try fixture.regularFile(named: "important.log", contents: Data("secret".utf8))
        _ = try fixture.directory(named: "build")
        _ = try fixture.regularFile(named: "build/output.txt", contents: Data("artifact".utf8))
        _ = try fixture.regularFile(named: "keep.txt", contents: Data("visible".utf8))

        let paths = [
            "app.log",
            "important.log",
            "build/output.txt",
            "keep.txt",
            ".gitignore",
        ]

        let classifier = try buildClassifier(for: fixture.url)
        for path in paths {
            let verified = try verifiedPath(path)
            let expected = try systemGitIgnores(path: path, repositoryRoot: fixture.url)
            XCTAssertEqual(
                classifier.isIgnored(verified),
                expected,
                "Mismatch for \(path)"
            )
        }
    }

    func testUnsupportedPatternMakesClassifierUnavailable() throws {
        let outcome = GitIgnoreClassifier.build(
            excludeFileContents: nil,
            gitignoreFiles: [(directory: nil, contents: Data("[[[invalid".utf8))]
        )
        XCTAssertEqual(outcome, .unsupported)
    }

    func testPatternLimitMakesClassifierUnavailable() {
        let patterns = (0..<Int(GitIgnoreClassifierLimits.maxPatterns + 1))
            .map { "file-\($0).txt\n" }
            .joined()
        let outcome = GitIgnoreClassifier.build(
            excludeFileContents: nil,
            gitignoreFiles: [(directory: nil, contents: Data(patterns.utf8))]
        )
        XCTAssertEqual(outcome, .unsupported)
    }

    private func buildClassifier(for root: URL) throws -> GitIgnoreClassifier {
        let gitignoreURL = root.appendingPathComponent(".gitignore")
        let excludeURL = root.appendingPathComponent(".git/info/exclude")
        let gitignoreContents = (try? Data(contentsOf: gitignoreURL)) ?? Data()
        let excludeContents = (try? Data(contentsOf: excludeURL)) ?? Data()
        switch GitIgnoreClassifier.build(
            excludeFileContents: excludeContents.isEmpty ? nil : excludeContents,
            gitignoreFiles: gitignoreContents.isEmpty
                ? []
                : [(directory: nil, contents: gitignoreContents)]
        ) {
        case let .available(classifier):
            return classifier
        case .unsupported:
            throw XCTSkip("Classifier unsupported for fixture")
        }
    }

    private func verifiedPath(_ path: String) throws -> VerifiedRelativePath {
        if path.isEmpty {
            return try VerifiedRelativePath(components: [
                try VerifiedPathComponent(bytes: Data(".".utf8)),
            ])
        }
        let components = try path.split(separator: "/").map {
            try VerifiedPathComponent(bytes: Data($0.utf8))
        }
        return try VerifiedRelativePath(components: components)
    }

    private func systemGitIgnores(path: String, repositoryRoot: URL) throws -> Bool {
        let process = Process()
        process.currentDirectoryURL = repositoryRoot
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-c", "core.excludesFile=",
            "check-ignore", "-q", "--no-index", path,
        ]
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "LANG": "C",
            "LC_ALL": "C",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_SYSTEM": "/dev/null",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        switch process.terminationStatus {
        case 0: return true
        case 1: return false
        default:
            throw CocoaError(.fileReadUnknown)
        }
    }

    private func initializeRepository(in root: URL) throws {
        let process = Process()
        process.currentDirectoryURL = root
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init", "-q"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
