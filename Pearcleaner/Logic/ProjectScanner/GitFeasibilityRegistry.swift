import Foundation
import GitEvidenceShared
import ProjectScannerCore

struct GitFeasibilityHostMetadata: Sendable, Equatable {
    let osBuildFamily: String
    let architecture: String
    let pearcleanerVersion: String
    let runnerVersion: String
    let appleGitVersion: String
}

protocol GitFeasibilityHostProbing: Sendable {
    func currentHostMetadata() -> GitFeasibilityHostMetadata
}

struct GitFeasibilityRegistry: GitFeasibilityProviding, Sendable {
    private let evidenceRoot: URL
    private let hostProbe: any GitFeasibilityHostProbing

    init(
        evidenceRoot: URL,
        hostProbe: any GitFeasibilityHostProbing
    ) {
        self.evidenceRoot = evidenceRoot
        self.hostProbe = hostProbe
    }

    static func production(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> GitFeasibilityRegistry {
        GitFeasibilityRegistry(
            evidenceRoot: defaultEvidenceRoot(bundle: bundle, fileManager: fileManager),
            hostProbe: SystemGitFeasibilityHostProbe(bundle: bundle)
        )
    }

    func currentSnapshot() -> GitFeasibilitySnapshot {
        let host = hostProbe.currentHostMetadata()
        let tupleDirectory = evidenceRoot.appendingPathComponent(
            GitFeasibilityTupleNaming.directoryName(
                osBuildFamily: host.osBuildFamily,
                architecture: host.architecture
            ),
            isDirectory: true
        )
        let manifestURL = tupleDirectory.appendingPathComponent("manifest.json", isDirectory: false)

        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return .unavailable()
        }

        let manifest: FeasibilityManifest
        do {
            let data = try Data(contentsOf: manifestURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            manifest = try decoder.decode(FeasibilityManifest.self, from: data)
        } catch {
            return .unavailable()
        }

        guard manifest.overallStatus == .passed else {
            return .unavailable()
        }

        guard manifestMatchesHost(manifest, host: host) else {
            return .unavailable()
        }

        return GitFeasibilitySnapshot(
            availability: .enabled(
                GitFeasibilityTupleMetadata(
                    osBuildFamily: manifest.osBuildFamily,
                    architecture: manifest.architecture,
                    pearcleanerVersion: manifest.pearcleanerVersion,
                    runnerVersion: manifest.runnerVersion,
                    appleGitVersion: manifest.appleGitVersion,
                    harnessVersion: manifest.harnessVersion,
                    testTimestamp: manifest.testTimestamp
                )
            )
        )
    }

    private func manifestMatchesHost(_ manifest: FeasibilityManifest, host: GitFeasibilityHostMetadata) -> Bool {
        manifest.osBuildFamily == host.osBuildFamily
            && manifest.architecture == host.architecture
            && manifest.pearcleanerVersion == host.pearcleanerVersion
            && manifest.runnerVersion == host.runnerVersion
            && manifest.appleGitVersion == host.appleGitVersion
    }

    private static func defaultEvidenceRoot(bundle: Bundle, fileManager: FileManager) -> URL {
        if let bundled = bundle.url(forResource: "git-feasibility", withExtension: nil) {
            return bundled
        }

        if let resourceRoot = bundle.resourceURL {
            let candidate = resourceRoot.appendingPathComponent("git-feasibility", isDirectory: true)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        let checkoutEvidence = checkedInEvidenceRoot()
        if fileManager.fileExists(atPath: checkoutEvidence.path) {
            return checkoutEvidence
        }

        return resourceRootFallback(bundle: bundle)
    }

    private static func checkedInEvidenceRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/superpowers/evidence/git-feasibility", isDirectory: true)
    }

    private static func resourceRootFallback(bundle: Bundle) -> URL {
        bundle.resourceURL?
            .appendingPathComponent("git-feasibility", isDirectory: true)
            ?? URL(fileURLWithPath: "/dev/null/git-feasibility", isDirectory: true)
    }
}

struct SystemGitFeasibilityHostProbe: GitFeasibilityHostProbing, Sendable {
    private let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    func currentHostMetadata() -> GitFeasibilityHostMetadata {
        GitFeasibilityHostMetadata(
            osBuildFamily: Self.osBuildFamily(),
            architecture: Self.machineArchitecture(),
            pearcleanerVersion: bundle.pearcleanerMarketingVersion,
            runnerVersion: GitRunnerVersion.placeholder,
            appleGitVersion: Self.appleGitVersion()
        )
    }

    private static func appleGitVersion() -> String {
        if let override = ProcessInfo.processInfo.environment["GIT_FEASIBILITY_APPLE_GIT_VERSION"],
           !override.isEmpty {
            return override
        }

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
        let buildNumber = sysctlString(name: "kern.osversion") ?? "unknown-build"
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

private extension Bundle {
    var pearcleanerMarketingVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }
}
