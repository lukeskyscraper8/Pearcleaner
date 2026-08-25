import Darwin
import Foundation
import GitEvidenceShared

enum GitOperationsScenarioSupport {
    struct RepositoryHandles {
        let rootURL: URL
        let headObjectID: GitEvidenceXPCObjectID
        let blobObjectID: GitEvidenceXPCObjectID
        let transferredDescriptors: [GitEvidenceXPCTransferredDescriptor]
        let openDescriptors: [Int32]
    }

    static func embeddedServiceURL(bundle: Bundle = .main) throws -> URL {
        guard let serviceURL = GitEvidenceXPCConnectionFactory.embeddedServiceURL(in: bundle),
              FileManager.default.fileExists(atPath: serviceURL.path) else {
            throw FeasibilityScenarioFailure.scenarioFailed(
                .lsFilesOperation,
                reason: "embedded GitEvidenceService.xpc is missing from the harness bundle"
            )
        }
        return serviceURL
    }

    static func prepareRepository() throws -> RepositoryHandles {
        let rootURL = try copyMinimalFixtureRepository()
        defer { }

        let gitDirectory = rootURL.appendingPathComponent(".git")
        let headHex = try readHEAD(from: gitDirectory)
        let headObjectID = GitEvidenceXPCObjectID(algorithm: .sha1, hex: headHex)
        let blobHex = try resolveBlobOID(in: gitDirectory, headHex: headHex)
        let blobObjectID = GitEvidenceXPCObjectID(algorithm: .sha1, hex: blobHex)

        var openDescriptors: [Int32] = []
        var transferred: [GitEvidenceXPCTransferredDescriptor] = []

        let indexPath = gitDirectory.appendingPathComponent("index")
        let indexDescriptor = try openReadOnlyDescriptor(for: indexPath)
        openDescriptors.append(indexDescriptor)
        transferred.append(
            try makeTransferredDescriptor(
                role: .index,
                path: indexPath,
                descriptor: indexDescriptor
            )
        )

        let objectsDirectory = gitDirectory.appendingPathComponent("objects")
        let objectPaths = try looseObjectPaths(in: objectsDirectory)
        for objectPath in objectPaths {
            let descriptor = try openReadOnlyDescriptor(for: objectPath)
            openDescriptors.append(descriptor)
            let hex = looseObjectHex(from: objectPath)
            transferred.append(
                try makeTransferredDescriptor(
                    role: .looseObject,
                    path: objectPath,
                    descriptor: descriptor,
                    objectID: GitEvidenceXPCObjectID(algorithm: .sha1, hex: hex)
                )
            )
        }

        return RepositoryHandles(
            rootURL: rootURL,
            headObjectID: headObjectID,
            blobObjectID: blobObjectID,
            transferredDescriptors: transferred,
            openDescriptors: openDescriptors
        )
    }

    static func perform(
        request: GitEvidenceXPCRequest,
        serviceURL: URL
    ) throws -> GitEvidenceXPCOperationResult {
        guard try GitEvidenceCodesignValidation.serviceAtURLMatchesRequirement(serviceURL) else {
            throw FeasibilityScenarioFailure.scenarioFailed(
                .lsFilesOperation,
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
                .lsFilesOperation,
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
                .lsFilesOperation,
                reason: capturedError.localizedDescription
            )
        }

        guard let result = capturedReply?.result else {
            throw FeasibilityScenarioFailure.scenarioFailed(
                .lsFilesOperation,
                reason: "GitEvidenceService returned an empty reply"
            )
        }

        return result
    }

    static func closeDescriptors(_ descriptors: [Int32]) {
        for descriptor in descriptors {
            close(descriptor)
        }
    }

