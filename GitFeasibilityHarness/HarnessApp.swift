import Foundation
import GitEvidenceShared

struct FeasibilitySystemMetadata: Sendable {
    let pearcleanerVersion: String
    let harnessVersion: String
    let runnerVersion: String
    let appleGitVersion: String
    let osBuildFamily: String
    let architecture: String
    let testTimestamp: Date

    static func collect(runnerVersion: String = GitRunnerVersion.current) -> FeasibilitySystemMetadata {
        FeasibilitySystemMetadata(
            pearcleanerVersion: Bundle.main.pearcleanerMarketingVersion,
            harnessVersion: Bundle.main.harnessMarketingVersion,
            runnerVersion: runnerVersion,
            appleGitVersion: Self.appleGitVersion(),
            osBuildFamily: Self.osBuildFamily(),
            architecture: Self.machineArchitecture(),
            testTimestamp: Date()
        )
    }

    private static func appleGitVersion() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--version"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return "unavailable: \(error.localizedDescription)"
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return "unavailable: exit \(process.terminationStatus)"
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let version = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return version?.isEmpty == false ? version! : "unavailable: empty output"
    }

    private static func osBuildFamily() -> String {
        let productVersion = ProcessInfo.processInfo.operatingSystemVersion
        let versionString = "\(productVersion.majorVersion).\(productVersion.minorVersion).\(productVersion.patchVersion)"
        let buildNumber = Self.sysctlString(name: "kern.osversion") ?? "unknown-build"
        return "macOS-\(versionString)-\(buildNumber)"
    }

    private static func machineArchitecture() -> String {
        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else {
            return "unknown"
        }

        return withUnsafeBytes(of: &systemInfo.machine) { rawBuffer in
            rawBuffer.bindMemory(to: CChar.self).baseAddress.map { String(cString: $0) } ?? "unknown"
        }
    }

    private static func sysctlString(name: String) -> String? {
        var size: size_t = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }

        var buffer = [CChar](repeating: 0, count: Int(size))
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }

        return String(cString: buffer)
    }
}

struct HarnessRunner: Sendable {
    private let scenarios: [any FeasibilityScenario] = [
        DescriptorTransferScenario(),
        LsFilesOperationScenario(),
        LsTreeOperationScenario(),
        CatFileBatchOperationScenario(),
        SandboxDenialScenario(),
        GitTransitionScenario(),
        CleanupScenario(),
    ]

    func run() -> Int32 {
        do {
            let outputDirectory = try resolveOutputDirectory()
            let metadata = FeasibilitySystemMetadata.collect()
            let scenarioResults = try runScenarios(outputDirectory: outputDirectory)
            let manifest = makeManifest(metadata: metadata, scenarioResults: scenarioResults)

            let manifestURL = try FeasibilityManifest.write(manifest, to: outputDirectory)
            fputs("Wrote feasibility manifest to \(manifestURL.path)\n", stdout)

            let failedCount = scenarioResults.filter { !$0.passed }.count
            if failedCount > 0 {
                fputs("Git feasibility harness completed with \(failedCount) failing scenario(s).\n", stderr)
                return 1
            }

            fputs("Git feasibility harness completed successfully.\n", stdout)
            return 0
        } catch {
            fputs("Git feasibility harness failed: \(error.localizedDescription)\n", stderr)
            return 2
        }
    }

    private func resolveOutputDirectory() throws -> URL {
        if let environmentPath = ProcessInfo.processInfo.environment["GIT_FEASIBILITY_OUTPUT"],
           !environmentPath.isEmpty {
            return URL(fileURLWithPath: environmentPath, isDirectory: true)
        }

        let arguments = CommandLine.arguments.dropFirst()
        if let firstArgument = arguments.first, !firstArgument.isEmpty {
            return URL(fileURLWithPath: firstArgument, isDirectory: true)
        }

        throw HarnessError.missingOutputDirectory
    }

    private func runScenarios(outputDirectory: URL) throws -> [FeasibilityScenarioResult] {
        try scenarios.map { scenario in
            try scenario.run(outputDirectory: outputDirectory)
        }
    }

    private func makeManifest(
        metadata: FeasibilitySystemMetadata,
        scenarioResults: [FeasibilityScenarioResult]
    ) -> FeasibilityManifest {
        FeasibilityManifest(
            pearcleanerVersion: metadata.pearcleanerVersion,
            harnessVersion: metadata.harnessVersion,
            runnerVersion: metadata.runnerVersion,
            appleGitVersion: metadata.appleGitVersion,
            osBuildFamily: metadata.osBuildFamily,
            architecture: metadata.architecture,
            testTimestamp: metadata.testTimestamp,
            overallStatus: FeasibilityManifest.overallStatus(for: scenarioResults),
            scenarios: scenarioResults
        )
    }
}

enum HarnessError: Error, Sendable {
    case missingOutputDirectory
}

private extension Bundle {
    var pearcleanerMarketingVersion: String {
        stringInfoPlistValue(for: "CFBundleShortVersionString") ?? "unknown"
    }

    var harnessMarketingVersion: String {
        pearcleanerMarketingVersion
    }

    func stringInfoPlistValue(for key: String) -> String? {
        object(forInfoDictionaryKey: key) as? String
    }
}

@main
enum HarnessApp {
    static func main() {
        let exitCode = HarnessRunner().run()
        exit(exitCode)
    }
}
