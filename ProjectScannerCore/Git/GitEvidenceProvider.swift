import Foundation

private enum GitOperationStep<T>: Sendable {
    case success(T)
    case failure(CoverageReasonCode)
}

struct GitEvidenceProvider: Sendable {
    private let feasibility: GitFeasibilityProviding
    private let executor: GitEvidenceExecuting
    private let limits: ScanLimits

    init(
        feasibility: GitFeasibilityProviding,
        executor: GitEvidenceExecuting,
        limits: ScanLimits = .defaults
    ) {
        self.feasibility = feasibility
        self.executor = executor
        self.limits = limits
    }

    func collect(
        broker: FileBroker,
        ledger: CoverageLedger,
        transaction: CoverageTransactionID,
        request: GitEvidenceCollectionRequest,
        blobConsumer: (any GitIndexHeadBlobConsuming)? = nil
    ) async -> GitEvidenceCollectionOutcome {
        let repositoryID = RepositoryCoverageID()

        guard feasibility.currentSnapshot().isEnabled else {
            try? await recordUnavailable(
                ledger: ledger,
                transaction: transaction,
                repositoryID: repositoryID,
                reason: .gitPreflightRejected
            )
            return .unavailable(.gitPreflightRejected)
        }

        let preflight = await GitRepositoryPreflight().preflight(broker: broker)
        switch preflight {
        case let .rejected(reason):
            try? await recordUnavailable(
                ledger: ledger,
                transaction: transaction,
                repositoryID: repositoryID,
                reason: .gitPreflightRejected
            )
            _ = reason
            return .unavailable(.gitPreflightRejected)
        case let .accepted(context):
            return await collectAccepted(
                broker: broker,
                ledger: ledger,
                transaction: transaction,
                repositoryID: repositoryID,
                context: context,
                request: request,
                blobConsumer: blobConsumer
            )
        }
    }

    private func collectAccepted(
        broker: FileBroker,
        ledger: CoverageLedger,
        transaction: CoverageTransactionID,
        repositoryID: RepositoryCoverageID,
        context: GitRepositoryContext,
        request: GitEvidenceCollectionRequest,
        blobConsumer: (any GitIndexHeadBlobConsuming)?
    ) async -> GitEvidenceCollectionOutcome {
        var limitingReason: CoverageReasonCode?
        let ignoredPaths = await buildIgnoredPaths(broker: broker, context: context, request: request)

        let indexDescriptors = descriptorsForIndexMembership(context: context)
        let indexedPaths: Set<VerifiedRelativePath>
        switch await performListCachedPaths(
            broker: broker,
            context: context,
            descriptors: indexDescriptors
        ) {
        case let .success(paths):
            indexedPaths = paths
        case let .failure(reason):
            try? await recordPartialOrUnavailable(
                ledger: ledger,
                transaction: transaction,
                repositoryID: repositoryID,
                preflight: .complete,
                operation: .unavailable(reason),
                reason: reason
            )
            return .unavailable(reason)
        }

        let objectDescriptors = descriptorsForObjectOperations(context: context)
        let headEntries: [GitHeadTreePathEntry]
        switch await performListHeadTree(
            broker: broker,
            context: context,
            descriptors: objectDescriptors
        ) {
        case let .success(entries):
            headEntries = entries
        case let .failure(reason):
            limitingReason = reason
            headEntries = []
        }

        let headPaths = Set(headEntries.compactMap {
            GitPathParsing.verifiedRelativePath(fromGitPath: $0.path)
        })
        var headObjectIDsByPath: [VerifiedRelativePath: GitObjectID] = [:]
        for entry in headEntries {
            if let path = GitPathParsing.verifiedRelativePath(fromGitPath: entry.path) {
                headObjectIDsByPath[path] = entry.objectID
            }
        }

        let stagedPaths = indexedPaths.subtracting(headPaths)

        if limitingReason == nil,
           !objectDescriptors.isEmpty,
           objectDescriptors.count < context.manifest.descriptors.count {
            limitingReason = .gitDescriptorBudget
        }

        if limitingReason == nil, !headEntries.isEmpty, let blobConsumer {
            let blobObjectIDs = headEntries.map(\.objectID)
            if !blobObjectIDs.isEmpty {
                switch await performCatFileBatch(
                    broker: broker,
                    context: context,
                    descriptors: objectDescriptors,
                    objectIDs: blobObjectIDs,
                    headEntries: headEntries,
                    blobConsumer: blobConsumer
                ) {
                case .success:
                    break
                case let .failure(reason):
                    limitingReason = reason
                }
            }
        }

        let facts = GitPathFacts(
            repositoryID: repositoryID,
            indexedPaths: indexedPaths,
            headPaths: headPaths,
            headObjectIDsByPath: headObjectIDsByPath,
            stagedPaths: stagedPaths,
            ignoredPaths: ignoredPaths,
            workingTreePaths: request.workingTreePaths
        )

        if let limitingReason {
            try? await recordPartialOrUnavailable(
                ledger: ledger,
                transaction: transaction,
                repositoryID: repositoryID,
                preflight: .complete,
                operation: .partial(limitingReason),
                reason: limitingReason
            )
            return .partial(facts, limitingReason)
        }

        try? await recordComplete(
            ledger: ledger,
            transaction: transaction,
            repositoryID: repositoryID
        )
        return .complete(facts)
    }

