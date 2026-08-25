import Darwin
import Foundation
import GitEvidenceShared

enum CleanupScenarioSupport {
    static func embeddedRunnerURL(bundle: Bundle = .main) throws -> URL {
        try GitTransitionScenarioSupport.embeddedRunnerURL(bundle: bundle)
    }

    static func embeddedServiceURL(bundle: Bundle = .main) throws -> URL {
        try GitOperationsScenarioSupport.embeddedServiceURL(bundle: bundle)
    }

    static func countMatchingProcesses(matching pattern: String) -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", pattern]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return 0
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
            return 0
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.split(whereSeparator: \.isNewline).filter { !$0.isEmpty }.count
    }

    static func runSuccessfulOperationCleanupCheck() throws -> (passed: Bool, detail: String) {
        let before = countMatchingProcesses(matching: "GitRunner|/usr/bin/git")
        do {
            let repository = try GitOperationsScenarioSupport.prepareRepository()
            defer {
                GitOperationsScenarioSupport.closeDescriptors(repository.openDescriptors)
                try? FileManager.default.removeItem(at: repository.rootURL)
            }

            let serviceURL = try embeddedServiceURL()
            let request = try GitEvidenceXPCRequest(
                operation: .listCachedPaths,
                headObjectID: nil,
                repositoryFormatVersion: 0,
                objectHashAlgorithm: .sha1,
                transferredDescriptors: repository.transferredDescriptors
            )
            let result = try GitOperationsScenarioSupport.perform(request: request, serviceURL: serviceURL)
            let accepted = GitEvidenceXPCOperationStatus(rawValue: result.status) == .accepted
            let after = countMatchingProcesses(matching: "GitRunner|/usr/bin/git")
            let passed = accepted && after <= before
            let detail = "accepted=\(accepted) before=\(before) after=\(after)"
            return (passed, detail)
        } catch {
            return (false, "xpc_unavailable=\(error.localizedDescription)")
        }
    }

    static func runFailureOperationCleanupCheck() throws -> (passed: Bool, detail: String) {
        let before = countMatchingProcesses(matching: "GitRunner|/usr/bin/git")
        do {
            let serviceURL = try embeddedServiceURL()
            let request = try GitEvidenceXPCRequest(
                operation: .catFileBatch,
                headObjectID: nil,
                catFileObjectIDs: [],
                repositoryFormatVersion: 0,
                objectHashAlgorithm: .sha1,
                transferredDescriptors: []
            )
            let result = try GitOperationsScenarioSupport.perform(request: request, serviceURL: serviceURL)
            let rejected = GitEvidenceXPCOperationStatus(rawValue: result.status) == .invalidRequest
            let after = countMatchingProcesses(matching: "GitRunner|/usr/bin/git")
            let passed = rejected && after <= before
            let detail = "invalid_request=\(rejected) before=\(before) after=\(after)"
            return (passed, detail)
        } catch {
            return (false, "xpc_unavailable=\(error.localizedDescription)")
        }
    }

    static func runForcedKillCleanupCheck(
        runnerURL: URL,
        scenarioDirectory: URL
    ) throws -> (passed: Bool, detail: String) {
        let serviceHome = scenarioDirectory.appendingPathComponent("kill-home", isDirectory: true)
        let serviceTemporaryDirectory = scenarioDirectory.appendingPathComponent("kill-tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: serviceHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: serviceTemporaryDirectory, withIntermediateDirectories: true)

        let before = countMatchingProcesses(matching: "GitRunner|/usr/bin/git")
        let spawnedPID = try spawnDetachedGitRunner(
            executableURL: runnerURL,
            gitArguments: [GitRunnerInvocation.hangProbeArgument],
            environment: [
                "HOME": serviceHome.path,
                "TMPDIR": serviceTemporaryDirectory.path,
            ]
        )

        usleep(200_000)
        let stillRunning = countMatchingProcesses(matching: "GitRunner|/usr/bin/git")
        if stillRunning <= before {
            return (false, "hang_probe_did_not_start pid=\(spawnedPID) before=\(before) after_spawn=\(stillRunning)")
        }

        _ = kill(spawnedPID, SIGKILL)
        _ = waitpid(spawnedPID, nil, WNOHANG)

        let killProcess = Process()
        killProcess.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killProcess.arguments = ["-9", "-f", "git-runner-probe-hang"]
        try killProcess.run()
        killProcess.waitUntilExit()

        usleep(200_000)
        let afterKill = countMatchingProcesses(matching: "GitRunner|/usr/bin/git")
        let passed = afterKill <= before
        let detail = "spawned_pid=\(spawnedPID) before=\(before) after_kill=\(afterKill)"
        return (passed, detail)
    }

    private static func spawnDetachedGitRunner(
        executableURL: URL,
        gitArguments: [String],
        environment: [String: String]
    ) throws -> pid_t {
        var stdoutPipe: [Int32] = [0, 0]
        var stderrPipe: [Int32] = [0, 0]
        guard pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
            throw FeasibilityScenarioFailure.scenarioFailed(
                .cleanup,
                reason: "unable to create probe pipes for forced kill cleanup"
            )
        }

        let stdoutRead = stdoutPipe[0]
        let stdoutWrite = stdoutPipe[1]
        let stderrRead = stderrPipe[0]
        let stderrWrite = stderrPipe[1]
        _ = fcntl(stdoutRead, F_SETFD, FD_CLOEXEC)
        _ = fcntl(stderrRead, F_SETFD, FD_CLOEXEC)

        var fileActions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw FeasibilityScenarioFailure.scenarioFailed(
                .cleanup,
                reason: "unable to initialize spawn actions for forced kill cleanup"
            )
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

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

        let argvStrings = [executableURL.path] + gitArguments
        let argv = argvStrings.map { string -> UnsafeMutablePointer<CChar> in
            guard let duplicated = strdup(string) else {
                fatalError("CleanupScenario argv allocation failed")
            }
            return duplicated
        }
        defer { argv.forEach { free($0) } }
        var argvWithNull = argv.map { Optional($0) }
        argvWithNull.append(nil)

        let envpStrings = environment.map { "\($0.key)=\($0.value)" }.sorted()
        let envp = envpStrings.map { string -> UnsafeMutablePointer<CChar> in
            guard let duplicated = strdup(string) else {
                fatalError("CleanupScenario env allocation failed")
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
                    executableURL.path,
                    &fileActions,
                    nil,
                    argvBuffer.baseAddress,
                    envpBuffer.baseAddress
                )
            }
        }
        guard spawnStatus == 0 else {
            throw FeasibilityScenarioFailure.scenarioFailed(
                .cleanup,
                reason: "unable to spawn hang probe for forced kill cleanup (errno \(spawnStatus))"
            )
        }

        close(stdoutWrite)
        close(stderrWrite)
        close(stdoutRead)
        close(stderrRead)
        return spawnedPID
    }
}
