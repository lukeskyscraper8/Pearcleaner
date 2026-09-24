import Darwin
import Foundation
import GitEvidenceShared

enum GitTransitionScenarioSupport {
    static func repositoryRootURL(bundle: Bundle = .main) throws -> URL {
        _ = bundle
        return try createInlineMinimalRepository()
    }

    static func createInlineMinimalRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-transition-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("fixture tracked\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))

        let process = Process()
        process.currentDirectoryURL = root
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init", "-q"]
        process.environment = [
            "HOME": root.appendingPathComponent(".home").path,
            "TMPDIR": root.appendingPathComponent(".tmp").path,
            "PATH": "/usr/bin:/bin",
            "LANG": "C",
            "LC_ALL": "C",
        ]
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".home"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".tmp"),
            withIntermediateDirectories: true
        )
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FeasibilityScenarioFailure.scenarioFailed(
                .gitTransition,
                reason: "unable to initialize inline minimal repository"
            )
        }

        let addProcess = Process()
        addProcess.currentDirectoryURL = root
        addProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        addProcess.arguments = ["add", "tracked.txt"]
        addProcess.environment = process.environment
        try addProcess.run()
        addProcess.waitUntilExit()
        guard addProcess.terminationStatus == 0 else {
            throw FeasibilityScenarioFailure.scenarioFailed(
                .gitTransition,
                reason: "unable to stage tracked file in inline minimal repository"
            )
        }

        return root
    }

    static func openReadOnlyDescriptor(for url: URL) throws -> Int32 {
        let path = url.path
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw FeasibilityScenarioFailure.scenarioFailed(
                .gitTransition,
                reason: "unable to open \(path): \(String(cString: strerror(errno)))"
            )
        }
        return descriptor
    }

    static func runnerSandboxEnforcementExpected(at runnerURL: URL) -> Bool {
        if sandboxEntitlementPresent(at: runnerURL) {
            return true
        }

        return productionSignedBinary(at: runnerURL)
    }

    private static func sandboxEntitlementPresent(at runnerURL: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-d", "--entitlements", ":-", runnerURL.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return false
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return false
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            return false
        }

        return (plist["com.apple.security.app-sandbox"] as? Bool) == true
    }

    private static func productionSignedBinary(at runnerURL: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dv", "--verbose=2", runnerURL.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return false
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return false
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        if output.contains("Signature=adhoc") || output.contains("code object is not signed at all") {
            return false
        }

        return output.contains("Authority=Developer ID Application")
            || output.contains("Authority=Apple Development")
    }
}
