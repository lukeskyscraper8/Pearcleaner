import Foundation
import GitEvidenceShared

struct CatFileBatchOperationScenario: FeasibilityScenario {
    let id: FeasibilityScenarioID = .catFileBatchOperation

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
            operation: .catFileBatch,
            headObjectID: repository.headObjectID,
            catFileObjectIDs: [repository.blobObjectID],
            repositoryFormatVersion: 0,
            objectHashAlgorithm: .sha1,
            transferredDescriptors: repository.transferredDescriptors
        )

        let result = try GitOperationsScenarioSupport.perform(request: request, serviceURL: serviceURL)
        let stdout = String(data: result.stdoutPreview, encoding: .utf8) ?? ""
        let accepted = GitEvidenceXPCOperationStatus(rawValue: result.status) == .accepted
        let blobPipeProvided = result.blobPipeReadHandle != nil

        var blobBytes = Data()
        if let blobPipe = result.blobPipeReadHandle {
            blobBytes = blobPipe.readDataToEndOfFile()
        }

        let blobText = String(data: blobBytes, encoding: .utf8) ?? ""
        let containsFixtureContent = blobText.contains("fixture tracked")
        let passed = accepted && blobPipeProvided && containsFixtureContent

        let logLines = [
            "operation=cat_file_batch",
            "blob_oid=\(repository.blobObjectID.hex)",
            "transfer_status=\(result.status)",
            "stdout_preview=\(stdout.trimmingCharacters(in: .whitespacesAndNewlines))",
            "blob_pipe_provided=\(blobPipeProvided)",
            "blob_byte_count=\(blobBytes.count)",
            "contains_fixture_content=\(containsFixtureContent)",
        ]
        try (logLines.joined(separator: "\n") + "\n").write(to: sandboxLogURL, atomically: true, encoding: .utf8)

        return FeasibilityScenarioResult(
            id: id,
            status: passed ? .passed : .failed,
            passed: passed,
            sandboxLogPath: "logs/\(id.rawValue).log",
            details: [
                "summary": passed
                    ? "git cat-file --batch streamed blob bytes through the anonymous pipe endpoint."
                    : "cat-file batch operation scenario failed acceptance, pipe transfer, or blob validation.",
                "transfer_status": result.status,
                "blob_pipe_provided": String(blobPipeProvided),
                "contains_fixture_content": String(containsFixtureContent),
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
