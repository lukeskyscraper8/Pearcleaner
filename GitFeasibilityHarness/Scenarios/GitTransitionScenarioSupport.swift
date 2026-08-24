import Darwin
import Foundation
import GitEvidenceShared

struct GitRunnerSpawnResult: Sendable {
    let terminationStatus: Int32
    let stdout: Data
    let stderr: Data
}

enum GitRunnerSpawnError: Error, Sendable {
    case pipeCreationFailed
    case spawnFailed(Int32)
    case executableNotFound(URL)
}

enum GitTransitionScenarioSupport {
    static func embeddedRunnerURL(bundle: Bundle = .main) throws -> URL {
        if let auxiliary = bundle.url(forAuxiliaryExecutable: "GitRunner") {
            return auxiliary
        }

        let macOSCandidate = bundle.bundleURL
            .appendingPathComponent("Contents/MacOS/GitRunner")
        if FileManager.default.isExecutableFile(atPath: macOSCandidate.path) {
            return macOSCandidate
        }

        throw GitRunnerSpawnError.executableNotFound(macOSCandidate)
    }

    static func repositoryRootURL(bundle: Bundle = .main) throws -> URL {
        _ = bundle
        return try createInlineMinimalRepository()
    }

    static func createInlineMinimalRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-transition-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("fixture tracked\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))

        let process = Process()
        process.currentDirectoryURL = root
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init", "-q"]
        process.environment = [
            "HOME": root.appendingPathComponent(".home").path,
            "TMPDIR": root.appendingPathComponent(".tmp").path,
            "PATH": "/usr/bin:/bin",
            "LANG": "C",
            "LC_ALL": "C",
        ]
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".home"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".tmp"),
            withIntermediateDirectories: true
        )
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FeasibilityScenarioFailure.scenarioFailed(
                .gitTransition,
                reason: "unable to initialize inline minimal repository"
            )
        }

        let addProcess = Process()
        addProcess.currentDirectoryURL = root
        addProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        addProcess.arguments = ["add", "tracked.txt"]
        addProcess.environment = process.environment
        try addProcess.run()
        addProcess.waitUntilExit()
        guard addProcess.terminationStatus == 0 else {
            throw FeasibilityScenarioFailure.scenarioFailed(
                .gitTransition,
                reason: "unable to stage tracked file in inline minimal repository"
            )
        }

        return root
    }

    static func spawnGitRunner(
        executableURL: URL,
        gitArguments: [String],
        environment: [String: String],
        inheritedMetadataDescriptors: [Int32]
    ) throws -> GitRunnerSpawnResult {
        var stdoutPipe: [Int32] = [0, 0]
        var stderrPipe: [Int32] = [0, 0]
        guard pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
            throw GitRunnerSpawnError.pipeCreationFailed
        }

        let stdoutRead = stdoutPipe[0]
        let stdoutWrite = stdoutPipe[1]
        let stderrRead = stderrPipe[0]
        let stderrWrite = stderrPipe[1]

        _ = fcntl(stdoutRead, F_SETFD, FD_CLOEXEC)
        _ = fcntl(stderrRead, F_SETFD, FD_CLOEXEC)

        for descriptor in inheritedMetadataDescriptors {
            let flags = fcntl(descriptor, F_GETFD)
            if flags >= 0 {
                _ = fcntl(descriptor, F_SETFD, flags & ~FD_CLOEXEC)
            }
        }

        var fileActions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw GitRunnerSpawnError.spawnFailed(errno)
        }
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
        }

        let devNull = open("/dev/null", O_RDONLY)
        if devNull >= 0 {
            _ = posix_spawn_file_actions_adddup2(&fileActions, devNull, STDIN_FILENO)
            _ = posix_spawn_file_actions_addclose(&fileActions, devNull)
        }

        _ = posix_spawn_file_actions_adddup2(&fileActions, stdoutWrite, STDOUT_FILENO)
        _ = posix_spawn_file_actions_adddup2(&fileActions, stderrWrite, STDERR_FILENO)
        _ = posix_spawn_file_actions_addclose(&fileActions, stdoutRead)
        _ = posix_spawn_file_actions_addclose(&fileActions, stderrWrite)
        _ = posix_spawn_file_actions_addclose(&fileActions, stderrRead)

        for descriptor in inheritedMetadataDescriptors {
            _ = posix_spawn_file_actions_addinherit_np(&fileActions, descriptor)
        }

        var environment = environment
        environment[GitRunnerInvocation.metadataFileDescriptorsEnvironmentKey] =
            inheritedMetadataDescriptors.map(String.init).joined(separator: ",")

        let argvStrings = [executableURL.path] + gitArguments
        let argv = argvStrings.map { string -> UnsafeMutablePointer<CChar> in
            guard let duplicated = strdup(string) else {
                fatalError("GitRunner harness argv allocation failed")
            }
            return duplicated
        }
        defer { argv.forEach { free($0) } }
        var argvWithNull = argv.map { Optional($0) }
        argvWithNull.append(nil)

        let envpStrings = environment.map { "\($0.key)=\($0.value)" }.sorted()
        let envp = envpStrings.map { string -> UnsafeMutablePointer<CChar> in
            guard let duplicated = strdup(string) else {
                fatalError("GitRunner harness env allocation failed")
            }
            return duplicated
        }
        defer { envp.forEach { free($0) } }
        var envpWithNull = envp.map { Optional($0) }
        envpWithNull.append(nil)

        var spawnedPID: pid_t = 0
        let spawnResult: Int32 = argvWithNull.withUnsafeMutableBufferPointer { argvBuffer in
            envpWithNull.withUnsafeMutableBufferPointer { envpBuffer in
                posix_spawn(
                    &spawnedPID,
                    executableURL.path,
                    &fileActions,
                    nil,
                    argvBuffer.baseAddress,
                    envpBuffer.baseAddress
                )
            }
        }
        guard spawnResult == 0 else {
            throw GitRunnerSpawnError.spawnFailed(spawnResult)
        }
        let pid = spawnedPID

        close(stdoutWrite)
        close(stderrWrite)

        var waitStatus: Int32 = 0
        waitpid(pid, &waitStatus, 0)

        let terminationStatus: Int32
        if (waitStatus & 0x7F) == 0 {
            terminationStatus = (waitStatus >> 8) & 0xFF
        } else {
            terminationStatus = 128 + (waitStatus & 0x7F)
        }

        let stdoutData = readToEnd(from: stdoutRead)
        let stderrData = readToEnd(from: stderrRead)
        close(stdoutRead)
        close(stderrRead)

        return GitRunnerSpawnResult(
            terminationStatus: terminationStatus,
            stdout: stdoutData,
            stderr: stderrData
        )
    }

    static func openReadOnlyDescriptor(for url: URL) throws -> Int32 {
        let path = url.path
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw FeasibilityScenarioFailure.scenarioFailed(
                .gitTransition,
                reason: "unable to open \(path): \(String(cString: strerror(errno)))"
            )
        }
        return descriptor
    }

    static func makeGitEnvironment(
        repositoryRoot: URL,
        serviceHome: URL,
        serviceTemporaryDirectory: URL,
        indexFileDescriptor: Int32
    ) -> [String: String] {
        [
            "HOME": serviceHome.path,
            "TMPDIR": serviceTemporaryDirectory.path,
            "GIT_DIR": repositoryRoot.appendingPathComponent(".git").path,
            "GIT_WORK_TREE": repositoryRoot.path,
            "GIT_INDEX_FILE": "/dev/fd/\(indexFileDescriptor)",
        ]
    }

    static func runnerSandboxEnforcementExpected(at runnerURL: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-d", "--entitlements", ":-", runnerURL.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return false
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return false
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            return false
        }

        return (plist["com.apple.security.app-sandbox"] as? Bool) == true
    }

    private static func readToEnd(from descriptor: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let readCount = buffer.withUnsafeMutableBytes { rawBuffer in
                read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if readCount <= 0 {
                break
            }
            data.append(contentsOf: buffer.prefix(readCount))
        }
        return data
    }
}