    private func buildIgnoredPaths(
        broker: FileBroker,
        context: GitRepositoryContext,
        request: GitEvidenceCollectionRequest
    ) async -> GitIgnoredPathFacts {
        let excludePath = excludeFilePath(for: context)
        let excludeContents = (try? await broker.readBoundedGitMetadataFile(
            at: excludePath,
            maxBytes: GitIgnoreClassifierLimits.maxBytesPerFile
        )) ?? Data()

        var gitignoreFiles: [(directory: VerifiedRelativePath?, contents: Data)] = []
        for gitignorePath in request.gitignoreFilePaths {
            guard let parentDirectory = parentDirectory(of: gitignorePath) else { continue }
            guard let contents = try? await broker.readBoundedGitMetadataFile(
                at: gitignorePath,
                maxBytes: GitIgnoreClassifierLimits.maxBytesPerFile
            ) else {
                return .unavailable
            }
            gitignoreFiles.append((directory: parentDirectory, contents: contents))
        }

        switch GitIgnoreClassifier.build(
            excludeFileContents: excludeContents.isEmpty ? nil : excludeContents,
            gitignoreFiles: gitignoreFiles
        ) {
        case let .available(classifier):
            let ignored = request.workingTreePaths.filter { classifier.isIgnored($0) }
            return .available(Set(ignored))
        case .unsupported:
            return .unavailable
        }
    }

    private func excludeFilePath(for context: GitRepositoryContext) -> VerifiedRelativePath {
        let components = context.commonDir.identityComponents + [Data("info".utf8), Data("exclude".utf8)]
        return (try? VerifiedRelativePath(
            components: components.compactMap { try? VerifiedPathComponent(bytes: $0) }
        )) ?? context.gitDir
    }

    private func parentDirectory(of path: VerifiedRelativePath) -> VerifiedRelativePath? {
        guard path.identityComponents.count > 1 else { return nil }
        let parentComponents = path.identityComponents.dropLast().compactMap {
            try? VerifiedPathComponent(bytes: $0)
        }
        return try? VerifiedRelativePath(components: parentComponents)
    }

    private func descriptorsForIndexMembership(
        context: GitRepositoryContext
    ) -> [GitMetadataDescriptor] {
        context.manifest.descriptors.filter { descriptor in
            switch descriptor.role {
            case .index, .sharedIndex:
                return true
            case .looseObject, .packIndex, .packData, .packReverseIndex:
                return false
            }
        }
    }

    private func descriptorsForObjectOperations(
        context: GitRepositoryContext
    ) -> [GitMetadataDescriptor] {
        let indexDescriptors = Set(descriptorsForIndexMembership(context: context))
        let budget = Int(limits.gitMetadataDescriptors)
        var selected = Array(indexDescriptors)
        guard selected.count < budget else { return selected }

        for descriptor in context.manifest.descriptors where !indexDescriptors.contains(descriptor) {
            selected.append(descriptor)
            if selected.count >= budget {
                break
            }
        }
        return selected
    }

    private func performListCachedPaths(
        broker: FileBroker,
        context: GitRepositoryContext,
        descriptors: [GitMetadataDescriptor]
    ) async -> GitOperationStep<Set<VerifiedRelativePath>> {
        await performOperation(
            broker: broker,
            context: context,
            descriptors: descriptors,
            operation: .listCachedPaths
        ) { response in
            GitPathParsing.verifiedRelativePaths(fromGitPaths: response.cachedPaths)
        }
    }

    private func performListHeadTree(
        broker: FileBroker,
        context: GitRepositoryContext,
        descriptors: [GitMetadataDescriptor]
    ) async -> GitOperationStep<[GitHeadTreePathEntry]> {
        await performOperation(
            broker: broker,
            context: context,
            descriptors: descriptors,
            operation: .listHeadTreePaths
        ) { response in
            response.headTreeEntries
        }
    }

