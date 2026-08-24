import Darwin
import Foundation

public actor ProjectStateStore {
    private let atomicFile: AtomicStateFile
    private let transactionLock: ProjectStateTransactionLock
    private let keyCoordinator: ProjectKeyCoordinator
    private let uuid: any UUIDGenerating

    public init(
        environment: any ScannerEnvironmentProviding,
        keyCoordinator: ProjectKeyCoordinator
    ) async throws {
        let parent: PrivateStateParentCapability
        do { parent = try environment.privateStateParent() }
        catch { throw ProjectStateError.stateUnavailable }
        defer { parent.close() }
        let components = try await openStateInfrastructure(
            parent: parent,
            operations: SystemStateFileSystemOperations(),
            backupOperations: SystemBackupExclusionOperations()
        )
        atomicFile = components.atomicFile
        transactionLock = components.transactionLock
        self.keyCoordinator = keyCoordinator
        uuid = SystemProjectStateUUIDGenerator()
    }

    init(
        parent: PrivateStateParentCapability,
        keyCoordinator: ProjectKeyCoordinator,
        uuid: any UUIDGenerating,
        operations: any StateFileSystemOperations,
        backupOperations: any BackupExclusionOperations
    ) async throws {
        let components = try await openStateInfrastructure(
            parent: parent,
            operations: operations,
            backupOperations: backupOperations
        )
        atomicFile = components.atomicFile
        transactionLock = components.transactionLock
        self.keyCoordinator = keyCoordinator
        self.uuid = uuid
    }

    public func register(
        label: String?,
        bookmark: ProjectBookmark,
        limitOverrides: ScanLimitOverrides,
        lease: ProjectKeyLease
    ) async throws -> ProjectRegistration {
        let generation = try persistentGeneration(for: lease)
        let projectUUID = uuid.makeUUID()
        let envelope = try PersistedProjectState(
            projectID: projectUUID,
            label: label,
            bookmark: bookmark,
            keyGeneration: generation,
            limitOverrides: limitOverrides
        )
        let projectID = ProjectID(rawValue: projectUUID)
        let filename = stateFilename(for: projectID)
        let configuration = try envelope.configuration

        let (_, commit) = try await performMutation {
            let existing = try self.atomicFile.inspect(
                name: filename,
                site: .inspectRegistrationDestination
            )
            if let existing {
                switch existing.st_mode & S_IFMT {
                case S_IFREG, S_IFLNK:
                    throw ProjectStateError.identifierCollision
                default:
                    throw ProjectStateError.stateUnavailable
                }
            }
            let data = try ProjectStateJSONCodec.encode(envelope)
            try await self.requireValid(lease)
            let outcome = try self.atomicFile.write(
                data: data,
                destinationName: filename,
                stagingUUID: self.uuid.makeUUID()
            )
            return ((), outcome)
        }
        return ProjectRegistration(
            projectID: projectID,
            configuration: configuration,
            commit: commit
        )
    }

    public func recordAttempt(
        projectID: ProjectID,
        coverage: ScanCoverageSnapshot,
        finishedAt: Date,
        metadata: AttemptSummaryMetadata,
        lease: ProjectKeyLease
    ) async throws -> ProjectStateCommit {
        let attempt = try PersistedAttempt(
            coverage: coverage,
            finishedAt: finishedAt,
            metadata: metadata
        )
        let complete: PersistedCompleteSummary?
        if coverage.terminalState == .complete {
            complete = try PersistedCompleteSummary(
                coverage: coverage,
                finishedAt: finishedAt,
                metadata: metadata
            )
        } else {
            complete = nil
        }

        let (_, commit) = try await performMutation {
            var envelope = try self.requireEnvelope(projectID: projectID)
            try self.requireMatchingGeneration(lease, envelope: envelope)
            envelope.lastAttempt = attempt
            if let complete { envelope.lastCompleteSummary = complete }
            envelope.advisoryCacheSchemaVersion = metadata.advisoryCacheSchemaVersion
            let data = try ProjectStateJSONCodec.encode(envelope)
            try await self.requireValid(lease)
            let outcome = try self.atomicFile.write(
                data: data,
                destinationName: stateFilename(for: projectID),
                stagingUUID: self.uuid.makeUUID()
            )
            return ((), outcome)
        }
        return commit
    }

    public func addSuppression(
        projectID: ProjectID,
        record: SuppressionRecord,
        lease: ProjectKeyLease
    ) async throws -> ProjectStateCommit {
        let persistedRecord = PersistedSuppressionRecord(record)
        let (_, commit) = try await performMutation {
            var envelope = try self.requireEnvelope(projectID: projectID)
            try self.requireMatchingGeneration(lease, envelope: envelope)
            guard !envelope.suppressions.contains(where: {
                $0.fingerprint == persistedRecord.fingerprint
            }) else {
                throw ProjectStateError.duplicateSuppression
            }
            guard envelope.suppressions.count < 10_000 else {
                throw ProjectStateError.suppressionLimit
            }
            envelope.suppressions.append(persistedRecord)
            let data = try ProjectStateJSONCodec.encode(envelope)
            try await self.requireValid(lease)
            let outcome = try self.atomicFile.write(
                data: data,
                destinationName: stateFilename(for: projectID),
                stagingUUID: self.uuid.makeUUID()
            )
            return ((), outcome)
        }
        return commit
    }

    public func loadSummary(projectID: ProjectID) throws -> ProjectConfigurationSnapshot? {
        guard let envelope = try loadEnvelope(projectID: projectID) else { return nil }
        return try envelope.configuration
    }

    public func loadForScan(projectID: ProjectID) async throws -> ProjectStateAccess? {
        guard let envelope = try loadEnvelope(projectID: projectID) else { return nil }
        let configuration = try envelope.configuration
        let access: ProjectKeyAccess
        do {
            access = try await keyCoordinator.access(
                for: .generation(envelope.keyGeneration)
            )
        } catch is CancellationError {
            throw ProjectStateError.cancelled
        } catch {
            throw ProjectStateError.stateUnavailable
        }
        switch access {
        case .ready(let lease):
            switch lease.persistence {
            case .persistent(let generation):
                guard generation == envelope.keyGeneration else {
                    throw ProjectStateError.keyResetRequired
                }
                let suppressions: [SuppressionRecord]
                do { suppressions = try envelope.suppressions.map { try $0.publicValue } }
                catch { throw ProjectStateError.invalidState }
                return .persistent(configuration, suppressions: suppressions, lease: lease)
            case .ephemeral:
                return .ephemeral(configuration, lease: lease)
            }
        case .resetRequired:
            return .resetRequired(configuration)
        }
    }

    private func performMutation<Value>(
        _ operation: () async throws -> (Value, AtomicStateWriteOutcome)
    ) async throws -> (Value, ProjectStateCommit) {
        do { try await transactionLock.acquire() }
        catch { throw publicStateError(error) }

        do {
            let (value, outcome) = try await operation()
            do {
                try transactionLock.release()
                return (value, commit(for: outcome))
            } catch {
                transactionLock.retireAfterReleaseFailure()
                return (value, .committedDurabilityUncertain)
            }
        } catch {
            do { try transactionLock.release() }
            catch { transactionLock.retireAfterReleaseFailure() }
            throw publicStateError(error)
        }
    }

    private func loadEnvelope(projectID: ProjectID) throws -> PersistedProjectState? {
        let data = try atomicFile.read(name: stateFilename(for: projectID))
        guard let data else { return nil }
        return try ProjectStateJSONCodec.decode(data, expectedProjectID: projectID)
    }

    private func requireEnvelope(projectID: ProjectID) throws -> PersistedProjectState {
        guard let envelope = try loadEnvelope(projectID: projectID) else {
            throw ProjectStateError.stateUnavailable
        }
        return envelope
    }

    private func requireMatchingGeneration(
        _ lease: ProjectKeyLease,
        envelope: PersistedProjectState
    ) throws {
        guard case .persistent(let generation) = lease.persistence else {
            throw ProjectStateError.ephemeralRun
        }
        guard generation == envelope.keyGeneration else {
            throw ProjectStateError.keyResetRequired
        }
    }

    private func requireValid(_ lease: ProjectKeyLease) async throws {
        switch await keyCoordinator.revalidate(lease) {
        case .valid: return
        case .ephemeralOnly: throw ProjectStateError.ephemeralRun
        case .resetRequired: throw ProjectStateError.keyResetRequired
        }
    }
}

