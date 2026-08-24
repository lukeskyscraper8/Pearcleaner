import Foundation
import GitEvidenceShared

struct GitTransitionScenario: FeasibilityScenario {
    let id: FeasibilityScenarioID = .gitTransition

    func run(outputDirectory: URL) throws -> FeasibilityScenarioResult {
        _ = outputDirectory
        return FeasibilityPlaceholderScenario.notImplementedResult(
            id: id,
            summary: "/usr/bin/git transition FD preservation is not implemented until Task 4."
        )
    }
}
