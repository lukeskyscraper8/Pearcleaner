import Foundation

public protocol FeasibilityScenario: Sendable {
    var id: FeasibilityScenarioID { get }

    func run(outputDirectory: URL) throws -> FeasibilityScenarioResult
}

public enum FeasibilityScenarioFailure: Error, Sendable, Equatable {
    case scenarioFailed(FeasibilityScenarioID, reason: String)

    /// The scenario's own reason when `error` is a scenario failure, so
    /// evidence doesn't record Foundation's generic enum description.
    public static func reason(for error: Error) -> String {
        if case let .scenarioFailed(_, reason) = error as? FeasibilityScenarioFailure {
            return reason
        }
        return String(describing: error)
    }
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
