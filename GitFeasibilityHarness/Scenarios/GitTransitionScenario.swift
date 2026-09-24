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

        do {
            return try runScenario(
                scenarioDirectory: scenarioDirectory,
                sandboxLogURL: sandboxLogURL
            )
        } catch let failure as FeasibilityScenarioFailure {
            if case let .scenarioFailed(_, reason) = failure {
                return FeasibilityScenarioResult(
                    id: id,
                    status: .failed,
                    passed: false,
                    sandboxLogPath: "logs/\(id.rawValue).log",
                    details: [
                        "summary": reason,
                        "scenario_failure": reason,
                    ]
                )
            }
            throw failure
        } catch {
            return FeasibilityScenarioResult(
                id: id,
                status: .failed,
                passed: false,
                sandboxLogPath: "logs/\(id.rawValue).log",
                details: [
                    "summary": error.localizedDescription,
                    "scenario_failure": error.localizedDescription,
                ]
            )
        }
    }

    private func runScenario(
        scenarioDirectory: URL,
        sandboxLogURL: URL
    ) throws -> FeasibilityScenarioResult {
        _ = scenarioDirectory
        // Both checks go through the sandboxed service, which is the only
        // process allowed to launch GitRunner: macOS kills a runner that
        // inherits a sandbox from an unsandboxed parent such as this harness.
        let serviceURL = try GitOperationsScenarioSupport.embeddedServiceURL()
        let runnerURL = try ServiceProbeSupport.serviceRunnerURL()
        let repositoryRoot = try GitTransitionScenarioSupport.repositoryRootURL()
        defer { try? FileManager.default.removeItem(at: repositoryRoot) }

        // The index reaches Git only as an inherited descriptor
        // (GIT_INDEX_FILE=/dev/fd/N), so listing tracked.txt proves the
        // descriptor survived the runner's exec into Git.
        let indexPath = repositoryRoot.appendingPathComponent(".git/index")
        let indexDescriptor = try GitTransitionScenarioSupport.openReadOnlyDescriptor(for: indexPath)
        defer { close(indexDescriptor) }

        let request = try GitEvidenceXPCRequest(
            operation: .listCachedPaths,
            headObjectID: nil,
            repositoryFormatVersion: 0,
            objectHashAlgorithm: .sha1,
            transferredDescriptors: [
                GitEvidenceXPCTransferredDescriptor(
                    record: GitEvidenceXPCDescriptorRecord(
                        role: .index,
                        identity: try DescriptorTransferScenarioSupport.makeIdentity(for: indexDescriptor)
                    ),
                    fileHandle: FileHandle(fileDescriptor: indexDescriptor, closeOnDealloc: false)
                ),
            ]
        )
        let metadataResult = try GitOperationsScenarioSupport.perform(request: request, serviceURL: serviceURL)
        let metadataStdout = String(data: metadataResult.stdoutPreview, encoding: .utf8) ?? ""
        let metadataStderr = String(data: metadataResult.stderrPreview, encoding: .utf8) ?? ""
        let metadataReadSucceeded = GitEvidenceXPCOperationStatus(rawValue: metadataResult.status) == .accepted
            && metadataStdout.contains("tracked.txt")

        // The same file is not readable by path from inside the sandbox.
        let workingTreeFile = repositoryRoot.appendingPathComponent("tracked.txt")
        let workingTreeProbe = try ServiceProbeSupport.runProbe([
            GitRunnerInvocation.openProbeArgument,
            workingTreeFile.path,
        ])
        let workingTreeReadDenied = ServiceProbeSupport.probeWasDenied(workingTreeProbe, marker: "probe_open_errno")
        let sandboxDenialVerified = workingTreeReadDenied
            || !GitTransitionScenarioSupport.runnerSandboxEnforcementExpected(at: runnerURL)

        let logLines: [String] = [
            "runner=\(runnerURL.path)",
            "repository_root=\(repositoryRoot.path)",
            "metadata_transfer_status=\(metadataResult.status)",
            "metadata_stdout=\(metadataStdout.trimmingCharacters(in: .whitespacesAndNewlines))",
            "metadata_stderr=\(metadataStderr.trimmingCharacters(in: .whitespacesAndNewlines))",
            "metadata_read_succeeded=\(metadataReadSucceeded)",
            "working_tree_probe_status=\(workingTreeProbe.status)",
            "working_tree_probe_exit=\(workingTreeProbe.exitCode)",
            "working_tree_probe_stderr=\(workingTreeProbe.stderr.trimmingCharacters(in: .whitespacesAndNewlines))",
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
                    ? "Metadata FD survived the Apple Git transition and sandbox denial checks passed or were deferred to signed matrix runs."
                    : "Git transition scenario failed metadata preservation and/or sandbox denial checks.",
                "metadata_read_succeeded": String(metadataReadSucceeded),
                "working_tree_read_denied": String(workingTreeReadDenied),
                "sandbox_denial_verified": String(sandboxDenialVerified),
                "runner_sandbox_enforcement_expected": String(
                    GitTransitionScenarioSupport.runnerSandboxEnforcementExpected(at: runnerURL)
                ),
                "runner_version": GitRunnerVersion.current,
                "git_launch_path": GitRunnerInvocation.resolvedGitLaunchPath() ?? "not_found",
            ]
        )
    }
}
