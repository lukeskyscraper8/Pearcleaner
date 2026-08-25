import Foundation
import GitEvidenceShared

struct LsTreeOperationScenario: FeasibilityScenario {
    let id: FeasibilityScenarioID = .lsTreeOperation

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
            operation: .listHeadTreePaths,
            headObjectID: repository.headObjectID,
            repositoryFormatVersion: 0,
            objectHashAlgorithm: .sha1,
            transferredDescriptors: repository.transferredDescriptors
        )

        let result = try GitOperationsScenarioSupport.perform(request: request, serviceURL: serviceURL)
        let stdout = String(data: result.stdoutPreview, encoding: .utf8) ?? ""
        let accepted = GitEvidenceXPCOperationStatus(rawValue: result.status) == .accepted
        let containsTrackedPath = stdout.contains("tracked.txt")
        let containsBlobOID = stdout.contains(repository.blobObjectID.hex)
        let passed = accepted && containsTrackedPath && containsBlobOID

        let logLines = [
            "operation=list_head_tree_paths",
            "head_oid=\(repository.headObjectID.hex)",
            "transfer_status=\(result.status)",
            "stdout_preview=\(stdout.trimmingCharacters(in: .whitespacesAndNewlines))",
            "contains_tracked_path=\(containsTrackedPath)",
            "contains_blob_oid=\(containsBlobOID)",
        ]
        try (logLines.joined(separator: "\n") + "\n").write(to: sandboxLogURL, atomically: true, encoding: .utf8)

        return FeasibilityScenarioResult(
            id: id,
            status: passed ? .passed : .failed,
            passed: passed,
            sandboxLogPath: "logs/\(id.rawValue).log",
            details: [
                "summary": passed
                    ? "git ls-tree -r -z returned HEAD tree paths through the synthetic administrative view."
                    : "ls-tree operation scenario failed acceptance or path validation.",
                "transfer_status": result.status,
                "contains_tracked_path": String(containsTrackedPath),
                "contains_blob_oid": String(containsBlobOID),
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
