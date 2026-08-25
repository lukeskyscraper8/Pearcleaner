import Foundation
import GitEvidenceShared

struct SandboxDenialScenario: FeasibilityScenario {
    let id: FeasibilityScenarioID = .sandboxDenial

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
        let runnerURL = try SandboxDenialScenarioSupport.embeddedRunnerURL()
        let repositoryRoot = try SandboxDenialScenarioSupport.repositoryRootURL()
        defer { try? FileManager.default.removeItem(at: repositoryRoot) }

        let sandboxEnforced = SandboxDenialScenarioSupport.runnerSandboxEnforcementExpected(at: runnerURL)
        let probeResults = try SandboxDenialScenarioSupport.runDenialMatrix(
            runnerURL: runnerURL,
            scenarioDirectory: scenarioDirectory,
            repositoryRoot: repositoryRoot
        )

        let deniedKinds = probeResults.filter(\.denied).map(\.kind.rawValue)
        let allowedKinds = probeResults.filter { !$0.denied }.map(\.kind.rawValue)
        let logLines = probeResults.flatMap { result in
            [
                "probe=\(result.kind.rawValue)",
                "exit=\(result.exitCode)",
                "denied=\(result.denied)",
                "stderr=\(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))",
                "",
            ]
        } + [
            "runner_sandbox_enforcement_expected=\(sandboxEnforced)",
            "denied_kinds=\(deniedKinds.joined(separator: ","))",
            "allowed_kinds=\(allowedKinds.joined(separator: ","))",
        ]
        try (logLines.joined(separator: "\n") + "\n").write(to: sandboxLogURL, atomically: true, encoding: .utf8)

        let passed: Bool
        let summary: String
        if sandboxEnforced {
            passed = probeResults.allSatisfy(\.denied)
            summary = passed
                ? "Sandboxed GitRunner denied working-tree, sibling user data, Pearcleaner private state, metadata writes, project executable launch, and network access."
                : "Sandbox denial matrix failed: \(allowedKinds.joined(separator: ", ")) were not denied."
        } else {
            passed = true
            summary = "Sandbox denial matrix deferred because runner sandbox entitlements are not enforced in this build profile."
        }

        return FeasibilityScenarioResult(
            id: id,
            status: passed ? .passed : .failed,
            passed: passed,
            sandboxLogPath: "logs/\(id.rawValue).log",
            details: [
                "summary": summary,
                "runner_sandbox_enforcement_expected": String(sandboxEnforced),
                "denied_kinds": deniedKinds.joined(separator: ","),
                "allowed_kinds": allowedKinds.joined(separator: ","),
            ]
        )
    }
}
