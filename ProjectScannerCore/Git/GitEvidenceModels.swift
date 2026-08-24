import Foundation

public enum GitObjectHashAlgorithm: String, Sendable, Equatable {
    case sha1
    case sha256
}

public struct GitObjectID: Sendable, Equatable, Hashable {
    public let algorithm: GitObjectHashAlgorithm
    public let hex: String

    public init?(algorithm: GitObjectHashAlgorithm, hex: String) {
        let expectedLength = algorithm == .sha1 ? 40 : 64
        guard hex.count == expectedLength,
              hex.allSatisfy(isLowerHexDigit) else {
            return nil
        }
        self.algorithm = algorithm
        self.hex = hex
    }
}

public enum GitPreflightRejectionReason: String, Sendable, Equatable {
    case noRepository = "no_repository"
    case externalGitDir = "external_gitdir"
    case externalCommonDir = "external_commondir"
    case objectAlternates = "object_alternates"
    case replacementReferences = "replacement_references"
    case promisorConfiguration = "promisor_configuration"
    case configurationInclude = "configuration_include"
    case unsafeOwnershipMarker = "unsafe_ownership_marker"
    case unsupportedExtension = "unsupported_extension"
    case malformedConfiguration = "malformed_configuration"
    case oversizeConfiguration = "oversize_configuration"
    case malformedHead = "malformed_head"
    case refChainLimit = "ref_chain_limit"
    case identityChangedDuringPreflight = "identity_changed_during_preflight"
    case descriptorBudgetExceeded = "descriptor_budget_exceeded"
    case unreadable = "unreadable"
    case mountBoundary = "mount_boundary"
}

public enum GitPreflightOutcome: Sendable, Equatable {
    case accepted(GitRepositoryContext)
    case rejected(GitPreflightRejectionReason)

    public var coverageReason: CoverageReasonCode {
        switch self {
        case .accepted: .unreadable
        case .rejected: .gitPreflightRejected
        }
    }
}

public struct GitRepositoryContext: Sendable, Equatable {
    public let worktreeRoot: VerifiedRelativePath?
    public let gitDir: VerifiedRelativePath
    public let commonDir: VerifiedRelativePath
    public let headObjectID: GitObjectID
    public let repositoryFormatVersion: Int
    public let objectHashAlgorithm: GitObjectHashAlgorithm
    public let manifest: GitMetadataDescriptorManifest

    public init(
        worktreeRoot: VerifiedRelativePath?,
        gitDir: VerifiedRelativePath,
        commonDir: VerifiedRelativePath,
        headObjectID: GitObjectID,
        repositoryFormatVersion: Int,
        objectHashAlgorithm: GitObjectHashAlgorithm,
        manifest: GitMetadataDescriptorManifest
    ) {
        self.worktreeRoot = worktreeRoot
        self.gitDir = gitDir
        self.commonDir = commonDir
        self.headObjectID = headObjectID
        self.repositoryFormatVersion = repositoryFormatVersion
        self.objectHashAlgorithm = objectHashAlgorithm
        self.manifest = manifest
    }
}

public enum GitEvidenceOperation: String, Sendable, Equatable, Codable {
    case listCachedPaths = "list_cached_paths"
    case listHeadTreePaths = "list_head_tree_paths"
    case catFileBatch = "cat_file_batch"
}

enum GitPreflightLimits {
    static let maxConfigBytes: UInt64 = 256 * 1_024
    static let maxHeadBytes: UInt64 = 512
    static let maxRefFileBytes: UInt64 = 256
    static let maxPointerFileBytes: UInt64 = 4_096
    static let maxRefChainDepth: UInt32 = 8
}

private func isLowerHexDigit(_ character: Character) -> Bool {
    guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
        return false
    }
    switch scalar.value {
    case 48...57, 97...102: return true
    default: return false
    }
}
