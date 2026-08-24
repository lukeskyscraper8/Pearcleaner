import CryptoKit
import Foundation

enum FingerprintError: Error, Equatable {
    case invalidKeyLength
    case invalidFingerprintLength
    case invalidSecureStorageRecord
    case invalidFieldLength
    case invalidPath
    case tooFewFields
    case tooManyFields
}

public struct ProjectKeyMaterial: Sendable {
    public let generation: UUID
    internal let key: SymmetricKey

    init(generation: UUID, keyBytes: Data) throws {
        guard keyBytes.count == 32 else {
            throw FingerprintError.invalidKeyLength
        }
        self.generation = generation
        key = SymmetricKey(data: keyBytes)
    }

    public init(secureStorageRecord: Data) throws {
        guard secureStorageRecord.count == 49 else {
            throw FingerprintError.invalidSecureStorageRecord
        }
        guard secureStorageRecord[secureStorageRecord.startIndex] == 0x01 else {
            throw FingerprintError.invalidSecureStorageRecord
        }

        let bytes = [UInt8](secureStorageRecord)
        generation = UUID(uuid: (
            bytes[1], bytes[2], bytes[3], bytes[4],
            bytes[5], bytes[6], bytes[7], bytes[8],
            bytes[9], bytes[10], bytes[11], bytes[12],
            bytes[13], bytes[14], bytes[15], bytes[16]
        ))
        key = SymmetricKey(data: Data(bytes[17..<49]))
    }

    public func secureStorageRecord() -> Data {
        var record = Data([0x01])
        var uuid = generation.uuid
        withUnsafeBytes(of: &uuid) { record.append(contentsOf: $0) }
        key.withUnsafeBytes { record.append(contentsOf: $0) }
        return record
    }
}

public struct SuppressionFingerprint: Sendable, Equatable, Hashable {
    fileprivate let bytes: Data

    fileprivate init(validatedBytes: Data) throws {
        guard validatedBytes.count == 32 else {
            throw FingerprintError.invalidFingerprintLength
        }
        bytes = validatedBytes
    }
}

enum SuppressionFingerprintPersistence {
    static func encode(_ value: SuppressionFingerprint) -> Data {
        value.bytes
    }

    static func decode(_ bytes: Data) throws -> SuppressionFingerprint {
        try SuppressionFingerprint(validatedBytes: bytes)
    }
}

struct FramedMACTestVector: Sendable {
    let fixedInteger: UInt32
    let fixedBytes: Data
    let relativePath: VerifiedRelativePath
}

func hmacSHA256(message: Data, key: Data) throws -> Data {
    let key = SymmetricKey(data: key)
    return Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
}

enum FramedMACTestSupport {
    private static let domain = Data(
        "com.lukerow.Pearcleaner.project-scanner.suppression.framing-test.v1".utf8
    )

    static func fingerprint(
        _ vector: FramedMACTestVector,
        borrowedField: UnsafeRawBufferPointer,
        keyMaterial: ProjectKeyMaterial
    ) throws -> SuppressionFingerprint {
        var framer = SuppressionMACFramer(keyMaterial: keyMaterial, fieldCount: 6)
        try updateFixedFields(&framer, vector: vector, domainTag: 0x01)
        try framer.updateBorrowedField(tag: 0x06, bytes: borrowedField)
        return try framer.finalize()
    }

    static func fingerprintWithAlternateDomainTag(
        _ vector: FramedMACTestVector,
        borrowedField: UnsafeRawBufferPointer,
        keyMaterial: ProjectKeyMaterial
    ) throws -> SuppressionFingerprint {
        var framer = SuppressionMACFramer(keyMaterial: keyMaterial, fieldCount: 6)
        try updateFixedFields(&framer, vector: vector, domainTag: 0x7F)
        try framer.updateBorrowedField(tag: 0x06, bytes: borrowedField)
        return try framer.finalize()
    }

