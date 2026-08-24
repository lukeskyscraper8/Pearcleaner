import Darwin
import Foundation
import GitEvidenceShared

final class GitEvidenceServiceDelegate: NSObject, NSXPCListenerDelegate, GitEvidenceXPCProtocol {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        _ = listener

        guard GitEvidenceCodesignValidation.clientIsAllowlisted(pid: newConnection.processIdentifier) else {
            fputs(
                "GitEvidenceService rejected client pid=\(newConnection.processIdentifier)\n",
                stderr
            )
            return false
        }

        let interface = NSXPCInterface(with: GitEvidenceXPCProtocol.self)
        GitEvidenceXPCInterfaceConfigurator.apply(to: interface, isRemote: false)
        newConnection.exportedInterface = interface
        newConnection.exportedObject = self
        newConnection.invalidationHandler = {
            exit(0)
        }
        newConnection.resume()
        return true
    }

    func perform(_ request: GitEvidenceXPCRequest, reply: @escaping (GitEvidenceXPCReply?, NSError?) -> Void) {
        do {
            let result = try handle(request: request)
            reply(GitEvidenceXPCReply(result: result), nil)
        } catch let validationError as GitEvidenceXPCValidationError {
            reply(
                GitEvidenceXPCReply(
                    result: GitEvidenceXPCOperationResult(status: status(for: validationError))
                ),
                nil
            )
        } catch {
            reply(nil, error as NSError)
        }
    }

    private func handle(request: GitEvidenceXPCRequest) throws -> GitEvidenceXPCOperationResult {
        guard GitEvidenceXPCOperation(rawValue: request.operation) != nil else {
            throw GitEvidenceXPCValidationError.unknownOperation
        }

        guard request.transferredDescriptors.count <= GitEvidenceXPCLimits.maxTransferBatchSize else {
            throw GitEvidenceXPCValidationError.batchTooLarge
        }

        for transferred in request.transferredDescriptors {
            let descriptor = transferred.fileHandle.fileDescriptor
            _ = try GitEvidenceDescriptorValidator.validateReadOnlyRegularFile(
                fileDescriptor: descriptor,
                expectedIdentity: transferred.record.identity
            )
        }

        let blobPipeReadHandle = try makeAnonymousReadPipeHandle()

        return GitEvidenceXPCOperationResult(
            status: .accepted,
            blobPipeReadHandle: blobPipeReadHandle
        )
    }

    private func status(for error: GitEvidenceXPCValidationError) -> GitEvidenceXPCOperationStatus {
        switch error {
        case .batchTooLarge, .unknownOperation:
            .invalidRequest
        case .invalidDescriptor, .notReadOnly, .notRegularFile, .identityMismatch:
            .descriptorRejected
        }
    }

    private func makeAnonymousReadPipeHandle() throws -> FileHandle {
        var pipeFds: [Int32] = [0, 0]
        guard pipe(&pipeFds) == 0 else {
            throw POSIXError(.EMFILE)
        }

        close(pipeFds[1])
        return FileHandle(fileDescriptor: pipeFds[0], closeOnDealloc: true)
    }
}
