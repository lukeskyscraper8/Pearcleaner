import Foundation

public protocol FeasibilityScenario: Sendable {
    var id: FeasibilityScenarioID { get }

    func run(outputDirectory: URL) throws -> FeasibilityScenarioResult
}

public enum FeasibilityScenarioFailure: Error, Sendable, Equatable {
    case scenarioFailed(FeasibilityScenarioID, reason: String)
}

public enum FeasibilityPlaceholderScenario {
    public static func notImplementedResult(
        id: FeasibilityScenarioID,
        summary: String
    ) -> FeasibilityScenarioResult {
        FeasibilityScenarioResult(
            id: id,
            status: .notImplemented,
            passed: false,
            details: [
                "status": FeasibilityScenarioStatus.notImplemented.rawValue,
                "summary": summary,
            ]
        )
    }
}
