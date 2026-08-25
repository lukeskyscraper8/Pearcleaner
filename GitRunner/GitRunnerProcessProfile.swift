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
    static let writeProbeArgument = GitRunnerInvocation.writeProbeArgument
    static let execProbeArgument = GitRunnerInvocation.execProbeArgument
    static let connectProbeArgument = GitRunnerInvocation.connectProbeArgument
    static let hangProbeArgument = GitRunnerInvocation.hangProbeArgument

    static func runIfRequested(arguments: [String]) -> Bool {
        guard let probe = arguments.first else {
            return false
        }

        switch probe {
        case openProbeArgument:
            return runOpenProbe(arguments: arguments)
        case writeProbeArgument:
            return runWriteProbe(arguments: arguments)
        case execProbeArgument:
            return runExecProbe(arguments: arguments)
        case connectProbeArgument:
            return runConnectProbe(arguments: arguments)
        case hangProbeArgument:
            return runHangProbe()
        default:
            return false
        }
    }

    private static func runOpenProbe(arguments: [String]) -> Bool {
        guard arguments.count == 2 else {
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

    private static func runWriteProbe(arguments: [String]) -> Bool {
        guard arguments.count == 2 else {
            return false
        }

        let path = arguments[1]
        let descriptor = open(path, O_WRONLY | O_CREAT, S_IRUSR | S_IWUSR)
        if descriptor < 0 {
            fputs("probe_write_errno=\(errno)\n", stderr)
            let expectedDenial = errno == EPERM || errno == EACCES || errno == EROFS
            exit(expectedDenial ? 0 : 1)
        }

        close(descriptor)
        fputs("probe_write_errno=0\n", stderr)
        exit(1)
    }

    private static func runExecProbe(arguments: [String]) -> Bool {
        guard arguments.count == 2 else {
            return false
        }

        let path = arguments[1]
        var fileActions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            fputs("probe_exec_errno=\(errno)\n", stderr)
            exit(1)
        }
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
        }

        let devNull = open("/dev/null", O_RDONLY)
        if devNull >= 0 {
            _ = posix_spawn_file_actions_adddup2(&fileActions, devNull, STDIN_FILENO)
            _ = posix_spawn_file_actions_adddup2(&fileActions, devNull, STDOUT_FILENO)
            _ = posix_spawn_file_actions_adddup2(&fileActions, devNull, STDERR_FILENO)
            _ = posix_spawn_file_actions_addclose(&fileActions, devNull)
        }

        let argvStrings = [path]
        let argv = argvStrings.map { string -> UnsafeMutablePointer<CChar> in
            guard let duplicated = strdup(string) else {
                fatalError("GitRunner exec probe argv allocation failed")
            }
            return duplicated
        }
        defer { argv.forEach { free($0) } }
        var argvWithNull = argv.map { Optional($0) }
        argvWithNull.append(nil)

        var spawnedPID: pid_t = 0
        let spawnStatus = argvWithNull.withUnsafeMutableBufferPointer { argvBuffer in
            posix_spawn(&spawnedPID, path, &fileActions, nil, argvBuffer.baseAddress, environ)
        }

        if spawnStatus != 0 {
            fputs("probe_exec_errno=\(spawnStatus)\n", stderr)
            let expectedDenial = spawnStatus == EPERM || spawnStatus == EACCES
            exit(expectedDenial ? 0 : 1)
        }

        var waitStatus: Int32 = 0
        waitpid(spawnedPID, &waitStatus, 0)
        fputs("probe_exec_errno=0\n", stderr)
        exit(1)
    }

    private static func runConnectProbe(arguments: [String]) -> Bool {
        guard arguments.count == 3,
              let port = UInt16(arguments[2]) else {
            return false
        }

        let host = arguments[1]
        var hints = addrinfo(
            ai_flags: AI_NUMERICSERV,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )

        var addressInfo: UnsafeMutablePointer<addrinfo>?
        let lookupStatus = getaddrinfo(host, String(port), &hints, &addressInfo)
        guard lookupStatus == 0, let addressInfo else {
            fputs("probe_connect_errno=\(lookupStatus)\n", stderr)
            exit(lookupStatus == EAI_NONAME || lookupStatus == EAI_FAIL ? 0 : 1)
        }
        defer { freeaddrinfo(addressInfo) }

        let socketDescriptor = socket(addressInfo.pointee.ai_family, addressInfo.pointee.ai_socktype, addressInfo.pointee.ai_protocol)
        if socketDescriptor < 0 {
            fputs("probe_connect_errno=\(errno)\n", stderr)
            let expectedDenial = errno == EPERM || errno == EACCES
            exit(expectedDenial ? 0 : 1)
        }
        defer { close(socketDescriptor) }

        let connectStatus = connect(socketDescriptor, addressInfo.pointee.ai_addr, addressInfo.pointee.ai_addrlen)
        if connectStatus != 0 {
            fputs("probe_connect_errno=\(errno)\n", stderr)
            let expectedDenial = errno == EPERM || errno == EACCES || errno == ENETDOWN
            exit(expectedDenial ? 0 : 1)
        }

        fputs("probe_connect_errno=0\n", stderr)
        exit(1)
    }

    private static func runHangProbe() -> Bool {
        while true {
            sleep(3600)
        }
    }
}
