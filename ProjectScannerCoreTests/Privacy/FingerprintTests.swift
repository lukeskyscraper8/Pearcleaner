import Foundation
import XCTest
@testable import ProjectScannerCore

final class FingerprintTests: XCTestCase {
    func testRFC4231SHA256HMACTestVector() throws {
        let key = Data(repeating: 0x0B, count: 20)
        let message = Data("Hi There".utf8)

        let digest = try hmacSHA256(message: message, key: key)

        XCTAssertEqual(
            digest,
            data(hex: "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
        )
    }

    func testSameKeyAndPrimitiveFieldsProduceSameFingerprint() throws {
        let keyMaterial = try makeKeyMaterial()
        let vector = try makeVector()
        let borrowed = Data([0x10, 0x20, 0x30])

        let first = try fingerprint(vector, borrowed: borrowed, keyMaterial: keyMaterial)
        let second = try fingerprint(vector, borrowed: borrowed, keyMaterial: keyMaterial)

        XCTAssertEqual(first, second)
    }

    func testTaggedFieldChangeChangesFingerprint() throws {
        let keyMaterial = try makeKeyMaterial()
        let vector = try makeVector()
        let borrowed = Data([0x10, 0x20, 0x30])

        let standard = try fingerprint(vector, borrowed: borrowed, keyMaterial: keyMaterial)
        let alternate = try borrowed.withUnsafeBytes {
            try FramedMACTestSupport.fingerprintWithAlternateDomainTag(
                vector,
                borrowedField: $0,
                keyMaterial: keyMaterial
            )
        }

        XCTAssertNotEqual(standard, alternate)

        XCTAssertThrowsError(
            try FramedMACTestSupport.finalizeWithTooFewFields(keyMaterial: keyMaterial)
        ) { error in
            XCTAssertEqual(error as? FingerprintError, .tooFewFields)
        }
        XCTAssertThrowsError(
            try FramedMACTestSupport.finalizeWithTooManyFields(keyMaterial: keyMaterial)
        ) { error in
            XCTAssertEqual(error as? FingerprintError, .tooManyFields)
        }
    }

    func testRawPathComponentChangeChangesPrimitiveOutput() throws {
        let keyMaterial = try makeKeyMaterial()
        let original = try makeVector(pathComponents: [Data([0x41]), Data([0xFF, 0x80])])
        let changed = try makeVector(pathComponents: [Data([0x41]), Data([0xFF, 0x81])])
        let borrowed = Data([0x10, 0x20, 0x30])

        XCTAssertNotEqual(
            try fingerprint(original, borrowed: borrowed, keyMaterial: keyMaterial),
            try fingerprint(changed, borrowed: borrowed, keyMaterial: keyMaterial)
        )
    }

    func testCaseAndUnicodeNormalizationAreNotFolded() throws {
        let keyMaterial = try makeKeyMaterial()
        let borrowed = Data([0x10])
        let uppercase = try makeVector(pathComponents: [Data("File".utf8)])
        let lowercase = try makeVector(pathComponents: [Data("file".utf8)])
        let composed = try makeVector(pathComponents: [Data([0xC3, 0xA9])])
        let decomposed = try makeVector(pathComponents: [Data([0x65, 0xCC, 0x81])])

        XCTAssertNotEqual(
            try fingerprint(uppercase, borrowed: borrowed, keyMaterial: keyMaterial),
            try fingerprint(lowercase, borrowed: borrowed, keyMaterial: keyMaterial)
        )
        XCTAssertNotEqual(
            try fingerprint(composed, borrowed: borrowed, keyMaterial: keyMaterial),
            try fingerprint(decomposed, borrowed: borrowed, keyMaterial: keyMaterial)
        )
    }

    func testBorrowedFieldChangeChangesFingerprint() throws {
        let keyMaterial = try makeKeyMaterial()
        let vector = try makeVector()

        XCTAssertNotEqual(
            try fingerprint(vector, borrowed: Data([0x10, 0x20]), keyMaterial: keyMaterial),
            try fingerprint(vector, borrowed: Data([0x10, 0x21]), keyMaterial: keyMaterial)
        )
    }

    func testPathFramingCannotExceedVerifiedFourThousandNinetySixByteBound() throws {
        var components = Array(repeating: Data(repeating: 0x61, count: 31), count: 127)
        components.append(Data(repeating: 0x62, count: 32))
        let maximumPath = try verifiedPath(components)
        XCTAssertEqual(maximumPath.components.count, 128)
        XCTAssertEqual(maximumPath.rawByteCount, 4_096)

        let maximumVector = FramedMACTestVector(
            fixedInteger: 0x01020304,
            fixedBytes: Data([0x00, 0xFF]),
            relativePath: maximumPath
        )
        XCTAssertNoThrow(
            try fingerprint(
                maximumVector,
                borrowed: Data([0x10]),
                keyMaterial: makeKeyMaterial()
            )
        )

        components[127] = Data(repeating: 0x62, count: 33)
        XCTAssertThrowsError(try verifiedPath(components)) { error in
            XCTAssertEqual(error as? ContainmentError, .pathTooLong)
        }
    }

    func testFieldBoundaryAmbiguityCannotCollide() throws {
        let keyMaterial = try makeKeyMaterial()
        let left = try makeVector(fixedBytes: Data("ab".utf8))
        let right = try makeVector(fixedBytes: Data("a".utf8))

        XCTAssertNotEqual(
            try fingerprint(left, borrowed: Data("c".utf8), keyMaterial: keyMaterial),
            try fingerprint(right, borrowed: Data("bc".utf8), keyMaterial: keyMaterial)
        )
    }

    func testFixedPrimitiveDomainAndTagsMatchGoldenFrame() throws {
        let goldenFrame = data(hex: """
            00000006010000000000000043636f6d2e6c756b65726f772e50656172636c65616e65722e70726f6a6563742d7363616e6e65722e7375707072657373696f6e2e6672616d696e672d746573742e7631020000000000000004000000010300000000000000040102030404000000000000000200ff050000000000000017000000020000000000000001410000000000000002ff80060000000000000003102030
            """)
        let pinnedHMAC = data(hex: "40d35045a3a7c9ebe78578e8c2b4ce36d027d145dc9cec4bf9cb13af85acd622")
        let keyBytes = Data(0..<32)
        let keyMaterial = try makeKeyMaterial(keyBytes: keyBytes)
        let vector = try makeVector()
        let borrowed = Data([0x10, 0x20, 0x30])

        XCTAssertEqual(try hmacSHA256(message: goldenFrame, key: keyBytes), pinnedHMAC)
        XCTAssertEqual(
            SuppressionFingerprintPersistence.encode(
                try fingerprint(vector, borrowed: borrowed, keyMaterial: keyMaterial)
            ),
            pinnedHMAC
        )
    }

    func testBorrowedFieldUsesANonOwningDataView() throws {
        let keyMaterial = try makeKeyMaterial()
        let vector = try makeVector()
        let borrowed = Data(repeating: 0xA5, count: 4_097)

        let aliasesSource = try borrowed.withUnsafeBytes {
            try FramedMACTestSupport.borrowedFieldViewAliasesSource(
                vector,
                borrowedField: $0,
                keyMaterial: keyMaterial
            )
        }

        XCTAssertTrue(aliasesSource)
    }

    func testPersistenceBridgeRejectsAnythingOtherThanThirtyTwoBytes() throws {
        XCTAssertThrowsError(
            try SuppressionFingerprintPersistence.decode(Data(repeating: 0x00, count: 31))
        ) { error in
            XCTAssertEqual(error as? FingerprintError, .invalidFingerprintLength)
        }
        XCTAssertThrowsError(
            try SuppressionFingerprintPersistence.decode(Data(repeating: 0x00, count: 33))
        ) { error in
            XCTAssertEqual(error as? FingerprintError, .invalidFingerprintLength)
        }

        let bytes = Data(0..<32)
        let fingerprint = try SuppressionFingerprintPersistence.decode(bytes)
        XCTAssertEqual(SuppressionFingerprintPersistence.encode(fingerprint), bytes)
    }

    func testSecureStorageRecordRoundTripsFixedVersionAndLength() throws {
        let keyBytes = Data(0..<32)
        let generation = try XCTUnwrap(UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"))
        let expectedRecord = data(hex: """
            0100112233445566778899aabbccddeeff000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
            """)

        XCTAssertThrowsError(
            try ProjectKeyMaterial(generation: generation, keyBytes: Data(repeating: 0x00, count: 31))
        ) { error in
            XCTAssertEqual(error as? FingerprintError, .invalidKeyLength)
        }
        XCTAssertThrowsError(
            try ProjectKeyMaterial(generation: generation, keyBytes: Data(repeating: 0x00, count: 33))
        ) { error in
            XCTAssertEqual(error as? FingerprintError, .invalidKeyLength)
        }

        let original = try ProjectKeyMaterial(generation: generation, keyBytes: keyBytes)
        XCTAssertEqual(original.secureStorageRecord().count, 49)
        XCTAssertEqual(original.secureStorageRecord(), expectedRecord)

        let decoded = try ProjectKeyMaterial(secureStorageRecord: expectedRecord)
        XCTAssertEqual(decoded.generation, generation)
        XCTAssertEqual(decoded.secureStorageRecord(), expectedRecord)
    }

    func testSecureStorageRecordRejectsUnknownVersionOrLength() throws {
        var unknownVersion = data(hex: """
            0100112233445566778899aabbccddeeff000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
            """)
        XCTAssertEqual(unknownVersion.count, 49)
        unknownVersion[unknownVersion.startIndex] = 0x02

        XCTAssertThrowsError(try ProjectKeyMaterial(secureStorageRecord: unknownVersion)) { error in
            XCTAssertEqual(error as? FingerprintError, .invalidSecureStorageRecord)
        }
        XCTAssertThrowsError(
            try ProjectKeyMaterial(secureStorageRecord: Data(unknownVersion.dropLast()))
        ) { error in
            XCTAssertEqual(error as? FingerprintError, .invalidSecureStorageRecord)
        }
        XCTAssertThrowsError(
            try ProjectKeyMaterial(secureStorageRecord: unknownVersion + Data([0x00]))
        ) { error in
            XCTAssertEqual(error as? FingerprintError, .invalidSecureStorageRecord)
        }
    }
}

private func makeKeyMaterial(keyBytes: Data = Data(0..<32)) throws -> ProjectKeyMaterial {
    try ProjectKeyMaterial(
        generation: UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!,
        keyBytes: keyBytes
    )
}

private func makeVector(
    fixedBytes: Data = Data([0x00, 0xFF]),
    pathComponents: [Data] = [Data([0x41]), Data([0xFF, 0x80])]
) throws -> FramedMACTestVector {
    FramedMACTestVector(
        fixedInteger: 0x01020304,
        fixedBytes: fixedBytes,
        relativePath: try verifiedPath(pathComponents)
    )
}

private func verifiedPath(_ components: [Data]) throws -> VerifiedRelativePath {
    try VerifiedRelativePath(components: components.map(VerifiedPathComponent.init(bytes:)))
}

private func fingerprint(
    _ vector: FramedMACTestVector,
    borrowed: Data,
    keyMaterial: ProjectKeyMaterial
) throws -> SuppressionFingerprint {
    try borrowed.withUnsafeBytes {
        try FramedMACTestSupport.fingerprint(
            vector,
            borrowedField: $0,
            keyMaterial: keyMaterial
        )
    }
}

private func data(hex: String) -> Data {
    let compact = hex.filter { !$0.isWhitespace }
    precondition(compact.count.isMultiple(of: 2))
    var result = Data()
    result.reserveCapacity(compact.count / 2)
    var index = compact.startIndex
    while index < compact.endIndex {
        let next = compact.index(index, offsetBy: 2)
        result.append(UInt8(compact[index..<next], radix: 16)!)
        index = next
    }
    return result
}
