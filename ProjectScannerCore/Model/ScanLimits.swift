public enum ScanLimitField: String, CaseIterable, Sendable {
    case generalFiles
    case secretFileBytes
    case lockfileBytes
    case manifestBytes
    case installedManifests
    case directories
    case directoryEntries
    case dependencyNodesPerLockfile
    case dependencyNodesPerSession
    case inputBytes
    case wallTimeMilliseconds
}

public enum ScanLimitError: Error, Equatable {
    case invalidValue(ScanLimitField)
    case exceedsHardCeiling(ScanLimitField)
}

public struct ScanLimits: Sendable, Equatable {
    public let generalFiles: UInt64
    public let secretFileBytes: UInt64
    public let lockfileBytes: UInt64
    public let manifestBytes: UInt64
    public let installedManifests: UInt64
    public let directories: UInt64
    public let directoryEntries: UInt64
    public let traversalDepth: UInt32
    public let relativePathBytes: UInt64
    public let structuredDataDepth: UInt32
    public let parsedScalarBytes: UInt64
    public let dependencyNodesPerLockfile: UInt64
    public let dependencyNodesPerSession: UInt64
    public let findingsPerFile: UInt64
    public let findingsPerSession: UInt64
    public let inputBytes: UInt64
    public let wallTimeMilliseconds: UInt64
    public let activeWorkers: UInt32
    public let activeProjectScans: UInt32
    public let gitMetadataDescriptors: UInt64
    public let gitDescriptorReserve: UInt64
    public let gitOperationMilliseconds: UInt64
    public let gitOutputBytes: UInt64
    public let retainedInputBytes: UInt64
    public let parserArenaBytes: UInt64
    public let findingModelBytes: UInt64
    public let rssSoftBytes: UInt64
    public let rssHardBytes: UInt64
    public let maximumLinkHops: UInt32
    public let progressIntervalMilliseconds: UInt64
    public let cancellationLatencyMilliseconds: UInt64

    fileprivate init(
        generalFiles: UInt64,
        secretFileBytes: UInt64,
        lockfileBytes: UInt64,
        manifestBytes: UInt64,
        installedManifests: UInt64,
        directories: UInt64,
        directoryEntries: UInt64,
        traversalDepth: UInt32,
        relativePathBytes: UInt64,
        structuredDataDepth: UInt32,
        parsedScalarBytes: UInt64,
        dependencyNodesPerLockfile: UInt64,
        dependencyNodesPerSession: UInt64,
        findingsPerFile: UInt64,
        findingsPerSession: UInt64,
        inputBytes: UInt64,
        wallTimeMilliseconds: UInt64,
        activeWorkers: UInt32,
        activeProjectScans: UInt32,
        gitMetadataDescriptors: UInt64,
        gitDescriptorReserve: UInt64,
        gitOperationMilliseconds: UInt64,
        gitOutputBytes: UInt64,
        retainedInputBytes: UInt64,
        parserArenaBytes: UInt64,
        findingModelBytes: UInt64,
        rssSoftBytes: UInt64,
        rssHardBytes: UInt64,
        maximumLinkHops: UInt32,
        progressIntervalMilliseconds: UInt64,
        cancellationLatencyMilliseconds: UInt64
    ) {
        self.generalFiles = generalFiles
        self.secretFileBytes = secretFileBytes
        self.lockfileBytes = lockfileBytes
        self.manifestBytes = manifestBytes
        self.installedManifests = installedManifests
        self.directories = directories
        self.directoryEntries = directoryEntries
        self.traversalDepth = traversalDepth
        self.relativePathBytes = relativePathBytes
        self.structuredDataDepth = structuredDataDepth
        self.parsedScalarBytes = parsedScalarBytes
        self.dependencyNodesPerLockfile = dependencyNodesPerLockfile
        self.dependencyNodesPerSession = dependencyNodesPerSession
        self.findingsPerFile = findingsPerFile
        self.findingsPerSession = findingsPerSession
        self.inputBytes = inputBytes
        self.wallTimeMilliseconds = wallTimeMilliseconds
        self.activeWorkers = activeWorkers
        self.activeProjectScans = activeProjectScans
        self.gitMetadataDescriptors = gitMetadataDescriptors
        self.gitDescriptorReserve = gitDescriptorReserve
        self.gitOperationMilliseconds = gitOperationMilliseconds
        self.gitOutputBytes = gitOutputBytes
        self.retainedInputBytes = retainedInputBytes
        self.parserArenaBytes = parserArenaBytes
        self.findingModelBytes = findingModelBytes
        self.rssSoftBytes = rssSoftBytes
        self.rssHardBytes = rssHardBytes
        self.maximumLinkHops = maximumLinkHops
        self.progressIntervalMilliseconds = progressIntervalMilliseconds
        self.cancellationLatencyMilliseconds = cancellationLatencyMilliseconds
    }
}