    static func borrowedFieldViewAliasesSource(
        _ vector: FramedMACTestVector,
        borrowedField: UnsafeRawBufferPointer,
        keyMaterial: ProjectKeyMaterial
    ) throws -> Bool {
        var framer = SuppressionMACFramer(keyMaterial: keyMaterial, fieldCount: 6)
        try updateFixedFields(&framer, vector: vector, domainTag: 0x01)
        let aliasesSource = try framer.updateBorrowedFieldObservingAlias(
            tag: 0x06,
            bytes: borrowedField
        )
        _ = try framer.finalize()
        return aliasesSource
    }

    static func finalizeWithTooFewFields(keyMaterial: ProjectKeyMaterial) throws {
        var framer = SuppressionMACFramer(keyMaterial: keyMaterial, fieldCount: 1)
        _ = try framer.finalize()
    }

    static func finalizeWithTooManyFields(keyMaterial: ProjectKeyMaterial) throws {
        var framer = SuppressionMACFramer(keyMaterial: keyMaterial, fieldCount: 0)
        do {
            try framer.updateField(tag: 0x01, bytes: Data())
        } catch FingerprintError.tooManyFields {
            // Finalization must preserve and report the overrun state.
        } catch {
            throw error
        }
        _ = try framer.finalize()
    }

    private static func updateFixedFields(
        _ framer: inout SuppressionMACFramer,
        vector: FramedMACTestVector,
        domainTag: UInt8
    ) throws {
        try framer.updateField(tag: domainTag, bytes: domain)
        try framer.updateUInt32Field(tag: 0x02, value: ScannerModule.schemaVersion)
        try framer.updateUInt32Field(tag: 0x03, value: vector.fixedInteger)
        try framer.updateField(tag: 0x04, bytes: vector.fixedBytes)
        try framer.updatePathField(tag: 0x05, path: vector.relativePath)
    }
}

