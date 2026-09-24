import Darwin
import Foundation
import GitEvidenceShared

enum DescriptorTransferScenarioSupport {
    static func embeddedServiceURL(bundle: Bundle = .main) throws -> URL {
        guard let serviceURL = GitEvidenceXPCConnectionFactory.embeddedServiceURL(in: bundle),
              FileManager.default.fileExists(atPath: serviceURL.path) else {
            throw FeasibilityScenarioFailure.scenarioFailed(
                .descriptorTransfer,
                reason: "embedded GitEvidenceService.xpc is missing from the harness bundle"
            )
        }
        return serviceURL
    }

    static func repositoryRootURL(bundle: Bundle = .main) throws -> URL {
        _ = bundle
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("descriptor-transfer-\(UUID().uuidString)", isDirectory: true)
        let gitDirectory = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        try minimalIndexFixture().write(to: gitDirectory.appendingPathComponent("index"))
        return root
    }

    private static func minimalIndexFixture() -> Data {
        // The index from minimal-repo-fixture.json: one tracked.txt entry.
        Data(base64Encoded: "RElSQwAAAAIAAAABaowtOBhcHbJqjCyXLDwM4QEAABIFduYnAACBpAAAAfUAAAAUAAAAEMp5qduRWKbjFNKqulwc8zlXYhIaAAt0cmFja2VkLnR4dAAAAAAAAABUUkVFAAAAGQAxIDAKbdo3Ag/eIGAk0N3HPK7FMt976HTMVP2i2Wzr1Pacu4Ar9Jmxm/rqZQ==")!
    }

    static func openReadOnlyDescriptor(for url: URL) throws -> Int32 {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw FeasibilityScenarioFailure.scenarioFailed(
                .descriptorTransfer,
                reason: "unable to open \(url.lastPathComponent): \(String(cString: strerror(errno)))"
            )
        }
        return descriptor
    }

    static func makeIdentity(for descriptor: Int32) throws -> GitEvidenceXPCFileIdentity {
        var statBuffer = stat()
        guard fstat(descriptor, &statBuffer) == 0 else {
            throw FeasibilityScenarioFailure.scenarioFailed(
                .descriptorTransfer,
                reason: "unable to stat transferred descriptor"
            )
        }
        return GitEvidenceXPCFileIdentity(statBuffer: statBuffer)
    }

    static func performDescriptorTransfer(
        serviceURL: URL,
        transferredDescriptors: [GitEvidenceXPCTransferredDescriptor]
    ) throws -> GitEvidenceXPCOperationResult {
        let pingRequest = try GitEvidenceXPCRequest(
            operation: .listCachedPaths,
            headObjectID: nil,
            repositoryFormatVersion: 0,
            objectHashAlgorithm: .sha1,
            transferredDescriptors: []
        )
        // The ping carries no index descriptor, so a reachable service must
        // answer invalid_request rather than run Git.
        let pingResult = try perform(request: pingRequest, serviceURL: serviceURL)
        guard GitEvidenceXPCOperationStatus(rawValue: pingResult.status) == .invalidRequest else {
            throw FeasibilityScenarioFailure.scenarioFailed(
                .descriptorTransfer,
                reason: "GitEvidenceService ping returned status \(pingResult.status), expected invalid_request"
            )
        }

        let request = try GitEvidenceXPCRequest(
            operation: .listCachedPaths,
            headObjectID: nil,
            repositoryFormatVersion: 0,
            objectHashAlgorithm: .sha1,
            transferredDescriptors: transferredDescriptors
        )

        return try perform(request: request, serviceURL: serviceURL)
    }

    private static func perform(
        request: GitEvidenceXPCRequest,
        serviceURL: URL
    ) throws -> GitEvidenceXPCOperationResult {
        guard try GitEvidenceCodesignValidation.serviceAtURLMatchesRequirement(serviceURL) else {
            throw FeasibilityScenarioFailure.scenarioFailed(
                .descriptorTransfer,
                reason: "embedded GitEvidenceService signature rejected"
            )
        }

        let connection = GitEvidenceXPCConnectionFactory.makeClientConnection(serviceURL: serviceURL)
        connection.resume()

        let semaphore = DispatchSemaphore(value: 0)
        var capturedReply: GitEvidenceXPCReply?
        var capturedError: NSError?

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            capturedError = error as NSError
            semaphore.signal()
        }) as? GitEvidenceXPCProtocol else {
            connection.invalidate()
            throw FeasibilityScenarioFailure.scenarioFailed(
                .descriptorTransfer,
                reason: "unable to create GitEvidenceService proxy"
            )
        }

        proxy.perform(request) { reply, error in
            capturedReply = reply
            capturedError = error
            semaphore.signal()
        }

        semaphore.wait()
        connection.invalidate()

        if let capturedError {
            throw FeasibilityScenarioFailure.scenarioFailed(
                .descriptorTransfer,
                reason: "\(capturedError.domain) \(capturedError.code): \(capturedError.localizedDescription)"
            )
        }

        guard let result = capturedReply?.result else {
            throw FeasibilityScenarioFailure.scenarioFailed(
                .descriptorTransfer,
                reason: "GitEvidenceService returned an empty reply"
            )
        }

        return result
    }
}
