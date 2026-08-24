import Foundation
import GitEvidenceShared
import Security

enum GitEvidenceXPCClientError: Error, Equatable {
    case embeddedServiceMissing
    case embeddedServiceSignatureRejected
    case remoteProxyUnavailable
    case transportFailed(String)
    case rejectedStatus(GitEvidenceXPCOperationStatus)
    case emptyReply
}

struct GitEvidenceXPCClient: Sendable {
    private let bundle: Bundle
    private let connectionFactory: @Sendable (URL) -> NSXPCConnection

    init(
        bundle: Bundle = .main,
        connectionFactory: @escaping @Sendable (URL) -> NSXPCConnection = GitEvidenceXPCConnectionFactory.makeClientConnection(serviceURL:)
    ) {
        self.bundle = bundle
        self.connectionFactory = connectionFactory
    }

    func validateEmbeddedServiceSignature() throws {
        let serviceURL = try requireEmbeddedServiceURL()
        guard try GitEvidenceCodesignValidation.serviceAtURLMatchesRequirement(serviceURL) else {
            throw GitEvidenceXPCClientError.embeddedServiceSignatureRejected
        }
    }

    func perform(_ request: GitEvidenceXPCRequest) throws -> GitEvidenceXPCOperationResult {
        try validateEmbeddedServiceSignature()

        let serviceURL = try requireEmbeddedServiceURL()
        let connection = connectionFactory(serviceURL)
        connection.resume()

        let semaphore = DispatchSemaphore(value: 0)
        var capturedReply: GitEvidenceXPCReply?
        var capturedError: NSError?

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            capturedError = error as NSError
            semaphore.signal()
        }) as? GitEvidenceXPCProtocol else {
            connection.invalidate()
            throw GitEvidenceXPCClientError.remoteProxyUnavailable
        }

        proxy.perform(request) { reply, error in
            capturedReply = reply
            capturedError = error
            semaphore.signal()
        }

        semaphore.wait()
        connection.invalidate()

        if let capturedError {
            throw GitEvidenceXPCClientError.transportFailed(capturedError.localizedDescription)
        }

        guard let result = capturedReply?.result else {
            throw GitEvidenceXPCClientError.emptyReply
        }

        guard let status = GitEvidenceXPCOperationStatus(rawValue: result.status) else {
            throw GitEvidenceXPCClientError.emptyReply
        }

        guard status == .accepted else {
            throw GitEvidenceXPCClientError.rejectedStatus(status)
        }

        return result
    }

    private func requireEmbeddedServiceURL() throws -> URL {
        guard let serviceURL = GitEvidenceXPCConnectionFactory.embeddedServiceURL(in: bundle),
              FileManager.default.fileExists(atPath: serviceURL.path) else {
            throw GitEvidenceXPCClientError.embeddedServiceMissing
        }
        return serviceURL
    }
}