private struct SystemProjectStateUUIDGenerator: UUIDGenerating {
    func makeUUID() -> UUID { UUID() }
}

private func persistentGeneration(for lease: ProjectKeyLease) throws -> UUID {
    guard case .persistent(let generation) = lease.persistence else {
        throw ProjectStateError.ephemeralRun
    }
    return generation
}

private func stateFilename(for projectID: ProjectID) -> String {
    "project-\(projectID.rawValue.uuidString.lowercased()).json"
}

private func commit(for outcome: AtomicStateWriteOutcome) -> ProjectStateCommit {
    switch outcome {
    case .committed: return .committed
    case .committedDurabilityUncertain: return .committedDurabilityUncertain
    }
}

private func publicStateError(_ error: Error) -> ProjectStateError {
    if let state = error as? ProjectStateError { return state }
    if error is CancellationError { return .cancelled }
    return .stateUnavailable
}

private func openStateInfrastructure(
    parent: PrivateStateParentCapability,
    operations: any StateFileSystemOperations,
    backupOperations: any BackupExclusionOperations
) async throws -> (atomicFile: AtomicStateFile, transactionLock: ProjectStateTransactionLock) {
    let atomicFile = try AtomicStateFile.open(
        parent: parent,
        operations: operations,
        backupOperations: backupOperations
    )
    do {
        let transactionLock = try ProjectStateTransactionLock.open(
            directoryDescriptor: atomicFile.retainedDirectoryDescriptor(),
            operations: operations
        )
        do {
            try await transactionLock.acquire()
            do {
                try atomicFile.removeValidatedStagingFiles()
            } catch {
                do { try transactionLock.release() }
                catch { transactionLock.retireAfterReleaseFailure() }
                throw error
            }
            do { try transactionLock.release() }
            catch {
                transactionLock.retireAfterReleaseFailure()
                throw error
            }
            return (atomicFile, transactionLock)
        } catch {
            transactionLock.close()
            throw closedStateError(error)
        }
    } catch {
        atomicFile.close()
        throw closedStateError(error)
    }
}
