import Darwin
import Foundation
import GitEvidenceShared

enum GitSyntheticAdminViewError: Error, Sendable, Equatable {
    case missingIndexDescriptor
    case duplicateRole(GitEvidenceXPCDescriptorRole)
    case unknownDescriptorRole(String)
    case missingObjectID(GitEvidenceXPCDescriptorRole)
    case invalidObjectID(String)
    case headObjectIDMismatch
    case filesystemFailure(String)
}

struct GitSyntheticAdminView: Sendable {
    let environment: [String: String]
    let metadataFileDescriptors: [Int32]

    private let gitDirectoryURL: URL
    private let workTreeURL: URL
    private let rootTemporaryURL: URL

    static func build(
        serviceHome: URL,
        serviceTemporaryDirectory: URL,
        repositoryFormatVersion: Int32,
        objectHashAlgorithm: GitEvidenceXPCObjectHashAlgorithm,
        headObjectID: GitEvidenceXPCObjectID?,
        transferredDescriptors: [GitEvidenceXPCTransferredDescriptor]
    ) throws -> GitSyntheticAdminView {
        if let headObjectID {
            guard GitEvidenceXPCObjectHashAlgorithm(rawValue: headObjectID.algorithm) == objectHashAlgorithm else {
                throw GitSyntheticAdminViewError.headObjectIDMismatch
            }
            try validateObjectIDHex(headObjectID.hex, algorithm: objectHashAlgorithm)
        }

        let fileManager = FileManager.default
        let rootTemporaryURL = serviceTemporaryDirectory
            .appendingPathComponent("synthetic-admin-\(UUID().uuidString)", isDirectory: true)
        let gitDirectoryURL = rootTemporaryURL.appendingPathComponent("git", isDirectory: true)
        let workTreeURL = rootTemporaryURL.appendingPathComponent("worktree", isDirectory: true)
        let objectsDirectoryURL = gitDirectoryURL.appendingPathComponent("objects", isDirectory: true)
        let packDirectoryURL = objectsDirectoryURL.appendingPathComponent("pack", isDirectory: true)

        try fileManager.createDirectory(at: gitDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: workTreeURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: objectsDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: packDirectoryURL, withIntermediateDirectories: true)

        let configBody = makeConfig(
            repositoryFormatVersion: repositoryFormatVersion,
            objectHashAlgorithm: objectHashAlgorithm
        )
        try configBody.write(
            to: gitDirectoryURL.appendingPathComponent("config"),
            atomically: true,
            encoding: .utf8
        )
        try "\(headObjectID?.hex ?? placeholderHeadHex(algorithm: objectHashAlgorithm))\n".write(
            to: gitDirectoryURL.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )

        var indexDescriptor: Int32?
        var seenRoles: Set<GitEvidenceXPCDescriptorRole> = []
        var metadataDescriptors: [Int32] = []

        for transferred in transferredDescriptors {
            guard let role = GitEvidenceXPCDescriptorRole(rawValue: transferred.record.role) else {
                throw GitSyntheticAdminViewError.unknownDescriptorRole(transferred.record.role)
            }

            if role == .index {
                if indexDescriptor != nil {
                    throw GitSyntheticAdminViewError.duplicateRole(.index)
                }
                let descriptor = transferred.fileHandle.fileDescriptor
                indexDescriptor = descriptor
                metadataDescriptors.append(descriptor)
                continue
            }

            if role == .sharedIndex {
                if seenRoles.contains(role) {
                    throw GitSyntheticAdminViewError.duplicateRole(role)
                }
                seenRoles.insert(role)
            }

            let descriptor = transferred.fileHandle.fileDescriptor
            let symlinkURL = try objectSymlinkURL(
                for: role,
                record: transferred.record,
                objectHashAlgorithm: objectHashAlgorithm,
                objectsDirectoryURL: objectsDirectoryURL,
                packDirectoryURL: packDirectoryURL
            )
            try createFileDescriptorSymlink(at: symlinkURL, fileDescriptor: descriptor)
            metadataDescriptors.append(descriptor)
        }

        guard let indexDescriptor else {
            throw GitSyntheticAdminViewError.missingIndexDescriptor
        }

        let deduplicatedMetadataDescriptors = deduplicatedPreservingOrder(metadataDescriptors)
        var environment = GitRunnerEnvironmentPolicy.fixedGitEnvironmentValues
        environment["HOME"] = serviceHome.path
        environment["TMPDIR"] = serviceTemporaryDirectory.path
        environment["GIT_DIR"] = gitDirectoryURL.path
        environment["GIT_WORK_TREE"] = workTreeURL.path
        environment["GIT_INDEX_FILE"] = fileDescriptorPath(indexDescriptor)
        environment["GIT_OBJECT_DIRECTORY"] = objectsDirectoryURL.path

        return GitSyntheticAdminView(
            environment: environment,
            metadataFileDescriptors: deduplicatedMetadataDescriptors,
            gitDirectoryURL: gitDirectoryURL,
            workTreeURL: workTreeURL,
            rootTemporaryURL: rootTemporaryURL
        )
    }

