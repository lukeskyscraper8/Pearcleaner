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
        scenarios: [FeasibilityScenarioResult]
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