    private static func copyMinimalFixtureRepository() throws -> URL {
        guard let archiveURL = Bundle.main.url(
            forResource: "minimal-repo-fixture",
            withExtension: "json"
        ) else {
            throw FeasibilityScenarioFailure.scenarioFailed(
                .lsFilesOperation,
                reason: "minimal-repo fixture archive is unavailable in the harness bundle"
            )
        }

        let data = try Data(contentsOf: archiveURL)
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw FeasibilityScenarioFailure.scenarioFailed(
                .lsFilesOperation,
                reason: "minimal-repo fixture archive is malformed"
            )
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-operations-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        for (relativePath, encoded) in payload {
            guard let fileData = Data(base64Encoded: encoded) else {
                throw FeasibilityScenarioFailure.scenarioFailed(
                    .lsFilesOperation,
                    reason: "minimal-repo fixture entry \(relativePath) is invalid"
                )
            }
            let outputURL = destination.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileData.write(to: outputURL, options: .atomic)
        }

        let extractedDotGit = destination.appendingPathComponent("dot-git")
        let destinationDotGit = destination.appendingPathComponent(".git")
        try FileManager.default.moveItem(at: extractedDotGit, to: destinationDotGit)
        return destination
    }

    private static func readHEAD(from gitDirectory: URL) throws -> String {
        let headURL = gitDirectory.appendingPathComponent("HEAD")
        let headContents = try String(contentsOf: headURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if headContents.hasPrefix("ref: ") {
            let refPath = String(headContents.dropFirst(5))
            let refURL = gitDirectory.appendingPathComponent(refPath)
            return try String(contentsOf: refURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return headContents
    }

    private static func resolveBlobOID(in gitDirectory: URL, headHex: String) throws -> String {
        _ = headHex
        let objectsDirectory = gitDirectory.appendingPathComponent("objects")
        let objectPaths = try looseObjectPaths(in: objectsDirectory)
        if let blobPath = objectPaths.first(where: { looseObjectHex(from: $0).hasPrefix("ca79a9db") }) {
            return looseObjectHex(from: blobPath)
        }

        throw FeasibilityScenarioFailure.scenarioFailed(
            .catFileBatchOperation,
            reason: "fixture repository has no blob objects"
        )
    }

    private static func looseObjectPaths(in objectsDirectory: URL) throws -> [URL] {
        let fileManager = FileManager.default
        var paths: [URL] = []
        let prefixEntries = try fileManager.contentsOfDirectory(
            at: objectsDirectory,
            includingPropertiesForKeys: nil
        )
        for prefixEntry in prefixEntries where prefixEntry.hasDirectoryPath {
            let suffixEntries = try fileManager.contentsOfDirectory(
                at: prefixEntry,
                includingPropertiesForKeys: nil
            )
            paths.append(contentsOf: suffixEntries.filter { !$0.hasDirectoryPath })
        }
        return paths.sorted { $0.path < $1.path }
    }

    private static func looseObjectHex(from objectPath: URL) -> String {
        let prefix = objectPath.deletingLastPathComponent().lastPathComponent
        let suffix = objectPath.lastPathComponent
        return prefix + suffix
    }

    private static func openReadOnlyDescriptor(for url: URL) throws -> Int32 {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw FeasibilityScenarioFailure.scenarioFailed(
                .lsFilesOperation,
                reason: "unable to open \(url.lastPathComponent): \(String(cString: strerror(errno)))"
            )
        }
        return descriptor
    }

    private static func makeTransferredDescriptor(
        role: GitEvidenceXPCDescriptorRole,
        path: URL,
        descriptor: Int32,
        objectID: GitEvidenceXPCObjectID? = nil
    ) throws -> GitEvidenceXPCTransferredDescriptor {
        var statBuffer = stat()
        guard fstat(descriptor, &statBuffer) == 0 else {
            throw FeasibilityScenarioFailure.scenarioFailed(
                .lsFilesOperation,
                reason: "unable to stat \(path.lastPathComponent)"
            )
        }

        return GitEvidenceXPCTransferredDescriptor(
            record: GitEvidenceXPCDescriptorRecord(
                role: role,
                identity: GitEvidenceXPCFileIdentity(statBuffer: statBuffer),
                objectID: objectID
            ),
            fileHandle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        )
    }
}