public extension ScanLimits {
    static let defaults = ScanLimits(
        generalFiles: 100_000,
        secretFileBytes: 5 * 1_024 * 1_024,
        lockfileBytes: 50 * 1_024 * 1_024,
        manifestBytes: 2 * 1_024 * 1_024,
        installedManifests: 50_000,
        directories: 50_000,
        directoryEntries: 250_000,
        traversalDepth: 128,
        relativePathBytes: 4_096,
        structuredDataDepth: 128,
        parsedScalarBytes: 1 * 1_024 * 1_024,
        dependencyNodesPerLockfile: 250_000,
        dependencyNodesPerSession: 500_000,
        findingsPerFile: 2_000,
        findingsPerSession: 10_000,
        inputBytes: 2 * 1_024 * 1_024 * 1_024,
        wallTimeMilliseconds: 5 * 60 * 1_000,
        activeWorkers: 4,
        activeProjectScans: 1,
        gitMetadataDescriptors: 1_024,
        gitDescriptorReserve: 128,
        gitOperationMilliseconds: 30_000,
        gitOutputBytes: 32 * 1_024 * 1_024,
        retainedInputBytes: 256 * 1_024 * 1_024,
        parserArenaBytes: 256 * 1_024 * 1_024,
        findingModelBytes: 128 * 1_024 * 1_024,
        rssSoftBytes: 512 * 1_024 * 1_024,
        rssHardBytes: 1_024 * 1_024 * 1_024,
        maximumLinkHops: 16,
        progressIntervalMilliseconds: 250,
        cancellationLatencyMilliseconds: 500
    )
}

extension ScanLimits {
    static let hardCeilings = ScanLimits(
        generalFiles: 500_000,
        secretFileBytes: 50 * 1_024 * 1_024,
        lockfileBytes: 100 * 1_024 * 1_024,
        manifestBytes: 4 * 1_024 * 1_024,
        installedManifests: 100_000,
        directories: 200_000,
        directoryEntries: 1_000_000,
        traversalDepth: defaults.traversalDepth,
        relativePathBytes: defaults.relativePathBytes,
        structuredDataDepth: defaults.structuredDataDepth,
        parsedScalarBytes: defaults.parsedScalarBytes,
        dependencyNodesPerLockfile: 1_000_000,
        dependencyNodesPerSession: 2_000_000,
        findingsPerFile: defaults.findingsPerFile,
        findingsPerSession: defaults.findingsPerSession,
        inputBytes: 8 * 1_024 * 1_024 * 1_024,
        wallTimeMilliseconds: 30 * 60 * 1_000,
        activeWorkers: defaults.activeWorkers,
        activeProjectScans: defaults.activeProjectScans,
        gitMetadataDescriptors: defaults.gitMetadataDescriptors,
        gitDescriptorReserve: defaults.gitDescriptorReserve,
        gitOperationMilliseconds: defaults.gitOperationMilliseconds,
        gitOutputBytes: defaults.gitOutputBytes,
        retainedInputBytes: defaults.retainedInputBytes,
        parserArenaBytes: defaults.parserArenaBytes,
        findingModelBytes: defaults.findingModelBytes,
        rssSoftBytes: defaults.rssSoftBytes,
        rssHardBytes: defaults.rssHardBytes,
        maximumLinkHops: defaults.maximumLinkHops,
        progressIntervalMilliseconds: defaults.progressIntervalMilliseconds,
        cancellationLatencyMilliseconds: defaults.cancellationLatencyMilliseconds
    )
}

public struct ScanLimitOverrides: Codable, Sendable, Equatable {
    public let generalFiles: UInt64?
    public let secretFileBytes: UInt64?
    public let lockfileBytes: UInt64?
    public let manifestBytes: UInt64?
    public let installedManifests: UInt64?
    public let directories: UInt64?
    public let directoryEntries: UInt64?
    public let dependencyNodesPerLockfile: UInt64?
    public let dependencyNodesPerSession: UInt64?
    public let inputBytes: UInt64?
    public let wallTimeMilliseconds: UInt64?

