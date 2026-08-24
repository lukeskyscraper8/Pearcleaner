import Foundation

public enum GitFeasibilityUnavailableReason: String, Sendable, Equatable {
    case gitTupleNotAllowlisted = "git_tuple_not_allowlisted"
}

public struct GitFeasibilityTupleMetadata: Sendable, Equatable {
    public let osBuildFamily: String
    public let architecture: String
    public let pearcleanerVersion: String
    public let runnerVersion: String
    public let appleGitVersion: String
    public let harnessVersion: String
    public let testTimestamp: Date

    public init(
        osBuildFamily: String,
        architecture: String,
        pearcleanerVersion: String,
        runnerVersion: String,
        appleGitVersion: String,
        harnessVersion: String,
        testTimestamp: Date
    ) {
        self.osBuildFamily = osBuildFamily
        self.architecture = architecture
        self.pearcleanerVersion = pearcleanerVersion
        self.runnerVersion = runnerVersion
        self.appleGitVersion = appleGitVersion
        self.harnessVersion = harnessVersion
        self.testTimestamp = testTimestamp
    }
}

public enum GitFeasibilityAvailability: Sendable, Equatable {
    case enabled(GitFeasibilityTupleMetadata)
    case unavailable(reason: GitFeasibilityUnavailableReason)
}

public struct GitFeasibilitySnapshot: Sendable, Equatable {
    public let availability: GitFeasibilityAvailability

    public init(availability: GitFeasibilityAvailability) {
        self.availability = availability
    }

    public var isEnabled: Bool {
        if case .enabled = availability {
            return true
        }
        return false
    }

    public static func unavailable(
        reason: GitFeasibilityUnavailableReason = .gitTupleNotAllowlisted
    ) -> GitFeasibilitySnapshot {
        GitFeasibilitySnapshot(availability: .unavailable(reason: reason))
    }
}

public enum GitFeasibilityTupleNaming {
    public static func directoryName(osBuildFamily: String, architecture: String) -> String {
        "\(osBuildFamily)-\(architecture)"
    }
}
