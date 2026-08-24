import Darwin
import Foundation
import GitEvidenceShared
import Security

public enum GitRunnerError: Error, Sendable, Equatable {
    case emptyGitArguments
    case invalidGitLaunchPath
    case invalidFileDescriptorList
    case fileDescriptorOperationFailed(Int32)
    case missingRequiredEnvironment(String)
    case disallowedEnvironmentKey(String)
    case signatureVerificationFailed(String)
    case execTransitionFailed(Int32)

    var message: String {
        switch self {
        case .emptyGitArguments:
            "GitRunner requires at least one Git argument"
        case .invalidGitLaunchPath:
            "Git launch path must be the fixed system path"
        case .invalidFileDescriptorList:
            "Invalid GitRunner file-descriptor allowlist"
        case let .fileDescriptorOperationFailed(fd):
            "File-descriptor operation failed for fd \(fd): \(String(cString: strerror(errno)))"
        case let .missingRequiredEnvironment(key):
            "Missing required GitRunner environment key: \(key)"
        case let .disallowedEnvironmentKey(key):
            "Disallowed GitRunner environment key: \(key)"
        case let .signatureVerificationFailed(reason):
            "Apple Git signature verification failed: \(reason)"
        case let .execTransitionFailed(code):
            "exec transition to /usr/bin/git failed with errno \(code)"
        }
    }

    var exitCode: Int32 {
        switch self {
        case .signatureVerificationFailed:
            79
        case .execTransitionFailed:
            80
        default:
            78
        }
    }

    init(policyError: GitRunnerPolicyError) {
        switch policyError {
        case .invalidFileDescriptorList:
            self = .invalidFileDescriptorList
        case let .missingRequiredEnvironment(key):
            self = .missingRequiredEnvironment(key)
        case let .disallowedEnvironmentKey(key):
            self = .disallowedEnvironmentKey(key)
        }
    }
}

public struct GitRunnerProcessProfile: Sendable, Equatable {
    public static let version: String = GitRunnerInvocation.version
    public static let gitLaunchPath: String = GitRunnerInvocation.gitLaunchPath

    public static let metadataFileDescriptorsEnvironmentKey = GitRunnerInvocation.metadataFileDescriptorsEnvironmentKey
    public static let pipeFileDescriptorsEnvironmentKey = GitRunnerInvocation.pipeFileDescriptorsEnvironmentKey

    public let version: String
    public let inheritSandbox: Bool

    public init(
        version: String = Self.version,
        inheritSandbox: Bool = true
    ) {
        self.version = version
        self.inheritSandbox = inheritSandbox
    }

    public static func executeGitTransition(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Never {
        guard !arguments.isEmpty else {
            throw GitRunnerError.emptyGitArguments
        }

        try verifyLaunchPathIsFixedSystemGit()
        try GitRunnerSignatureVerifier.verifyAppleSignedGit(at: gitLaunchPath)

        let metadataDescriptors: [Int32]
        do {
            metadataDescriptors = try GitRunnerEnvironmentPolicy.parseFileDescriptorList(
                environment[metadataFileDescriptorsEnvironmentKey]
            )
        } catch let policyError as GitRunnerPolicyError {
            throw GitRunnerError(policyError: policyError)
        }

        let pipeDescriptors: [Int32]
        do {
            pipeDescriptors = try resolvedPipeDescriptors(
                from: environment[pipeFileDescriptorsEnvironmentKey]
            )
        } catch let policyError as GitRunnerPolicyError {
            throw GitRunnerError(policyError: policyError)
        }

        let sanitizedEnvironment: [String: String]
        do {
            sanitizedEnvironment = try GitRunnerEnvironmentPolicy.sanitizedGitEnvironment(from: environment)
        } catch let policyError as GitRunnerPolicyError {
            throw GitRunnerError(policyError: policyError)
        }

        let preservedDescriptors = Set(metadataDescriptors + pipeDescriptors)

        closeDescriptorsExcept(allowed: preservedDescriptors)
        try clearCloseOnExec(for: Array(preservedDescriptors).sorted())

        let argvStrings = [gitLaunchPath] + arguments
        let envStrings = sanitizedEnvironment
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }

        let argv = argvStrings.map { string -> UnsafeMutablePointer<CChar> in
            guard let duplicated = strdup(string) else {
                fatalError("GitRunner argv allocation failed")
            }
            return duplicated
        }
        defer { argv.forEach { free($0) } }

        let envp = envStrings.map { string -> UnsafeMutablePointer<CChar> in
            guard let duplicated = strdup(string) else {
                fatalError("GitRunner envp allocation failed")
            }
            return duplicated
        }
        defer { envp.forEach { free($0) } }

        var argvWithNull = argv.map { Optional($0) }
        argvWithNull.append(nil)
        var envpWithNull = envp.map { Optional($0) }
        envpWithNull.append(nil)

        _ = argvWithNull.withUnsafeMutableBufferPointer { argvBuffer in
            envpWithNull.withUnsafeMutableBufferPointer { envpBuffer in
                execve(gitLaunchPath, argvBuffer.baseAddress, envpBuffer.baseAddress)
            }
        }

        throw GitRunnerError.execTransitionFailed(errno)
    }

