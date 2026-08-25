import Foundation

struct GitRepositoryPreflight: Sendable {
    init() {}

    func preflight(broker: FileBroker) async -> GitPreflightOutcome {
        await broker.gitPreflight()
    }
}
