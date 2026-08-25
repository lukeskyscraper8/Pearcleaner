import Foundation
import GitEvidenceShared

struct LsFilesOperationScenario: FeasibilityScenario {
    let id: FeasibilityScenarioID = .lsFilesOperation

    func run(outputDirectory: URL) throws -> FeasibilityScenarioResult {
        let logsDirectory = outputDirectory.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        let sandboxLogURL = logsDirectory.appendingPathComponent("\(id.rawValue).log")

        do {
            return try runScenario(sandboxLogURL: sandboxLogURL)
        } catch let failure as FeasibilityScenarioFailure {
            if case let .scenarioFailed(_, reason) = failure {
                return failedResult(sandboxLogURL: sandboxLogURL, reason: reason)
            }
            throw failure
        } catch {
            return failedResult(sandboxLogURL: sandboxLogURL, reason: error.localizedDescription)
        }
    }

    private func runScenario(sandboxLogURL: URL) throws -> FeasibilityScenarioResult {
        let serviceURL = try GitOperationsScenarioSupport.embeddedServiceURL()
        let repository = try GitOperationsScenarioSupport.prepareRepository()
        defer {
            GitOperationsScenarioSupport.closeDescriptors(repository.openDescriptors)
            try? FileManager.default.removeItem(at: repository.rootURL)
        }

        let request = try GitEvidenceXPCRequest(
            operation: .listCachedPaths,
            headObjectID: nil,
            repositoryFormatVersion: 0,
            objectHashAlgorithm: .sha1,
            transferredDescriptors: repository.transferredDescriptors
        )

        let result = try GitOperationsScenarioSupport.perform(request: request, serviceURL: serviceURL)
        let stdout = String(data: result.stdoutPreview, encoding: .utf8) ?? ""
        let accepted = GitEvidenceXPCOperationStatus(rawValue: result.status) == .accepted
        let containsTrackedPath = stdout.contains("tracked.txt")
        let passed = accepted && containsTrackedPath

        let logLines = [
            "operation=list_cached_paths",
            "transfer_status=\(result.status)",
            "stdout_preview=\(stdout.trimmingCharacters(in: .whitespacesAndNewlines))",
            "contains_tracked_path=\(containsTrackedPath)",
        ]
        try (logLines.joined(separator: "\n") + "\n").write(to: sandboxLogURL, atomically: true, encoding: .utf8)

        return FeasibilityScenarioResult(
            id: id,
            status: passed ? .passed : .failed,
            passed: passed,
            sandboxLogPath: "logs/\(id.rawValue).log",
            details: [
                "summary": passed
                    ? "git ls-files --cached -z returned tracked paths through the synthetic administrative view."
                    : "ls-files operation scenario failed acceptance or path validation.",
                "transfer_status": result.status,
                "contains_tracked_path": String(containsTrackedPath),
            ]
        )
    }

    private func failedResult(sandboxLogURL: URL, reason: String) -> FeasibilityScenarioResult {
        try? ("scenario_failure=\(reason)\n").write(
            to: sandboxLogURL,
            atomically: true,
            encoding: .utf8
        )
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
}
