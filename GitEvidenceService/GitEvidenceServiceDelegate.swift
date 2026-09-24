import Darwin
import Foundation
import GitEvidenceShared

final class GitEvidenceServiceDelegate: NSObject, NSXPCListenerDelegate, GitEvidenceXPCProtocol {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        _ = listener

        // Pin the client through the XPC runtime's audit-token check, as
        // PearcleanerHelper does, rather than a racy pid-based lookup.
        GitEvidenceCodesignValidation.applyClientRequirement(to: newConnection)

        #if GIT_FEASIBILITY_HARNESS
        let interface = GitEvidenceXPCHarnessInterface.make()
        #else
        let interface = NSXPCInterface(with: GitEvidenceXPCProtocol.self)
        GitEvidenceXPCInterfaceConfigurator.apply(to: interface, isRemote: false)
        #endif
        newConnection.exportedInterface = interface
        newConnection.exportedObject = self
        // Don't exit when a connection closes: the service keeps no state
        // between requests, and exiting can interrupt a new connection launchd
        // has already routed to this process. launchd ends idle services.
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
        } catch let adminViewError as GitSyntheticAdminViewError where adminViewError.isMalformedRequest {
            reply(
                GitEvidenceXPCReply(result: GitEvidenceXPCOperationResult(status: .invalidRequest)),
                nil
            )
        } catch {
            reply(nil, error as NSError)
        }
    }

    private func handle(request: GitEvidenceXPCRequest) throws -> GitEvidenceXPCOperationResult {
        guard let operation = GitEvidenceXPCOperation(rawValue: request.operation) else {
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

        guard let hashAlgorithm = GitEvidenceXPCObjectHashAlgorithm(rawValue: request.objectHashAlgorithm) else {
            return GitEvidenceXPCOperationResult(status: .invalidRequest)
        }

        if operation == .listHeadTreePaths, request.headObjectID == nil {
            return GitEvidenceXPCOperationResult(status: .invalidRequest)
        }

        if operation == .catFileBatch, request.catFileObjectIDs.isEmpty {
            return GitEvidenceXPCOperationResult(status: .invalidRequest)
        }

        let servicePaths = try makeServicePaths()
        let adminView = try GitSyntheticAdminView.build(
            serviceHome: servicePaths.home,
            serviceTemporaryDirectory: servicePaths.temporary,
            repositoryFormatVersion: request.repositoryFormatVersion,
            objectHashAlgorithm: hashAlgorithm,
            headObjectID: request.headObjectID,
            transferredDescriptors: request.transferredDescriptors
        )
        defer { adminView.destroy() }

        var blobPipeFds: [Int32] = [0, 0]
        let blobPipeReadHandle: FileHandle?
        let blobPipeWriteFD: Int32?
        if operation == .catFileBatch {
            guard pipe(&blobPipeFds) == 0 else {
                throw POSIXError(.EMFILE)
            }
            blobPipeReadHandle = FileHandle(fileDescriptor: blobPipeFds[0], closeOnDealloc: true)
            blobPipeWriteFD = blobPipeFds[1]
        } else {
            blobPipeReadHandle = nil
            blobPipeWriteFD = nil
        }
        defer {
            if let blobPipeWriteFD, blobPipeWriteFD >= 0 {
                close(blobPipeWriteFD)
            }
        }

        let runnerURL = try embeddedRunnerURL()
        let catFileObjectHexes = request.catFileObjectIDs.map(\.hex)

        let supervisorResult = try GitOperationSupervisor.run(
            operation: operation,
            runnerExecutableURL: runnerURL,
            adminView: adminView,
            headObjectHex: request.headObjectID?.hex,
            catFileObjectIDs: catFileObjectHexes,
            blobPipeWriteFD: blobPipeWriteFD
        )

        if supervisorResult.terminationReason == .timedOut {
            return failureResult(
                status: .timedOut,
                stdout: supervisorResult.stdout,
                stderr: supervisorResult.stderr
            )
        }

        if supervisorResult.terminationReason == .outputLimitExceeded {
            return failureResult(
                status: .outputLimitExceeded,
                stdout: supervisorResult.stdout,
                stderr: supervisorResult.stderr
            )
        }

        guard supervisorResult.terminationReason == .exited, supervisorResult.exitCode == 0 else {
            return failureResult(
                status: .operationFailed,
                stdout: supervisorResult.stdout,
                stderr: supervisorResult.stderr
            )
        }

        do {
            try validateParsedOutput(
                operation: operation,
                stdout: supervisorResult.stdout,
                hashAlgorithm: hashAlgorithm,
                catFileObjectHexes: catFileObjectHexes
            )
        } catch {
            return failureResult(
                status: .outputRejected,
                stdout: supervisorResult.stdout,
                stderr: supervisorResult.stderr
            )
        }

        return GitEvidenceXPCOperationResult(
            status: .accepted,
            stdoutByteCount: UInt64(supervisorResult.stdout.count),
            stderrByteCount: UInt64(supervisorResult.stderr.count),
            stdoutPreview: supervisorResult.stdout,
            stderrPreview: supervisorResult.stderr,
            blobPipeReadHandle: blobPipeReadHandle
        )
    }

    private func validateParsedOutput(
        operation: GitEvidenceXPCOperation,
        stdout: Data,
        hashAlgorithm: GitEvidenceXPCObjectHashAlgorithm,
        catFileObjectHexes: [String]
    ) throws {
        switch operation {
        case .listCachedPaths:
            _ = try GitOutputParser.parseNulDelimitedPaths(from: stdout)
        case .listHeadTreePaths:
            _ = try GitOutputParser.parseLsTreeRecords(from: stdout, hashAlgorithm: hashAlgorithm)
        case .catFileBatch:
            var parser = try GitCatFileBatchHeaderParser(
                expectedOIDs: catFileObjectHexes,
                hashAlgorithm: hashAlgorithm,
                payloadsIncluded: false
            )
            _ = try parser.append(stdout)
            try parser.finish()
        }
    }

    private func failureResult(
        status: GitEvidenceXPCOperationStatus,
        stdout: Data,
        stderr: Data
    ) -> GitEvidenceXPCOperationResult {
        GitEvidenceXPCOperationResult(
            status: status,
            stdoutByteCount: UInt64(stdout.count),
            stderrByteCount: UInt64(stderr.count),
            stdoutPreview: stdout,
            stderrPreview: stderr
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

    private func makeServicePaths() throws -> (home: URL, temporary: URL) {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("git-evidence-service-\(UUID().uuidString)", isDirectory: true)
        let home = base.appendingPathComponent("home", isDirectory: true)
        let temporary = base.appendingPathComponent("tmp", isDirectory: true)
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
        return (home, temporary)
    }

    private func embeddedRunnerURL() throws -> URL {
        if let auxiliary = Bundle.main.url(forAuxiliaryExecutable: "GitRunner") {
            return auxiliary
        }

        let xpcBundleURL = Bundle.main.bundleURL
        let appBundleURL = xpcBundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidate = appBundleURL.appendingPathComponent("Contents/MacOS/GitRunner")
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }

        throw POSIXError(.ENOENT)
    }
}

#if GIT_FEASIBILITY_HARNESS
extension GitEvidenceServiceDelegate: GitEvidenceXPCHarnessProtocol {
    func runHarnessProbe(_ arguments: [String], reply: @escaping (String, Int32, Data) -> Void) {
        guard let probe = arguments.first,
              GitEvidenceXPCHarnessInterface.probeArguments.contains(probe) else {
            reply(GitEvidenceXPCOperationStatus.invalidRequest.rawValue, -1, Data())
            return
        }

        do {
            let servicePaths = try makeServicePaths()
            let probeView = try GitSyntheticAdminView.buildProbeView(
                serviceHome: servicePaths.home,
                serviceTemporaryDirectory: servicePaths.temporary
            )
            defer { probeView.destroy() }

            let result = try GitOperationSupervisor.runHarnessProbe(
                arguments: arguments,
                runnerExecutableURL: try embeddedRunnerURL(),
                adminView: probeView
            )
            let status: GitEvidenceXPCOperationStatus = switch result.terminationReason {
            case .timedOut: .timedOut
            case .outputLimitExceeded: .outputLimitExceeded
            case .exited, .signal: .accepted
            }
            reply(status.rawValue, result.exitCode, result.stderr)
        } catch {
            reply(
                GitEvidenceXPCOperationStatus.operationFailed.rawValue,
                -1,
                Data(String(describing: error).utf8)
            )
        }
    }
}
#endif

private extension GitSyntheticAdminViewError {
    /// True when the request itself is malformed, as opposed to a service fault.
    var isMalformedRequest: Bool {
        if case .filesystemFailure = self {
            return false
        }
        return true
    }
}
