import Foundation
import GitEvidenceShared

struct CleanupScenario: FeasibilityScenario {
    let id: FeasibilityScenarioID = .cleanup

    func run(outputDirectory: URL) throws -> FeasibilityScenarioResult {
        _ = outputDirectory
        return FeasibilityPlaceholderScenario.notImplementedResult(
            id: id,
            summary: "Cleanup after success/failure/SIGKILL is not implemented until Task 6."
        )
    }
}