    public init(
        generalFiles: UInt64? = nil,
        secretFileBytes: UInt64? = nil,
        lockfileBytes: UInt64? = nil,
        manifestBytes: UInt64? = nil,
        installedManifests: UInt64? = nil,
        directories: UInt64? = nil,
        directoryEntries: UInt64? = nil,
        dependencyNodesPerLockfile: UInt64? = nil,
        dependencyNodesPerSession: UInt64? = nil,
        inputBytes: UInt64? = nil,
        wallTimeMilliseconds: UInt64? = nil
    ) {
        self.generalFiles = generalFiles
        self.secretFileBytes = secretFileBytes
        self.lockfileBytes = lockfileBytes
        self.manifestBytes = manifestBytes
        self.installedManifests = installedManifests
        self.directories = directories
        self.directoryEntries = directoryEntries
        self.dependencyNodesPerLockfile = dependencyNodesPerLockfile
        self.dependencyNodesPerSession = dependencyNodesPerSession
        self.inputBytes = inputBytes
        self.wallTimeMilliseconds = wallTimeMilliseconds
    }

    private enum CodingKeys: String, CaseIterable, CodingKey {
        case generalFiles
        case secretFileBytes
        case lockfileBytes
        case manifestBytes
        case installedManifests
        case directories
        case directoryEntries
        case dependencyNodesPerLockfile
        case dependencyNodesPerSession
        case inputBytes
        case wallTimeMilliseconds
    }

