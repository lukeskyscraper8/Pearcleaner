import Darwin
import Foundation
import GitEvidenceShared

enum GitOperationTerminationReason: Sendable, Equatable {
    case exited
    case timedOut
    case outputLimitExceeded
    case signal
}

struct GitOperationResult: Sendable, Equatable {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
    let terminationReason: GitOperationTerminationReason

    init(
        exitCode: Int32,
        stdout: Data,
        stderr: Data,
        terminationReason: GitOperationTerminationReason
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.terminationReason = terminationReason
    }
}

enum GitOperationSupervisorError: Error, Sendable, Equatable {
    case pipeCreationFailed
    case spawnFailed(Int32)
    case invalidOperationParameters(String)
}

enum GitOperationSupervisor {
    static let timeoutSeconds: TimeInterval = 30
    static let killEscalationMilliseconds: UInt64 = 500

    static func run(
        operation: GitEvidenceXPCOperation,
        runnerExecutableURL: URL,
        adminView: GitSyntheticAdminView,
        headObjectHex: String? = nil,
        catFileObjectIDs: [String] = [],
        blobPipeWriteFD: Int32? = nil,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) throws -> GitOperationResult {
        let gitArguments = try makeGitArguments(
            operation: operation,
            headObjectHex: headObjectHex
        )

        var stdoutPipe: [Int32] = [0, 0]
        var stderrPipe: [Int32] = [0, 0]
        guard pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
            throw GitOperationSupervisorError.pipeCreationFailed
        }

        let stdoutRead = stdoutPipe[0]
        let stdoutWrite = stdoutPipe[1]
        let stderrRead = stderrPipe[0]
        let stderrWrite = stderrPipe[1]

        _ = fcntl(stdoutRead, F_SETFD, FD_CLOEXEC)
        _ = fcntl(stderrRead, F_SETFD, FD_CLOEXEC)

        var stdinRead: Int32 = -1
        var stdinWrite: Int32 = -1
        let stdinPayload: Data?
        if operation == .catFileBatch {
            stdinPayload = Data(catFileObjectIDs.map { $0 + "\n" }.joined().utf8)
            var stdinPipe: [Int32] = [0, 0]
            guard pipe(&stdinPipe) == 0 else {
                close(stdoutRead)
                close(stdoutWrite)
                close(stderrRead)
                close(stderrWrite)
                throw GitOperationSupervisorError.pipeCreationFailed
            }
            stdinRead = stdinPipe[0]
            stdinWrite = stdinPipe[1]
            _ = fcntl(stdinRead, F_SETFD, FD_CLOEXEC)
        } else {
            stdinPayload = nil
        }

        for descriptor in adminView.metadataFileDescriptors {
            let flags = fcntl(descriptor, F_GETFD)
            if flags >= 0 {
                _ = fcntl(descriptor, F_SETFD, flags & ~FD_CLOEXEC)
            }
        }

