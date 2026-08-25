import Foundation
import GitEvidenceShared

struct CleanupScenario: FeasibilityScenario {
    let id: FeasibilityScenarioID = .cleanup

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
        let runnerURL = try CleanupScenarioSupport.embeddedRunnerURL()
        let successCheck = try CleanupScenarioSupport.runSuccessfulOperationCleanupCheck()
        let failureCheck = try CleanupScenarioSupport.runFailureOperationCleanupCheck()
        let killCheck = try CleanupScenarioSupport.runForcedKillCleanupCheck(
            runnerURL: runnerURL,
            scenarioDirectory: scenarioDirectory
        )

        let xpcUnavailable = successCheck.detail.hasPrefix("xpc_unavailable=")
            || failureCheck.detail.hasPrefix("xpc_unavailable=")
        let passed: Bool
        let summary: String
        if xpcUnavailable {
            passed = killCheck.passed
            summary = passed
                ? "Forced SIGKILL cleanup passed; XPC success/failure cleanup deferred until signed service launch is available."
                : "Cleanup scenario failed forced SIGKILL cleanup; XPC checks were deferred."
        } else {
            passed = successCheck.passed && failureCheck.passed && killCheck.passed
            summary = passed
                ? "Git evidence operations cleaned up after success, invalid-request failure, and forced SIGKILL."
                : "Cleanup scenario failed one or more success/failure/SIGKILL checks."
        }
        let logLines = [
            "success_cleanup=\(successCheck.detail)",
            "failure_cleanup=\(failureCheck.detail)",
            "forced_kill_cleanup=\(killCheck.detail)",
            "passed=\(passed)",
        ]
        try (logLines.joined(separator: "\n") + "\n").write(to: sandboxLogURL, atomically: true, encoding: .utf8)

        return FeasibilityScenarioResult(
            id: id,
            status: passed ? .passed : .failed,
            passed: passed,
            sandboxLogPath: "logs/\(id.rawValue).log",
            details: [
                "summary": summary,
                "success_cleanup": successCheck.detail,
                "failure_cleanup": failureCheck.detail,
                "forced_kill_cleanup": killCheck.detail,
                "xpc_checks_deferred": String(xpcUnavailable),
            ]
        )
    }
}
