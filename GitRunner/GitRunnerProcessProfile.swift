import Foundation

public struct GitRunnerProcessProfile: Sendable, Equatable {
    public static let placeholderVersion: String = "0.0.0-not-implemented"

    public let version: String
    public let inheritSandbox: Bool

    public init(
        version: String = Self.placeholderVersion,
        inheritSandbox: Bool = true
    ) {
        self.version = version
        self.inheritSandbox = inheritSandbox
    }
}