fileprivate struct SuppressionMACFramer {
    private var hmac: HMAC<SHA256>
    private var remainingFields: UInt32
    private var hasTooManyFields: Bool

    init(keyMaterial: ProjectKeyMaterial, fieldCount: UInt32) {
        hmac = HMAC<SHA256>(key: keyMaterial.key)
        remainingFields = fieldCount
        hasTooManyFields = false
        hmac.update(data: encodedUInt32(fieldCount))
    }

    mutating func updateField(tag: UInt8, bytes: Data) throws {
        guard let byteCount = UInt64(exactly: bytes.count) else {
            throw FingerprintError.invalidFieldLength
        }
        try updateFieldHeader(tag: tag, byteCount: byteCount)
        hmac.update(data: bytes)
    }

    mutating func updateUInt32Field(tag: UInt8, value: UInt32) throws {
        try updateField(tag: tag, bytes: encodedUInt32(value))
    }

    mutating func updatePathField(tag: UInt8, path: VerifiedRelativePath) throws {
        let componentCount = path.components.count
        guard (1...128).contains(componentCount),
              let encodedComponentCount = UInt32(exactly: componentCount) else {
            throw FingerprintError.invalidPath
        }

        var rawByteCount: UInt64 = 0
        var framedByteCount: UInt64 = 4
        for (index, component) in path.components.enumerated() {
            let bytes = component.bytes
            guard !bytes.isEmpty,
                  bytes.count <= 255,
                  !bytes.contains(0),
                  !bytes.contains(0x2F),
                  bytes != Data([0x2E]),
                  bytes != Data([0x2E, 0x2E]),
                  let componentByteCount = UInt64(exactly: bytes.count) else {
                throw FingerprintError.invalidPath
            }

            let (rawWithComponent, rawComponentOverflow) = rawByteCount.addingReportingOverflow(
                componentByteCount
            )
            guard !rawComponentOverflow else { throw FingerprintError.invalidPath }
            rawByteCount = rawWithComponent
            if index > 0 {
                let (rawWithSeparator, separatorOverflow) = rawByteCount.addingReportingOverflow(1)
                guard !separatorOverflow else { throw FingerprintError.invalidPath }
                rawByteCount = rawWithSeparator
            }

            let (framedWithLength, framedLengthOverflow) = framedByteCount.addingReportingOverflow(8)
            guard !framedLengthOverflow else { throw FingerprintError.invalidFieldLength }
            let (framedWithComponent, framedComponentOverflow) = framedWithLength
                .addingReportingOverflow(componentByteCount)
            guard !framedComponentOverflow else { throw FingerprintError.invalidFieldLength }
            framedByteCount = framedWithComponent
        }

        guard rawByteCount == path.rawByteCount, rawByteCount <= 4_096 else {
            throw FingerprintError.invalidPath
        }

        try updateFieldHeader(tag: tag, byteCount: framedByteCount)
        hmac.update(data: encodedUInt32(encodedComponentCount))
        for component in path.components {
            guard let componentByteCount = UInt64(exactly: component.bytes.count) else {
                throw FingerprintError.invalidFieldLength
            }
            hmac.update(data: encodedUInt64(componentByteCount))
            hmac.update(data: component.bytes)
        }
    }

    mutating func updateBorrowedField(
        tag: UInt8,
        bytes: UnsafeRawBufferPointer
    ) throws {
        _ = try updateBorrowedField(tag: tag, bytes: bytes, observeAlias: false)
    }

    mutating func updateBorrowedFieldObservingAlias(
        tag: UInt8,
        bytes: UnsafeRawBufferPointer
    ) throws -> Bool {
        try updateBorrowedField(tag: tag, bytes: bytes, observeAlias: true)
    }

    mutating func finalize() throws -> SuppressionFingerprint {
        guard !hasTooManyFields else {
            throw FingerprintError.tooManyFields
        }
        guard remainingFields == 0 else {
            throw FingerprintError.tooFewFields
        }
        return try SuppressionFingerprint(validatedBytes: Data(hmac.finalize()))
    }

    private mutating func updateBorrowedField(
        tag: UInt8,
        bytes: UnsafeRawBufferPointer,
        observeAlias: Bool
    ) throws -> Bool {
        guard let byteCount = UInt64(exactly: bytes.count) else {
            throw FingerprintError.invalidFieldLength
        }
        try updateFieldHeader(tag: tag, byteCount: byteCount)
        guard !bytes.isEmpty else { return !observeAlias }
        guard let baseAddress = bytes.baseAddress else {
            throw FingerprintError.invalidFieldLength
        }

        let view = BorrowedHMACDataView(bytes)
        let aliasesSource = view.withUnsafeBytes { $0.baseAddress == baseAddress }
        hmac.update(data: view)
        return observeAlias && aliasesSource
    }

    private mutating func updateFieldHeader(tag: UInt8, byteCount: UInt64) throws {
        guard remainingFields > 0 else {
            hasTooManyFields = true
            throw FingerprintError.tooManyFields
        }
        hmac.update(data: Data([tag]))
        hmac.update(data: encodedUInt64(byteCount))
        remainingFields -= 1
    }
}

fileprivate struct BorrowedHMACDataView: RandomAccessCollection, ContiguousBytes, DataProtocol {
    typealias Element = UInt8
    typealias Index = Int
    typealias SubSequence = Slice<BorrowedHMACDataView>
    typealias Regions = CollectionOfOne<UnsafeRawBufferPointer>

    private let bytes: UnsafeRawBufferPointer

    init(_ bytes: UnsafeRawBufferPointer) {
        precondition(!bytes.isEmpty)
        self.bytes = bytes
    }

    var startIndex: Int { bytes.startIndex }
    var endIndex: Int { bytes.endIndex }
    var regions: Regions { CollectionOfOne(bytes) }

    subscript(position: Int) -> UInt8 {
        bytes[position]
    }

    func withUnsafeBytes<Result>(
        _ body: (UnsafeRawBufferPointer) throws -> Result
    ) rethrows -> Result {
        try body(bytes)
    }
}

@available(*, unavailable)
extension BorrowedHMACDataView: Sendable {}

private func encodedUInt32(_ value: UInt32) -> Data {
    var bigEndian = value.bigEndian
    return withUnsafeBytes(of: &bigEndian) { Data($0) }
}

private func encodedUInt64(_ value: UInt64) -> Data {
    var bigEndian = value.bigEndian
    return withUnsafeBytes(of: &bigEndian) { Data($0) }
}