        var fileActions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            closeSpawnPipes(
                stdoutRead: stdoutRead,
                stdoutWrite: stdoutWrite,
                stderrRead: stderrRead,
                stderrWrite: stderrWrite,
                stdinRead: stdinRead,
                stdinWrite: stdinWrite
            )
            throw GitOperationSupervisorError.spawnFailed(errno)
        }
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
        }

        if stdinRead >= 0 {
            _ = posix_spawn_file_actions_adddup2(&fileActions, stdinRead, STDIN_FILENO)
            _ = posix_spawn_file_actions_addclose(&fileActions, stdinWrite)
        } else {
            let devNull = open("/dev/null", O_RDONLY)
            if devNull >= 0 {
                _ = posix_spawn_file_actions_adddup2(&fileActions, devNull, STDIN_FILENO)
                _ = posix_spawn_file_actions_addclose(&fileActions, devNull)
            }
        }

        _ = posix_spawn_file_actions_adddup2(&fileActions, stdoutWrite, STDOUT_FILENO)
        _ = posix_spawn_file_actions_adddup2(&fileActions, stderrWrite, STDERR_FILENO)
        _ = posix_spawn_file_actions_addclose(&fileActions, stdoutRead)
        _ = posix_spawn_file_actions_addclose(&fileActions, stdoutWrite)
        _ = posix_spawn_file_actions_addclose(&fileActions, stderrRead)
        _ = posix_spawn_file_actions_addclose(&fileActions, stderrWrite)

        for descriptor in adminView.metadataFileDescriptors {
            _ = posix_spawn_file_actions_addinherit_np(&fileActions, descriptor)
        }

        var environment = adminView.environment
        environment[GitRunnerInvocation.metadataFileDescriptorsEnvironmentKey] =
            adminView.metadataFileDescriptors.map(String.init).joined(separator: ",")
        environment[GitRunnerInvocation.pipeFileDescriptorsEnvironmentKey] = "0,1,2"

        var spawnAttributes: posix_spawnattr_t? = nil
        guard posix_spawnattr_init(&spawnAttributes) == 0 else {
            closeSpawnPipes(
                stdoutRead: stdoutRead,
                stdoutWrite: stdoutWrite,
                stderrRead: stderrRead,
                stderrWrite: stderrWrite,
                stdinRead: stdinRead,
                stdinWrite: stdinWrite
            )
            throw GitOperationSupervisorError.spawnFailed(errno)
        }
        defer {
            posix_spawnattr_destroy(&spawnAttributes)
        }

        let spawnFlags = Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP)
        guard posix_spawnattr_setflags(&spawnAttributes, spawnFlags) == 0,
              posix_spawnattr_setpgroup(&spawnAttributes, 0) == 0 else {
            closeSpawnPipes(
                stdoutRead: stdoutRead,
                stdoutWrite: stdoutWrite,
                stderrRead: stderrRead,
                stderrWrite: stderrWrite,
                stdinRead: stdinRead,
                stdinWrite: stdinWrite
            )
            throw GitOperationSupervisorError.spawnFailed(errno)
        }

        let argvStrings = [runnerExecutableURL.path] + gitArguments
        let argv = argvStrings.map { string -> UnsafeMutablePointer<CChar> in
            guard let duplicated = strdup(string) else {
                fatalError("GitOperationSupervisor argv allocation failed")
            }
            return duplicated
        }
        defer { argv.forEach { free($0) } }
        var argvWithNull = argv.map { Optional($0) }
        argvWithNull.append(nil)

        let envpStrings = environment.map { "\($0.key)=\($0.value)" }.sorted()
        let envp = envpStrings.map { string -> UnsafeMutablePointer<CChar> in
            guard let duplicated = strdup(string) else {
                fatalError("GitOperationSupervisor envp allocation failed")
            }
            return duplicated
        }
        defer { envp.forEach { free($0) } }
        var envpWithNull = envp.map { Optional($0) }
        envpWithNull.append(nil)

        var spawnedPID: pid_t = 0
        let spawnStatus: Int32 = argvWithNull.withUnsafeMutableBufferPointer { argvBuffer in
            envpWithNull.withUnsafeMutableBufferPointer { envpBuffer in
                posix_spawn(
                    &spawnedPID,
                    runnerExecutableURL.path,
                    &fileActions,
                    &spawnAttributes,
                    argvBuffer.baseAddress,
                    envpBuffer.baseAddress
                )
            }
        }

        guard spawnStatus == 0 else {
            closeSpawnPipes(
                stdoutRead: stdoutRead,
                stdoutWrite: stdoutWrite,
                stderrRead: stderrRead,
                stderrWrite: stderrWrite,
                stdinRead: stdinRead,
                stdinWrite: stdinWrite
            )
            throw GitOperationSupervisorError.spawnFailed(spawnStatus)
        }

        close(stdoutWrite)
        close(stderrWrite)

        if let stdinPayload, stdinWrite >= 0 {
            writeAll(stdinPayload, to: stdinWrite)
            close(stdinWrite)
        }
        if stdinRead >= 0 {
            close(stdinRead)
        }

        let pid = spawnedPID
        let processGroupID = pid

        let collector = OutputCollector(limit: GitEvidenceXPCLimits.maxCombinedOutputBytes)
        let drainGroup = DispatchGroup()
        let shouldStop = StopFlag()

        drainGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { drainGroup.leave() }
            if operation == .catFileBatch {
                drainCatFileStdout(
                    from: stdoutRead,
                    blobPipeWriteFD: blobPipeWriteFD,
                    collector: collector,
                    shouldStop: shouldStop
                )
            } else {
                drainSimpleOutput(from: stdoutRead, into: collector.appendStdout, shouldStop: shouldStop)
            }
            close(stdoutRead)
        }

        drainGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { drainGroup.leave() }
            drainSimpleOutput(from: stderrRead, into: collector.appendStderr, shouldStop: shouldStop)
            close(stderrRead)
        }

        var terminationReason: GitOperationTerminationReason = .exited
        var forcedTermination = false

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var waitStatus: Int32 = 0

        while true {
            if shouldCancel() {
                terminationReason = .timedOut
                forcedTermination = true
                break
            }

            if collector.limitExceeded {
                terminationReason = .outputLimitExceeded
                forcedTermination = true
                break
            }

            let waitResult = waitpid(pid, &waitStatus, WNOHANG)
            if waitResult == pid {
                break
            }
            if waitResult < 0 && errno != EINTR {
                break
            }

            if Date() >= deadline {
                terminationReason = .timedOut
                forcedTermination = true
                break
            }

            usleep(10_000)
        }

        if forcedTermination {
            shouldStop.stop()
            terminateProcessGroup(processGroupID)
            _ = waitpid(pid, &waitStatus, 0)
        }

        drainGroup.wait()

        if !forcedTermination {
            if collector.limitExceeded {
                terminationReason = .outputLimitExceeded
            } else if (waitStatus & 0x7F) != 0 {
                terminationReason = .signal
            } else {
                terminationReason = .exited
            }
        }

        let exitCode: Int32
        if (waitStatus & 0x7F) == 0 {
            exitCode = (waitStatus >> 8) & 0xFF
        } else {
            exitCode = 128 + (waitStatus & 0x7F)
        }

        return GitOperationResult(
            exitCode: exitCode,
            stdout: collector.stdout,
            stderr: collector.stderr,
            terminationReason: terminationReason
        )
    }

    private static func makeGitArguments(
        operation: GitEvidenceXPCOperation,
        headObjectHex: String?
    ) throws -> [String] {
        var arguments = GitEvidenceGitCommand.fixedConfigurationPrelude
        switch operation {
        case .listCachedPaths:
            arguments += ["ls-files", "--cached", "-z"]
        case .listHeadTreePaths:
            guard let headObjectHex, !headObjectHex.isEmpty else {
                throw GitOperationSupervisorError.invalidOperationParameters(
                    "listHeadTreePaths requires a resolved HEAD object ID"
                )
            }
            arguments += ["ls-tree", "-r", "-z", headObjectHex]
        case .catFileBatch:
            arguments += ["cat-file", "--batch"]
        }
        return arguments
    }

    private static func terminateProcessGroup(_ processGroupID: pid_t) {
        _ = kill(-processGroupID, SIGTERM)
        usleep(useconds_t(killEscalationMilliseconds * 1_000))
        _ = kill(-processGroupID, SIGKILL)
    }

    private static func closeSpawnPipes(
        stdoutRead: Int32,
        stdoutWrite: Int32,
        stderrRead: Int32,
        stderrWrite: Int32,
        stdinRead: Int32,
        stdinWrite: Int32
    ) {
        if stdoutRead >= 0 { close(stdoutRead) }
        if stdoutWrite >= 0 { close(stdoutWrite) }
        if stderrRead >= 0 { close(stderrRead) }
        if stderrWrite >= 0 { close(stderrWrite) }
        if stdinRead >= 0 { close(stdinRead) }
        if stdinWrite >= 0 { close(stdinWrite) }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            var offset = 0
            while offset < rawBuffer.count {
                let wrote = write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if wrote <= 0 {
                    break
                }
                offset += wrote
            }
        }
    }

    private static func drainSimpleOutput(
        from descriptor: Int32,
        into append: (Data) -> Bool,
        shouldStop: StopFlag
    ) {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while !shouldStop.isStopped {
            let readCount = buffer.withUnsafeMutableBytes { rawBuffer in
                read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if readCount <= 0 {
                break
            }
            if !append(Data(buffer.prefix(readCount))) {
                shouldStop.stop()
                break
            }
        }
    }

    private static func drainCatFileStdout(
        from descriptor: Int32,
        blobPipeWriteFD: Int32?,
        collector: OutputCollector,
        shouldStop: StopFlag
    ) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)

        func processPending() -> Bool {
            while !pending.isEmpty {
                guard let newlineIndex = pending.firstIndex(of: 0x0A) else {
                    return true
                }

                let header = pending[..<newlineIndex]
                pending.removeSubrange(...newlineIndex)

                guard collector.appendStdout(Data(header) + Data([0x0A])) else {
                    return false
                }

                guard let headerText = String(data: header, encoding: .utf8) else {
                    continue
                }

                if headerText.hasSuffix(" missing") {
                    continue
                }

                let parts = headerText.split(separator: " ", omittingEmptySubsequences: false)
                guard parts.count >= 3, let contentSize = Int(parts[2]) else {
                    continue
                }

                while pending.count < contentSize, !shouldStop.isStopped {
                    let readCount = buffer.withUnsafeMutableBytes { rawBuffer in
                        read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
                    }
                    if readCount <= 0 {
                        return false
                    }
                    pending.append(contentsOf: buffer.prefix(readCount))
                }

                guard pending.count >= contentSize else {
                    return false
                }

                let blobBytes = pending.prefix(contentSize)
                pending.removeFirst(contentSize)

                if let blobPipeWriteFD, blobPipeWriteFD >= 0 {
                    writeAll(Data(blobBytes), to: blobPipeWriteFD)
                } else {
                    guard collector.appendStdout(Data(blobBytes)) else {
                        return false
                    }
                }
            }

            return true
        }

        while !shouldStop.isStopped {
            if !processPending() {
                break
            }

            let readCount = buffer.withUnsafeMutableBytes { rawBuffer in
                read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if readCount <= 0 {
                break
            }
            pending.append(contentsOf: buffer.prefix(readCount))
            if !processPending() {
                break
            }
        }

        _ = processPending()
    }
}

private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: UInt64
    private var combinedCount: UInt64 = 0

    private(set) var stdout = Data()
    private(set) var stderr = Data()
    private(set) var limitExceeded = false

    init(limit: UInt64) {
        self.limit = limit
    }

    @discardableResult
    func appendStdout(_ chunk: Data) -> Bool {
        append(chunk, to: &stdout)
    }

    @discardableResult
    func appendStderr(_ chunk: Data) -> Bool {
        append(chunk, to: &stderr)
    }

    @discardableResult
    private func append(_ chunk: Data, to destination: inout Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if limitExceeded {
            return false
        }

        let nextCount = combinedCount + UInt64(chunk.count)
        if nextCount > limit {
            limitExceeded = true
            return false
        }

        combinedCount = nextCount
        destination.append(chunk)
        return true
    }
}
