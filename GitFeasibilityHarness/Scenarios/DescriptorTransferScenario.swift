import Darwin
import Foundation
import GitEvidenceShared

struct DescriptorTransferScenario: FeasibilityScenario {
    let id: FeasibilityScenarioID = .descriptorTransfer

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
            throw failure
        } catch {
            let reason = error.localizedDescription
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

    private func runScenario(
        scenarioDirectory: URL,
        sandboxLogURL: URL
    ) throws -> FeasibilityScenarioResult {
        _ = scenarioDirectory

        let serviceURL = try DescriptorTransferScenarioSupport.embeddedServiceURL()
        let repositoryRoot = try DescriptorTransferScenarioSupport.repositoryRootURL()
        defer { try? FileManager.default.removeItem(at: repositoryRoot) }

        let indexPath = repositoryRoot.appendingPathComponent(".git/index")
        let indexDescriptor = try DescriptorTransferScenarioSupport.openReadOnlyDescriptor(for: indexPath)
        defer { close(indexDescriptor) }

        let expectedIdentity = try DescriptorTransferScenarioSupport.makeIdentity(for: indexDescriptor)
        let transferred = GitEvidenceXPCTransferredDescriptor(
            record: GitEvidenceXPCDescriptorRecord(
                role: .index,
                identity: expectedIdentity
            ),
            fileHandle: FileHandle(fileDescriptor: indexDescriptor, closeOnDealloc: false)
        )

        let result = try DescriptorTransferScenarioSupport.performDescriptorTransfer(
            serviceURL: serviceURL,
            transferredDescriptors: [transferred]
        )

        let readOnlyPreserved = GitEvidenceDescriptorValidator.isReadOnly(fileDescriptor: indexDescriptor)
        let identityPreserved: Bool
        do {
            let reopenedIdentity = try DescriptorTransferScenarioSupport.makeIdentity(for: indexDescriptor)
            identityPreserved = reopenedIdentity.matches(expectedIdentity)
        } catch {
            identityPreserved = false
        }

        let accepted = GitEvidenceXPCOperationStatus(rawValue: result.status) == .accepted
        let blobPipeProvided = result.blobPipeReadHandle != nil
        let passed = accepted && readOnlyPreserved && identityPreserved && blobPipeProvided

        let logLines = [
            "service=\(serviceURL.path)",
            "repository_root=\(repositoryRoot.path)",
            "transfer_status=\(result.status)",
            "read_only_preserved=\(readOnlyPreserved)",
            "identity_preserved=\(identityPreserved)",
            "blob_pipe_provided=\(blobPipeProvided)",
        ]
        try (logLines.joined(separator: "\n") + "\n").write(to: sandboxLogURL, atomically: true, encoding: .utf8)

        return FeasibilityScenarioResult(
            id: id,
            status: passed ? .passed : .failed,
            passed: passed,
            sandboxLogPath: "logs/\(id.rawValue).log",
            details: [
                "summary": passed
                    ? "Batched descriptor transfer preserved O_RDONLY access and file identity across XPC."
                    : "Descriptor transfer scenario failed read-only preservation, identity checks, or XPC acceptance.",
                "transfer_status": result.status,
                "read_only_preserved": String(readOnlyPreserved),
                "identity_preserved": String(identityPreserved),
                "blob_pipe_provided": String(blobPipeProvided),
            ]
        )
    }
}