    func destroy() {
        try? FileManager.default.removeItem(at: rootTemporaryURL)
    }

    private static func placeholderHeadHex(algorithm: GitEvidenceXPCObjectHashAlgorithm) -> String {
        String(repeating: "0", count: algorithm == .sha256 ? 64 : 40)
    }

    private static func makeConfig(
        repositoryFormatVersion: Int32,
        objectHashAlgorithm: GitEvidenceXPCObjectHashAlgorithm
    ) -> String {
        var lines = [
            "[core]",
            "\trepositoryformatversion = \(repositoryFormatVersion)",
        ]
        if objectHashAlgorithm == .sha256 {
            lines.append("\tobjectformat = sha256")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func objectSymlinkURL(
        for role: GitEvidenceXPCDescriptorRole,
        record: GitEvidenceXPCDescriptorRecord,
        objectHashAlgorithm: GitEvidenceXPCObjectHashAlgorithm,
        objectsDirectoryURL: URL,
        packDirectoryURL: URL
    ) throws -> URL {
        guard let objectID = record.objectID else {
            throw GitSyntheticAdminViewError.missingObjectID(role)
        }
        guard GitEvidenceXPCObjectHashAlgorithm(rawValue: objectID.algorithm) == objectHashAlgorithm else {
            throw GitSyntheticAdminViewError.invalidObjectID(objectID.hex)
        }
        try validateObjectIDHex(objectID.hex, algorithm: objectHashAlgorithm)

        switch role {
        case .index:
            throw GitSyntheticAdminViewError.duplicateRole(.index)
        case .looseObject:
            let prefix = objectID.hex.prefix(2)
            let suffix = objectID.hex.dropFirst(2)
            return objectsDirectoryURL
                .appendingPathComponent(String(prefix), isDirectory: true)
                .appendingPathComponent(String(suffix), isDirectory: false)
        case .packIndex:
            return packDirectoryURL.appendingPathComponent("pack-\(objectID.hex).idx", isDirectory: false)
        case .packData:
            return packDirectoryURL.appendingPathComponent("pack-\(objectID.hex).pack", isDirectory: false)
        case .packReverseIndex:
            return packDirectoryURL.appendingPathComponent("pack-\(objectID.hex).rev", isDirectory: false)
        case .sharedIndex:
            return packDirectoryURL.appendingPathComponent("sharedindex.\(objectID.hex)", isDirectory: false)
        }
    }

    private static func validateObjectIDHex(
        _ hex: String,
        algorithm: GitEvidenceXPCObjectHashAlgorithm
    ) throws {
        let expectedLength = algorithm == .sha256 ? 64 : 40
        guard hex.count == expectedLength,
              hex.allSatisfy({ $0.isHexDigit }) else {
            throw GitSyntheticAdminViewError.invalidObjectID(hex)
        }
    }

    private static func fileDescriptorPath(_ fileDescriptor: Int32) -> String {
        "/dev/fd/\(fileDescriptor)"
    }

    private static func createFileDescriptorSymlink(at url: URL, fileDescriptor: Int32) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }

        let linkTarget = fileDescriptorPath(fileDescriptor)
        guard symlink(linkTarget, url.path) == 0 else {
            throw GitSyntheticAdminViewError.filesystemFailure(
                "unable to create symlink at \(url.path): \(String(cString: strerror(errno)))"
            )
        }
    }

    private static func deduplicatedPreservingOrder(_ descriptors: [Int32]) -> [Int32] {
        var seen: Set<Int32> = []
        var result: [Int32] = []
        for descriptor in descriptors where seen.insert(descriptor).inserted {
            result.append(descriptor)
        }
        return result
    }
}
