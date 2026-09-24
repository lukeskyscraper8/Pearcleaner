import Foundation

public enum GitEvidenceServiceIdentity {
    public static let serviceBundleIdentifier = "com.lukerow.Pearcleaner.GitEvidenceService"

    public static let serviceRequirement =
        #"identifier "com.lukerow.Pearcleaner.GitEvidenceService" and anchor apple generic and certificate leaf[subject.OU] = "68583N3MNF""#

    public static let pearcleanerClientRequirement =
        #"identifier "com.lukerow.Pearcleaner" and anchor apple generic and certificate leaf[subject.OU] = "68583N3MNF""#

    public static let harnessClientRequirement =
        #"identifier "com.lukerow.Pearcleaner.GitFeasibilityHarness" and anchor apple generic and certificate leaf[subject.OU] = "68583N3MNF""#

    public static let acceptedClientRequirements: [String] = [
        pearcleanerClientRequirement,
        harnessClientRequirement,
    ]

    /// One requirement accepting any allowlisted client, for
    /// `NSXPCConnection.setCodeSigningRequirement(_:)`.
    public static let acceptedClientRequirement: String =
        acceptedClientRequirements.map { "(\($0))" }.joined(separator: " or ")
}