    private func performCatFileBatch(
        broker: FileBroker,
        context: GitRepositoryContext,
        descriptors: [GitMetadataDescriptor],
        objectIDs: [GitObjectID],
        headEntries: [GitHeadTreePathEntry],
        blobConsumer: any GitIndexHeadBlobConsuming
    ) async -> GitOperationStep<Void> {
        let step: GitOperationStep<Data> = await performOperation(
            broker: broker,
            context: context,
            descriptors: descriptors,
            operation: .catFileBatch,
            catFileObjectIDs: objectIDs
        ) { response in
            response.catFileBlobBytes
        }

        switch step {
        case let .success(bytes):
            if !bytes.isEmpty,
               let firstObjectID = objectIDs.first,
               let firstEntry = headEntries.first(where: { $0.objectID == firstObjectID }),
               let path = GitPathParsing.verifiedRelativePath(fromGitPath: firstEntry.path) {
                await blobConsumer.consumeBlob(
                    objectID: firstObjectID,
                    path: path,
                    bytes: bytes
                )
            }
            return .success(())
        case let .failure(reason):
            return .failure(reason)
        }
    }

    private func performOperation<T>(
        broker: FileBroker,
        context: GitRepositoryContext,
        descriptors: [GitMetadataDescriptor],
        operation: GitEvidenceOperation,
        catFileObjectIDs: [GitObjectID] = [],
        map: (GitEvidenceExecutionResponse) -> T
    ) async -> GitOperationStep<T> {
        let manifestSnapshot = context.manifest
        var opened: [GitMetadataOpenedTransfer] = []
        defer { opened.forEach { $0.close() } }

        do {
            opened = try await broker.openGitMetadataTransfers(for: descriptors)
        } catch {
            return .failure(.unreadable)
        }

        let transfers = opened.map(\.transfer)
        let batches = transfers.chunked(
            size: GitMetadataDescriptorBatchLimits.maxTransferBatchSize
        )
        var combined = GitEvidenceExecutionResponse()

        for batch in batches {
            let request = GitEvidenceExecutionRequest(
                operation: operation,
                context: context,
                descriptorTransfers: batch,
                catFileObjectIDs: catFileObjectIDs
            )
            let execution = await executor.execute(request)
            switch execution {
            case let .success(response):
                if operation == .listCachedPaths {
                    combined = GitEvidenceExecutionResponse(
                        cachedPaths: response.cachedPaths,
                        headTreeEntries: combined.headTreeEntries,
                        catFileBlobBytes: combined.catFileBlobBytes
                    )
                } else if operation == .listHeadTreePaths {
                    combined = GitEvidenceExecutionResponse(
                        cachedPaths: combined.cachedPaths,
                        headTreeEntries: response.headTreeEntries,
                        catFileBlobBytes: combined.catFileBlobBytes
                    )
                } else {
                    combined = GitEvidenceExecutionResponse(
                        cachedPaths: combined.cachedPaths,
                        headTreeEntries: combined.headTreeEntries,
                        catFileBlobBytes: response.catFileBlobBytes
                    )
                }
            case let .failure(failure):
                return .failure(coverageReason(for: failure))
            }

            guard await broker.revalidateGitMetadataManifest(manifestSnapshot) else {
                return .failure(.identityChanged)
            }
        }

        return .success(map(combined))
    }

    private func coverageReason(for failure: GitEvidenceExecutionFailure) -> CoverageReasonCode {
        switch failure {
        case .timedOut:
            return .gitTimeout
        case .descriptorRejected, .outputLimitExceeded:
            return .gitDescriptorBudget
        case .transportFailed, .outputRejected, .operationFailed, .unavailable:
            return .unreadable
        }
    }

    private func recordComplete(
        ledger: CoverageLedger,
        transaction: CoverageTransactionID,
        repositoryID: RepositoryCoverageID
    ) async throws {
        try await ledger.record(
            .gitRepository(repositoryID, preflight: .complete, operation: .complete),
            in: transaction
        )
    }

    private func recordPartialOrUnavailable(
        ledger: CoverageLedger,
        transaction: CoverageTransactionID,
        repositoryID: RepositoryCoverageID,
        preflight: GitPreflightStatus,
        operation: GitOperationStatus,
        reason: CoverageReasonCode
    ) async throws {
        try await ledger.record(
            .gitRepository(repositoryID, preflight: preflight, operation: operation),
            in: transaction
        )
        try await ledger.record(.failed(reason: reason, files: 1, bytes: 0), in: transaction)
    }

    private func recordUnavailable(
        ledger: CoverageLedger,
        transaction: CoverageTransactionID,
        repositoryID: RepositoryCoverageID,
        reason: CoverageReasonCode
    ) async throws {
        try await ledger.record(
            .gitRepository(
                repositoryID,
                preflight: .unavailable(reason),
                operation: .absent
            ),
            in: transaction
        )
        try await ledger.record(.unsupported(reason: reason, files: 1, bytes: 0), in: transaction)
    }
}

private extension Array {
    func chunked(size: Int) -> [[Element]] {
        guard size > 0 else { return isEmpty ? [] : [self] }
        var result: [[Element]] = []
        var index = startIndex
        while index < endIndex {
            let end = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(Array(self[index..<end]))
            index = end
        }
        return result
    }
}
