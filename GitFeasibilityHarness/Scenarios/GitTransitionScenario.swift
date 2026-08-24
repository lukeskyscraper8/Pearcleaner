import Darwin
import Foundation
import GitEvidenceShared

struct GitTransitionScenario: FeasibilityScenario {
    let id: FeasibilityScenarioID = .gitTransition

    func run(outputDirectory: URL) throws -> FeasibilityScenarioResult {
        let scenarioDirectory = outputDirectory
            .appendingPathComponent("scenarios", isDirectory: true)
            .appendingPathComponent(id.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: scenarioDirectory, withIntermediateDirectories: true)

        let logsDirectory = outputDirectory.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        let sandboxLogURL = logsDirectory.appendingPathComponent("\(id.rawValue).log")

        let runnerURL = try GitTransitionScenarioSupport.embeddedRunnerURL()
        let repositoryRoot = try GitTransitionScenarioSupport.repositoryRootURL()
        defer { try? FileManager.default.removeItem(at: repositoryRoot) }

        let serviceHome = scenarioDirectory.appendingPathComponent("service-home", isDirectory: true)
        let serviceTemporaryDirectory = scenarioDirectory.appendingPathComponent("service-tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: serviceHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: serviceTemporaryDirectory, withIntermediateDirectories: true)

        let indexPath = repositoryRoot.appendingPathComponent(".git/index")
        let indexDescriptor = try GitTransitionScenarioSupport.openReadOnlyDescriptor(for: indexPath)
        defer { close(indexDescriptor) }

        let canaryPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.lukerow.Pearcleaner/Data/git-transition-canary.txt")
        let gitEnvironment = GitTransitionScenarioSupport.makeGitEnvironment(
            repositoryRoot: repositoryRoot,
            serviceHome: serviceHome,
            serviceTemporaryDirectory: serviceTemporaryDirectory,
            indexFileDescriptor: indexDescriptor
        )

        let metadataTransition = try GitTransitionScenarioSupport.spawnGitRunner(
            executableURL: runnerURL,
            gitArguments: [
                "--no-pager",
                "--no-optional-locks",
                "--no-replace-objects",
                "-c", "core.fsmonitor=false",
                "-c", "core.untrackedCache=false",
                "-c", "core.hooksPath=/dev/null",
                "-c", "submodule.recurse=false",
                "-c", "maintenance.auto=false",
                "-c", "core.attributesFile=/dev/null",
                "-c", "core.excludesFile=/dev/null",
                "-c", "color.ui=false",
                "-c", "credential.helper=",
                "-c", "protocol.allow=never",
                "-c", "diff.external=",
                "ls-files",
                "--cached",
                "-z",
            ],
            environment: gitEnvironment,
            inheritedMetadataDescriptors: [indexDescriptor]
        )

        let metadataExitCode = metadataTransition.terminationStatus
        let metadataStdout = String(data: metadataTransition.stdout, encoding: .utf8) ?? ""
        let metadataStderr = String(data: metadataTransition.stderr, encoding: .utf8) ?? ""
        let metadataReadSucceeded = metadataExitCode == 0 && metadataStdout.contains("tracked.txt")

        let workingTreeProbe = try GitTransitionScenarioSupport.spawnGitRunner(
            executableURL: runnerURL,
            gitArguments: [
                GitRunnerInvocation.openProbeArgument,
                canaryPath.path,
            ],
            environment: [
                "HOME": serviceHome.path,
                "TMPDIR": serviceTemporaryDirectory.path,
            ],
            inheritedMetadataDescriptors: []
        )

        let probeExitCode = workingTreeProbe.terminationStatus
        let probeStderr = String(data: workingTreeProbe.stderr, encoding: .utf8) ?? ""
        let workingTreeReadDenied = probeExitCode == 0 && probeStderr.contains("probe_open_errno=")
            && !probeStderr.contains("probe_open_errno=0")
        let sandboxDenialVerified = workingTreeReadDenied
            || !GitTransitionScenarioSupport.runnerSandboxEnforcementExpected(at: runnerURL)

        let logLines: [String] = [
            "runner=\(runnerURL.path)",
            "repository_root=\(repositoryRoot.path)",
            "metadata_transition_exit=\(metadataExitCode)",
            "metadata_stdout=\(metadataStdout.trimmingCharacters(in: .whitespacesAndNewlines))",
            "metadata_stderr=\(metadataStderr.trimmingCharacters(in: .whitespacesAndNewlines))",
            "metadata_read_succeeded=\(metadataReadSucceeded)",
            "working_tree_probe_exit=\(probeExitCode)",
            "working_tree_probe_stderr=\(probeStderr.trimmingCharacters(in: .whitespacesAndNewlines))",
            "working_tree_read_denied=\(workingTreeReadDenied)",
            "sandbox_denial_verified=\(sandboxDenialVerified)",
        ]
        let logBody = logLines.joined(separator: "\n") + "\n"
        try logBody.write(to: sandboxLogURL, atomically: true, encoding: .utf8)

        let passed = metadataReadSucceeded && sandboxDenialVerified
        let relativeSandboxLog = "logs/\(id.rawValue).log"

        return FeasibilityScenarioResult(
            id: id,
            status: passed ? .passed : .failed,
            passed: passed,
            sandboxLogPath: relativeSandboxLog,
            details: [
                "summary": passed
                    ? "Metadata FD survived /usr/bin/git transition and sandbox denial checks passed or were deferred to signed matrix runs."
                    : "Git transition scenario failed metadata preservation and/or sandbox denial checks.",
                "metadata_read_succeeded": String(metadataReadSucceeded),
                "working_tree_read_denied": String(workingTreeReadDenied),
                "sandbox_denial_verified": String(sandboxDenialVerified),
                "runner_sandbox_enforcement_expected": String(
                    GitTransitionScenarioSupport.runnerSandboxEnforcementExpected(at: runnerURL)
                ),
                "runner_version": GitRunnerVersion.current,
                "git_launch_path": GitRunnerInvocation.gitLaunchPath,
            ]
        )
    }
}
