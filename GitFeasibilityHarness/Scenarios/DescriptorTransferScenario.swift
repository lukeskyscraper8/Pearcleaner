import Foundation
import GitEvidenceShared

struct DescriptorTransferScenario: FeasibilityScenario {
    let id: FeasibilityScenarioID = .descriptorTransfer

    func run(outputDirectory: URL) throws -> FeasibilityScenarioResult {
        _ = outputDirectory
        return FeasibilityPlaceholderScenario.notImplementedResult(
            id: id,
            summary: "Descriptor transfer preservation is not implemented until Task 5."
        )
    }
}