    public init(from decoder: any Decoder) throws {
        let rawContainer = try decoder.container(keyedBy: AnyCodingKey.self)
        if let unknownKey = rawContainer.allKeys.first(where: { CodingKeys(rawValue: $0.stringValue) == nil }) {
            throw DecodingError.dataCorruptedError(
                forKey: unknownKey,
                in: rawContainer,
                debugDescription: "Unknown or fixed scan limit override field."
            )
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            generalFiles: try container.decodeIfPresent(UInt64.self, forKey: .generalFiles),
            secretFileBytes: try container.decodeIfPresent(UInt64.self, forKey: .secretFileBytes),
            lockfileBytes: try container.decodeIfPresent(UInt64.self, forKey: .lockfileBytes),
            manifestBytes: try container.decodeIfPresent(UInt64.self, forKey: .manifestBytes),
            installedManifests: try container.decodeIfPresent(UInt64.self, forKey: .installedManifests),
            directories: try container.decodeIfPresent(UInt64.self, forKey: .directories),
            directoryEntries: try container.decodeIfPresent(UInt64.self, forKey: .directoryEntries),
            dependencyNodesPerLockfile: try container.decodeIfPresent(UInt64.self, forKey: .dependencyNodesPerLockfile),
            dependencyNodesPerSession: try container.decodeIfPresent(UInt64.self, forKey: .dependencyNodesPerSession),
            inputBytes: try container.decodeIfPresent(UInt64.self, forKey: .inputBytes),
            wallTimeMilliseconds: try container.decodeIfPresent(UInt64.self, forKey: .wallTimeMilliseconds)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(generalFiles, forKey: .generalFiles)
        try container.encodeIfPresent(secretFileBytes, forKey: .secretFileBytes)
        try container.encodeIfPresent(lockfileBytes, forKey: .lockfileBytes)
        try container.encodeIfPresent(manifestBytes, forKey: .manifestBytes)
        try container.encodeIfPresent(installedManifests, forKey: .installedManifests)
        try container.encodeIfPresent(directories, forKey: .directories)
        try container.encodeIfPresent(directoryEntries, forKey: .directoryEntries)
        try container.encodeIfPresent(dependencyNodesPerLockfile, forKey: .dependencyNodesPerLockfile)
        try container.encodeIfPresent(dependencyNodesPerSession, forKey: .dependencyNodesPerSession)
        try container.encodeIfPresent(inputBytes, forKey: .inputBytes)
        try container.encodeIfPresent(wallTimeMilliseconds, forKey: .wallTimeMilliseconds)
    }

    public func applying(to limits: ScanLimits) throws -> ScanLimits {
        let generalFiles = try validated(generalFiles, field: .generalFiles)
        let secretFileBytes = try validated(secretFileBytes, field: .secretFileBytes)
        let lockfileBytes = try validated(lockfileBytes, field: .lockfileBytes)
        let manifestBytes = try validated(manifestBytes, field: .manifestBytes)
        let installedManifests = try validated(installedManifests, field: .installedManifests)
        let directories = try validated(directories, field: .directories)
        let directoryEntries = try validated(directoryEntries, field: .directoryEntries)
        let dependencyNodesPerLockfile = try validated(dependencyNodesPerLockfile, field: .dependencyNodesPerLockfile)
        let dependencyNodesPerSession = try validated(dependencyNodesPerSession, field: .dependencyNodesPerSession)
        let inputBytes = try validated(inputBytes, field: .inputBytes)
        let wallTimeMilliseconds = try validated(wallTimeMilliseconds, field: .wallTimeMilliseconds)

        return ScanLimits(
            generalFiles: generalFiles ?? limits.generalFiles,
            secretFileBytes: secretFileBytes ?? limits.secretFileBytes,
            lockfileBytes: lockfileBytes ?? limits.lockfileBytes,
            manifestBytes: manifestBytes ?? limits.manifestBytes,
            installedManifests: installedManifests ?? limits.installedManifests,
            directories: directories ?? limits.directories,
            directoryEntries: directoryEntries ?? limits.directoryEntries,
            traversalDepth: limits.traversalDepth,
            relativePathBytes: limits.relativePathBytes,
            structuredDataDepth: limits.structuredDataDepth,
            parsedScalarBytes: limits.parsedScalarBytes,
            dependencyNodesPerLockfile: dependencyNodesPerLockfile ?? limits.dependencyNodesPerLockfile,
            dependencyNodesPerSession: dependencyNodesPerSession ?? limits.dependencyNodesPerSession,
            findingsPerFile: limits.findingsPerFile,
            findingsPerSession: limits.findingsPerSession,
            inputBytes: inputBytes ?? limits.inputBytes,
            wallTimeMilliseconds: wallTimeMilliseconds ?? limits.wallTimeMilliseconds,
            activeWorkers: limits.activeWorkers,
            activeProjectScans: limits.activeProjectScans,
            gitMetadataDescriptors: limits.gitMetadataDescriptors,
            gitDescriptorReserve: limits.gitDescriptorReserve,
            gitOperationMilliseconds: limits.gitOperationMilliseconds,
            gitOutputBytes: limits.gitOutputBytes,
            retainedInputBytes: limits.retainedInputBytes,
            parserArenaBytes: limits.parserArenaBytes,
            findingModelBytes: limits.findingModelBytes,
            rssSoftBytes: limits.rssSoftBytes,
            rssHardBytes: limits.rssHardBytes,
            maximumLinkHops: limits.maximumLinkHops,
            progressIntervalMilliseconds: limits.progressIntervalMilliseconds,
            cancellationLatencyMilliseconds: limits.cancellationLatencyMilliseconds
        )
    }

    private func validated(_ value: UInt64?, field: ScanLimitField) throws -> UInt64? {
        guard let value else {
            return nil
        }
        guard value > 0 else {
            throw ScanLimitError.invalidValue(field)
        }
        guard value <= hardCeiling(for: field) else {
            throw ScanLimitError.exceedsHardCeiling(field)
        }
        return value
    }

    private func hardCeiling(for field: ScanLimitField) -> UInt64 {
        switch field {
        case .generalFiles: return ScanLimits.hardCeilings.generalFiles
        case .secretFileBytes: return ScanLimits.hardCeilings.secretFileBytes
        case .lockfileBytes: return ScanLimits.hardCeilings.lockfileBytes
        case .manifestBytes: return ScanLimits.hardCeilings.manifestBytes
        case .installedManifests: return ScanLimits.hardCeilings.installedManifests
        case .directories: return ScanLimits.hardCeilings.directories
        case .directoryEntries: return ScanLimits.hardCeilings.directoryEntries
        case .dependencyNodesPerLockfile: return ScanLimits.hardCeilings.dependencyNodesPerLockfile
        case .dependencyNodesPerSession: return ScanLimits.hardCeilings.dependencyNodesPerSession
        case .inputBytes: return ScanLimits.hardCeilings.inputBytes
        case .wallTimeMilliseconds: return ScanLimits.hardCeilings.wallTimeMilliseconds
        }
    }
}

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
