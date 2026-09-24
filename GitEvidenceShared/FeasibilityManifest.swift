import Foundation

public enum FeasibilityManifestSchema {
    public static let currentVersion: UInt32 = 1
}

public enum GitRunnerVersion {
    public static let current: String = GitRunnerInvocation.version
    public static let placeholder: String = "0.0.0-not-implemented"
}

public enum FeasibilityScenarioID: String, Codable, CaseIterable, Sendable {
    case descriptorTransfer = "descriptor_transfer"
    case sandboxDenial = "sandbox_denial"
    case gitTransition = "git_transition"
    case cleanup = "cleanup"
    case lsFilesOperation = "ls_files_operation"
    case lsTreeOperation = "ls_tree_operation"
    case catFileBatchOperation = "cat_file_batch_operation"
}

public enum FeasibilityScenarioStatus: String, Codable, Sendable {
    case passed
    case failed
    case notImplemented = "not_implemented"
}

public enum FeasibilityOverallStatus: String, Codable, Sendable {
    case passed
    case failed
}

public struct FeasibilityScenarioResult: Codable, Sendable, Equatable {
    public let id: FeasibilityScenarioID
    public let status: FeasibilityScenarioStatus
    public let passed: Bool
    public let sandboxLogPath: String?
    public let filesystemSnapshotPath: String?
    public let details: [String: String]

    public init(
        id: FeasibilityScenarioID,
        status: FeasibilityScenarioStatus,
        passed: Bool,
        sandboxLogPath: String? = nil,
        filesystemSnapshotPath: String? = nil,
        details: [String: String] = [:]
    ) {
        self.id = id
        self.status = status
        self.passed = passed
        self.sandboxLogPath = sandboxLogPath
        self.filesystemSnapshotPath = filesystemSnapshotPath
        self.details = details
    }
}

/// Code-signing facts for one signed product the harness exercised. Spec
/// §10.5 requires the allowlist tuple to record the app and runner
/// signatures, and to accept only production-signed evidence.
public struct FeasibilityCodeSignature: Codable, Sendable, Equatable {
    public let identifier: String
    public let teamIdentifier: String
    /// Hex code-directory hash (kSecCodeInfoUnique).
    public let cdhash: String
    /// Leaf certificate summary, e.g. "Developer ID Application: …".
    public let leafAuthority: String
    /// Signed with a Developer ID Application certificate.
    public let developerIDSigned: Bool
    /// Satisfies the "notarized" code requirement.
    public let notarized: Bool

    public init(
        identifier: String,
        teamIdentifier: String,
        cdhash: String,
        leafAuthority: String,
        developerIDSigned: Bool,
        notarized: Bool
    ) {
        self.identifier = identifier
        self.teamIdentifier = teamIdentifier
        self.cdhash = cdhash
        self.leafAuthority = leafAuthority
        self.developerIDSigned = developerIDSigned
        self.notarized = notarized
    }

    public var isProductionSigned: Bool {
        developerIDSigned && notarized
    }
}

public struct FeasibilityManifest: Codable, Sendable, Equatable {
    public let schemaVersion: UInt32
    public let pearcleanerVersion: String
    public let harnessVersion: String
    public let runnerVersion: String
    public let appleGitVersion: String
    public let osBuildFamily: String
    public let architecture: String
    public let testTimestamp: Date
    public let overallStatus: FeasibilityOverallStatus
    public let scenarios: [FeasibilityScenarioResult]
    /// Optional so manifests archived before signatures were recorded still
    /// decode; such manifests can never count as production-signed.
    public let harnessSignature: FeasibilityCodeSignature?
    public let serviceSignature: FeasibilityCodeSignature?
    public let runnerSignature: FeasibilityCodeSignature?

    public init(
        schemaVersion: UInt32 = FeasibilityManifestSchema.currentVersion,
        pearcleanerVersion: String,
        harnessVersion: String,
        runnerVersion: String,
        appleGitVersion: String,
        osBuildFamily: String,
        architecture: String,
        testTimestamp: Date,
        overallStatus: FeasibilityOverallStatus,
        scenarios: [FeasibilityScenarioResult],
        harnessSignature: FeasibilityCodeSignature? = nil,
        serviceSignature: FeasibilityCodeSignature? = nil,
        runnerSignature: FeasibilityCodeSignature? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.pearcleanerVersion = pearcleanerVersion
        self.harnessVersion = harnessVersion
        self.runnerVersion = runnerVersion
        self.appleGitVersion = appleGitVersion
        self.osBuildFamily = osBuildFamily
        self.architecture = architecture
        self.testTimestamp = testTimestamp
        self.overallStatus = overallStatus
        self.scenarios = scenarios
        self.harnessSignature = harnessSignature
        self.serviceSignature = serviceSignature
        self.runnerSignature = runnerSignature
    }

    /// True only when every signed product in the run was Developer ID
    /// signed and notarized, as spec §10.5 requires of gate evidence.
    public var isProductionSigned: Bool {
        [harnessSignature, serviceSignature, runnerSignature].allSatisfy { $0?.isProductionSigned == true }
    }

    public static func overallStatus(for scenarios: [FeasibilityScenarioResult]) -> FeasibilityOverallStatus {
        scenarios.allSatisfy(\.passed) ? .passed : .failed
    }

    public func encodedJSON(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    @discardableResult
    public static func write(_ manifest: FeasibilityManifest, to directory: URL) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let manifestURL = directory.appendingPathComponent("manifest.json", isDirectory: false)
        let data = try manifest.encodedJSON()
        try data.write(to: manifestURL, options: .atomic)

        let scenariosDirectory = directory.appendingPathComponent("scenarios", isDirectory: true)
        try fileManager.createDirectory(at: scenariosDirectory, withIntermediateDirectories: true)

        let scenarioEncoder = JSONEncoder()
        scenarioEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        scenarioEncoder.dateEncodingStrategy = .iso8601

        for scenario in manifest.scenarios {
            let scenarioURL = scenariosDirectory.appendingPathComponent("\(scenario.id.rawValue).json", isDirectory: false)
            let scenarioData = try scenarioEncoder.encode(scenario)
            try scenarioData.write(to: scenarioURL, options: .atomic)
        }

        return manifestURL
    }
}
