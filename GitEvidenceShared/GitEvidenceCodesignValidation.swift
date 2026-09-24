import Foundation
import Security

public enum GitEvidenceCodesignValidationError: Error, Sendable {
    case message(String)
}

public enum GitEvidenceCodesignValidation {
    /// Pins an incoming connection to the allowlisted clients. The XPC runtime
    /// then rejects messages from any other client using its audit token.
    public static func applyClientRequirement(to connection: NSXPCConnection) {
        if ProcessInfo.processInfo.environment["GIT_FEASIBILITY_RELAXED_CODESIGN"] == "1" {
            return
        }

        connection.setCodeSigningRequirement(GitEvidenceServiceIdentity.acceptedClientRequirement)
    }

    public static func serviceAtURLMatchesRequirement(_ url: URL) throws -> Bool {
        if ProcessInfo.processInfo.environment["GIT_FEASIBILITY_RELAXED_CODESIGN"] == "1" {
            var staticCode: SecStaticCode?
            let createStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
            return createStatus == errSecSuccess && staticCode != nil
        }

        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            throw GitEvidenceCodesignValidationError.message("unable to read GitEvidenceService signature")
        }

        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(
            GitEvidenceServiceIdentity.serviceRequirement as CFString,
            [],
            &requirement
        )
        guard requirementStatus == errSecSuccess, let requirement else {
            throw GitEvidenceCodesignValidationError.message("unable to build GitEvidenceService requirement")
        }

        return SecStaticCodeCheckValidity(staticCode, [], requirement) == errSecSuccess
    }
}
