import Foundation
import GitEvidenceShared

enum SandboxDenialProbeKind: String, Sendable {
    case workingTreeCanary = "working_tree_canary"
    case siblingUserData = "sibling_user_data"
    case pearcleanerPrivateState = "pearcleaner_private_state"
    case metadataWrite = "metadata_write"
    case projectExecutableLaunch = "project_executable_launch"
    case networkAccess = "network_access"
}

struct SandboxDenialProbeResult: Sendable {
    let kind: SandboxDenialProbeKind
    let denied: Bool
    let exitCode: Int32
    let stderr: String
}

enum SandboxDenialScenarioSupport {
    static func embeddedRunnerURL(bundle: Bundle = .main) throws -> URL {
        try GitTransitionScenarioSupport.embeddedRunnerURL(bundle: bundle)
    }

    static func runnerSandboxEnforcementExpected(at runnerURL: URL) -> Bool {
        GitTransitionScenarioSupport.runnerSandboxEnforcementExpected(at: runnerURL)
    }

    static func runDenialMatrix(
        runnerURL: URL,
        scenarioDirectory: URL,
        repositoryRoot: URL
    ) throws -> [SandboxDenialProbeResult] {
        let serviceHome = scenarioDirectory.appendingPathComponent("service-home", isDirectory: true)
        let serviceTemporaryDirectory = scenarioDirectory.appendingPathComponent("service-tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: serviceHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: serviceTemporaryDirectory, withIntermediateDirectories: true)

        let workingTreeCanary = repositoryRoot.appendingPathComponent("working-tree-canary.txt")
        try "working-tree-canary\n".write(to: workingTreeCanary, atomically: true, encoding: .utf8)

        let siblingUserData = scenarioDirectory.appendingPathComponent("sibling-user-canary.txt")
        try "sibling-user-canary\n".write(to: siblingUserData, atomically: true, encoding: .utf8)

        let pearcleanerPrivateState = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.lukerow.Pearcleaner/Data/private-canary.txt")

        let metadataWriteTarget = repositoryRoot.appendingPathComponent(".git/index")
        let projectExecutable = repositoryRoot.appendingPathComponent("project-controlled.sh")
        try "#!/bin/sh\nexit 0\n".write(to: projectExecutable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: projectExecutable.path)

        let environment = [
            "HOME": serviceHome.path,
            "TMPDIR": serviceTemporaryDirectory.path,
        ]

        let probes: [(SandboxDenialProbeKind, [String])] = [
            (.workingTreeCanary, [GitRunnerInvocation.openProbeArgument, workingTreeCanary.path]),
            (.siblingUserData, [GitRunnerInvocation.openProbeArgument, siblingUserData.path]),
            (.pearcleanerPrivateState, [GitRunnerInvocation.openProbeArgument, pearcleanerPrivateState.path]),
            (.metadataWrite, [GitRunnerInvocation.writeProbeArgument, metadataWriteTarget.path]),
            (.projectExecutableLaunch, [GitRunnerInvocation.execProbeArgument, projectExecutable.path]),
            (.networkAccess, [GitRunnerInvocation.connectProbeArgument, "1.1.1.1", "443"]),
        ]

        return try probes.map { kind, gitArguments in
            let result = try GitTransitionScenarioSupport.spawnGitRunner(
                executableURL: runnerURL,
                gitArguments: gitArguments,
                environment: environment,
                inheritedMetadataDescriptors: []
            )
            let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
            let denied = probeWasDenied(kind: kind, exitCode: result.terminationStatus, stderr: stderr)
            return SandboxDenialProbeResult(
                kind: kind,
                denied: denied,
                exitCode: result.terminationStatus,
                stderr: stderr
            )
        }
    }

    static func repositoryRootURL() throws -> URL {
        try GitTransitionScenarioSupport.createInlineMinimalRepository()
    }

    private static func probeWasDenied(
        kind: SandboxDenialProbeKind,
        exitCode: Int32,
        stderr: String
    ) -> Bool {
        guard exitCode == 0 else {
            return false
        }

        switch kind {
        case .workingTreeCanary, .siblingUserData, .pearcleanerPrivateState:
            return stderr.contains("probe_open_errno=") && !stderr.contains("probe_open_errno=0")
        case .metadataWrite:
            return stderr.contains("probe_write_errno=") && !stderr.contains("probe_write_errno=0")
        case .projectExecutableLaunch:
            return stderr.contains("probe_exec_errno=") && !stderr.contains("probe_exec_errno=0")
        case .networkAccess:
            return stderr.contains("probe_connect_errno=") && !stderr.contains("probe_connect_errno=0")
        }
    }
}
