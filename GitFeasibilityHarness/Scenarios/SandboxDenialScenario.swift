import Foundation
import GitEvidenceShared

struct SandboxDenialScenario: FeasibilityScenario {
    let id: FeasibilityScenarioID = .sandboxDenial

    func run(outputDirectory: URL) throws -> FeasibilityScenarioResult {
        _ = outputDirectory
        return FeasibilityPlaceholderScenario.notImplementedResult(
            id: id,
            summary: "Sandbox denial matrix is not implemented until Task 5."
        )
    }
}
