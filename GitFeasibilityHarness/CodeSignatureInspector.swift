import Foundation
import GitEvidenceShared
import Security

/// Reads the code-signing facts the manifest records for each signed product.
enum CodeSignatureInspector {
    private static let developerIDRequirement =
        "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
        + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    private static let notarizedRequirement = "notarized"

    static func inspect(_ url: URL) -> FeasibilityCodeSignature? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return nil
        }

        var rawInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &rawInformation
        ) == errSecSuccess,
            let information = rawInformation as? [String: Any] else {
            return nil
        }

        let identifier = information[kSecCodeInfoIdentifier as String] as? String ?? "unknown"
        let teamIdentifier = information[kSecCodeInfoTeamIdentifier as String] as? String ?? "none"
        let cdhash = (information[kSecCodeInfoUnique as String] as? Data)
            .map { $0.map { String(format: "%02x", $0) }.joined() } ?? "unknown"
        let leafAuthority = (information[kSecCodeInfoCertificates as String] as? [SecCertificate])?
            .first
            .flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? "unsigned"

        return FeasibilityCodeSignature(
            identifier: identifier,
            teamIdentifier: teamIdentifier,
            cdhash: cdhash,
            leafAuthority: leafAuthority,
            developerIDSigned: satisfies(staticCode, requirement: developerIDRequirement),
            notarized: satisfies(staticCode, requirement: notarizedRequirement)
        )
    }

    private static func satisfies(_ staticCode: SecStaticCode, requirement text: String) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            return false
        }
        return SecStaticCodeCheckValidity(staticCode, [], requirement) == errSecSuccess
    }
}
