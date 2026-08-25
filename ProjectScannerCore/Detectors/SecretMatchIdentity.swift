import CryptoKit
import Foundation

public struct SecretMatchIdentity: Sendable, Equatable, Hashable {
    fileprivate let digest: Data

    fileprivate init(digest: Data) {
        precondition(digest.count == 32)
        self.digest = digest
    }

    var suppressionFieldBytes: Data { digest }
}

public struct SecretMatchIdentityKey: Sendable {
    fileprivate let symmetricKey: SymmetricKey

    public init(keyMaterial: ProjectKeyMaterial) {
        symmetricKey = keyMaterial.key
    }

    public init(ephemeralBytes: Data) throws {
        guard ephemeralBytes.count == 32 else {
            throw FingerprintError.invalidKeyLength
        }
        symmetricKey = SymmetricKey(data: ephemeralBytes)
    }

    public static func makeEphemeral() throws -> SecretMatchIdentityKey {
        var generator = SystemRandomNumberGenerator()
        let bytes = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        return try SecretMatchIdentityKey(ephemeralBytes: bytes)
    }
}

enum SecretMatchIdentityEncoder {
    private static let domain = Data(
        "com.lukerow.Pearcleaner.project-scanner.secret-match-identity.v1".utf8
    )

    static func identity(
        matchBytes: UnsafeRawBufferPointer,
        ruleID: RuleID,
        ruleVersion: UInt32,
        key: SecretMatchIdentityKey
    ) -> SecretMatchIdentity {
        var hmac = HMAC<SHA256>(key: key.symmetricKey)
        hmac.update(data: domain)
        hmac.update(data: encodedUInt32(ruleVersion))
        let ruleBytes = Data(ruleID.rawValue.utf8)
        hmac.update(data: encodedUInt64(UInt64(ruleBytes.count)))
        hmac.update(data: ruleBytes)
        hmac.update(data: encodedUInt64(UInt64(matchBytes.count)))
        if !matchBytes.isEmpty {
            hmac.update(data: Data(matchBytes))
        }
        return SecretMatchIdentity(digest: Data(hmac.finalize()))
    }
}

private func encodedUInt32(_ value: UInt32) -> Data {
    var bigEndian = value.bigEndian
    return withUnsafeBytes(of: &bigEndian) { Data($0) }
}

private func encodedUInt64(_ value: UInt64) -> Data {
    var bigEndian = value.bigEndian
    return withUnsafeBytes(of: &bigEndian) { Data($0) }
}
