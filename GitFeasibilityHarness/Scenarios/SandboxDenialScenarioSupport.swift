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
        try ServiceProbeSupport.serviceRunnerURL(bundle: bundle)
    }

    static func runnerSandboxEnforcementExpected(at runnerURL: URL) -> Bool {
        GitTransitionScenarioSupport.runnerSandboxEnforcementExpected(at: runnerURL)
    }

    static func runDenialMatrix(
        scenarioDirectory: URL,
        repositoryRoot: URL
    ) throws -> [SandboxDenialProbeResult] {
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

        let probes: [(SandboxDenialProbeKind, [String])] = [
            (.workingTreeCanary, [GitRunnerInvocation.openProbeArgument, workingTreeCanary.path]),
            (.siblingUserData, [GitRunnerInvocation.openProbeArgument, siblingUserData.path]),
            (.pearcleanerPrivateState, [GitRunnerInvocation.openProbeArgument, pearcleanerPrivateState.path]),
            (.metadataWrite, [GitRunnerInvocation.writeProbeArgument, metadataWriteTarget.path]),
            (.projectExecutableLaunch, [GitRunnerInvocation.execProbeArgument, projectExecutable.path]),
            (.networkAccess, [GitRunnerInvocation.connectProbeArgument, "1.1.1.1", "443"]),
        ]

        return try probes.map { kind, probeArguments in
            let result = try ServiceProbeSupport.runProbe(probeArguments)
            return SandboxDenialProbeResult(
                kind: kind,
                denied: ServiceProbeSupport.probeWasDenied(result, marker: marker(for: kind)),
                exitCode: result.exitCode,
                stderr: result.completed ? result.stderr : "status=\(result.status) \(result.stderr)"
            )
        }
    }

    static func repositoryRootURL() throws -> URL {
        try GitTransitionScenarioSupport.createInlineMinimalRepository()
    }

    private static func marker(for kind: SandboxDenialProbeKind) -> String {
        switch kind {
        case .workingTreeCanary, .siblingUserData, .pearcleanerPrivateState:
            "probe_open_errno"
        case .metadataWrite:
            "probe_write_errno"
        case .projectExecutableLaunch:
            "probe_exec_errno"
        case .networkAccess:
            "probe_connect_errno"
        }
    }
}
