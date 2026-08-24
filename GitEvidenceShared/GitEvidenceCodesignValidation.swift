import Foundation
import Security

public enum GitEvidenceCodesignValidationError: Error, Sendable {
    case message(String)
}

public enum GitEvidenceCodesignValidation {
    public static func clientIsAllowlisted(pid: pid_t) -> Bool {
        GitEvidenceServiceIdentity.acceptedClientRequirements.contains { requirement in
            (try? clientMatchesRequirement(pid: pid, requirement: requirement)) == true
        }
    }

    public static func serviceAtURLMatchesRequirement(_ url: URL) throws -> Bool {
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

    private static func clientMatchesRequirement(pid: pid_t, requirement: String) throws -> Bool {
        var guestCode: SecCode?
        let guestStatus = SecCodeCopyGuestWithAttributes(
            nil,
            [kSecGuestAttributePid: pid] as CFDictionary,
            [],
            &guestCode
        )
        guard guestStatus == errSecSuccess, let guestCode else {
            throw GitEvidenceCodesignValidationError.message("unable to inspect XPC client signature")
        }

        var parsedRequirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(requirement as CFString, [], &parsedRequirement)
        guard requirementStatus == errSecSuccess, let parsedRequirement else {
            throw GitEvidenceCodesignValidationError.message("unable to build client requirement")
        }

        return SecCodeCheckValidity(guestCode, [], parsedRequirement) == errSecSuccess
    }
}