    public static func clearCloseOnExec(for descriptors: [Int32]) throws {
        for descriptor in descriptors {
            let flags = fcntl(descriptor, F_GETFD)
            guard flags >= 0 else {
                throw GitRunnerError.fileDescriptorOperationFailed(descriptor)
            }
            guard fcntl(descriptor, F_SETFD, flags & ~FD_CLOEXEC) >= 0 else {
                throw GitRunnerError.fileDescriptorOperationFailed(descriptor)
            }
        }
    }

    public static func closeDescriptorsExcept(allowed: Set<Int32>, through highest: Int32 = 1023) {
        guard highest >= 3 else {
            return
        }

        for descriptor in 3...highest where !allowed.contains(descriptor) {
            _ = close(descriptor)
        }
    }

    static func resolvedPipeDescriptors(from rawValue: String?) throws -> [Int32] {
        let configured = try GitRunnerEnvironmentPolicy.parseFileDescriptorList(rawValue)
        if configured.isEmpty {
            return [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO]
        }
        return configured
    }

    static func verifyLaunchPathIsFixedSystemGit() throws {
        guard gitLaunchPath == "/usr/bin/git" else {
            throw GitRunnerError.invalidGitLaunchPath
        }
    }
}

enum GitRunnerSignatureVerifier {
    private static let appleAnchorRequirement = "anchor apple"

    static func verifyAppleSignedGit(at launchPath: String) throws {
        guard launchPath == GitRunnerProcessProfile.gitLaunchPath else {
            throw GitRunnerError.invalidGitLaunchPath
        }

        let launchURL = URL(fileURLWithPath: launchPath, isDirectory: false)
        try verifyStaticCode(at: launchURL, label: launchPath)

        let fileManager = FileManager.default
        var resolvedURL = launchURL
        if let destination = try? fileManager.destinationOfSymbolicLink(atPath: launchPath) {
            if destination.hasPrefix("/") {
                resolvedURL = URL(fileURLWithPath: destination, isDirectory: false)
            } else {
                resolvedURL = launchURL.deletingLastPathComponent().appendingPathComponent(destination)
            }
            if resolvedURL.path != launchURL.path {
                try verifyStaticCode(at: resolvedURL, label: resolvedURL.path)
            }
        }
    }

    private static func verifyStaticCode(at url: URL, label: String) throws {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else {
            throw GitRunnerError.signatureVerificationFailed("unable to create static code for \(label) (\(createStatus))")
        }

        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(
            appleAnchorRequirement as CFString,
            SecCSFlags(rawValue: 0),
            &requirement
        )
        guard requirementStatus == errSecSuccess, let requirement else {
            throw GitRunnerError.signatureVerificationFailed("unable to create Apple anchor requirement (\(requirementStatus))")
        }

        let validityStatus = SecStaticCodeCheckValidity(code, [], requirement)
        guard validityStatus == errSecSuccess else {
            throw GitRunnerError.signatureVerificationFailed("validity check failed for \(label) (\(validityStatus))")
        }
    }
}

enum GitRunnerHarnessProbe {
    static let openProbeArgument = GitRunnerInvocation.openProbeArgument

    static func runIfRequested(arguments: [String]) -> Bool {
        guard arguments.count == 2, arguments[0] == openProbeArgument else {
            return false
        }

        let path = arguments[1]
        let descriptor = open(path, O_RDONLY)
        if descriptor < 0 {
            fputs("probe_open_errno=\(errno)\n", stderr)
            let expectedDenial = errno == EPERM || errno == EACCES || errno == ENOENT
            exit(expectedDenial ? 0 : 1)
        }

        close(descriptor)
        fputs("probe_open_errno=0\n", stderr)
        exit(1)
    }
}
