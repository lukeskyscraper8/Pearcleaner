import Foundation
import GitEvidenceShared

struct GitEvidencePlatformAdapter: GitEvidenceExecuting {
    private let client: GitEvidenceXPCClient

    init(client: GitEvidenceXPCClient = GitEvidenceXPCClient()) {
        self.client = client
    }

    func execute(
        _ request: GitEvidenceExecutionRequest
    ) async -> Result<GitEvidenceExecutionResponse, GitEvidenceExecutionFailure> {
        do {
            let xpcRequest = try makeXPCRequest(from: request)
            let result = try client.perform(xpcRequest)
            return .success(try makeCoreResponse(from: result, request: request))
        } catch let error as GitEvidenceXPCClientError {
            return .failure(mapClientError(error))
        } catch {
            return .failure(.transportFailed)
        }
    }

    private func makeXPCRequest(from request: GitEvidenceExecutionRequest) throws -> GitEvidenceXPCRequest {
        let operation = try mapOperation(request.operation)
        let hashAlgorithm = mapHashAlgorithm(request.context.objectHashAlgorithm)
        let headObjectID = GitEvidenceXPCObjectID(
            algorithm: hashAlgorithm,
            hex: request.context.headObjectID.hex
        )
        let transferredDescriptors = try request.descriptorTransfers.map { transfer in
            let role = try mapRole(transfer.descriptor.role)
            let identity = GitEvidenceXPCFileIdentity(
                device: transfer.descriptor.identity.device,
                inode: transfer.descriptor.identity.inode,
                size: transfer.descriptor.identity.size,
                mode: transfer.descriptor.identity.mode,
                modificationSeconds: transfer.descriptor.identity.modificationSeconds,
                modificationNanoseconds: transfer.descriptor.identity.modificationNanoseconds,
                statusChangeSeconds: transfer.descriptor.identity.statusChangeSeconds,
                statusChangeNanoseconds: transfer.descriptor.identity.statusChangeNanoseconds
            )
            let objectID = transfer.descriptor.objectID.map {
                GitEvidenceXPCObjectID(algorithm: hashAlgorithm, hex: $0.hex)
            }
            let record = GitEvidenceXPCDescriptorRecord(
                role: role,
                identity: identity,
                objectID: objectID
            )
            let handle = FileHandle(fileDescriptor: transfer.fileDescriptor, closeOnDealloc: false)
            return GitEvidenceXPCTransferredDescriptor(record: record, fileHandle: handle)
        }
        let catFileObjectIDs = request.catFileObjectIDs.map {
            GitEvidenceXPCObjectID(algorithm: hashAlgorithm, hex: $0.hex)
        }
        return try GitEvidenceXPCRequest(
            operation: operation,
            headObjectID: headObjectID,
            catFileObjectIDs: catFileObjectIDs,
            repositoryFormatVersion: Int32(request.context.repositoryFormatVersion),
            objectHashAlgorithm: hashAlgorithm,
            transferredDescriptors: transferredDescriptors
        )
    }

    private func makeCoreResponse(
        from result: GitEvidenceXPCOperationResult,
        request: GitEvidenceExecutionRequest
    ) throws -> GitEvidenceExecutionResponse {
        let hashAlgorithm = mapHashAlgorithm(request.context.objectHashAlgorithm)
        switch request.operation {
        case .listCachedPaths:
            let paths = try GitOutputParser.parseNulDelimitedPaths(from: result.stdoutPreview)
            return GitEvidenceExecutionResponse(cachedPaths: paths)
        case .listHeadTreePaths:
            let records = try GitOutputParser.parseLsTreeRecords(
                from: result.stdoutPreview,
                hashAlgorithm: hashAlgorithm
            )
            let entries = records.compactMap { record -> GitHeadTreePathEntry? in
                guard let objectID = GitObjectID(
                    algorithm: request.context.objectHashAlgorithm,
                    hex: record.oid
                ) else {
                    return nil
                }
                return GitHeadTreePathEntry(
                    path: record.path,
                    objectID: objectID,
                    objectType: record.type
                )
            }
            return GitEvidenceExecutionResponse(headTreeEntries: entries)
        case .catFileBatch:
            let blobBytes = readBlobBytes(from: result.blobPipeReadHandle)
            return GitEvidenceExecutionResponse(catFileBlobBytes: blobBytes)
        }
    }

    private func readBlobBytes(from handle: FileHandle?) -> Data {
        guard let handle else { return Data() }
        return handle.readDataToEndOfFile()
    }

    private func mapOperation(_ operation: GitEvidenceOperation) throws -> GitEvidenceXPCOperation {
        switch operation {
        case .listCachedPaths: return .listCachedPaths
        case .listHeadTreePaths: return .listHeadTreePaths
        case .catFileBatch: return .catFileBatch
        }
    }

    private func mapRole(_ role: GitMetadataDescriptorRole) throws -> GitEvidenceXPCDescriptorRole {
        switch role {
        case .index: return .index
        case .sharedIndex: return .sharedIndex
        case .looseObject: return .looseObject
        case .packIndex: return .packIndex
        case .packData: return .packData
        case .packReverseIndex: return .packReverseIndex
        }
    }

    private func mapHashAlgorithm(
        _ algorithm: GitObjectHashAlgorithm
    ) -> GitEvidenceXPCObjectHashAlgorithm {
        switch algorithm {
        case .sha1: return .sha1
        case .sha256: return .sha256
        }
    }

    private func mapClientError(_ error: GitEvidenceXPCClientError) -> GitEvidenceExecutionFailure {
        switch error {
        case .rejectedStatus(.timedOut):
            return .timedOut
        case .rejectedStatus(.descriptorRejected), .rejectedStatus(.outputLimitExceeded):
            return .descriptorRejected
        case .rejectedStatus(.outputRejected):
            return .outputRejected
        case .rejectedStatus(.operationFailed):
            return .operationFailed
        case .embeddedServiceMissing, .embeddedServiceSignatureRejected,
             .remoteProxyUnavailable, .transportFailed, .emptyReply,
             .rejectedStatus(.invalidRequest), .rejectedStatus(.notImplemented),
             .rejectedStatus(.accepted):
            return .transportFailed
        }
    }
}
