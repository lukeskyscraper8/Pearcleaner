//
//  LipoSafetyTests.swift
//  PearcleanerTests
//
//  Added for the independently maintained Pearcleaner fork.
//

import Foundation
import Security
import Darwin
import XCTest
@testable import Pearcleaner

final class LipoSafetyTests: XCTestCase {
    func testMutationEligibilityFailsClosed() {
        XCTAssertEqual(
            AppBundleMutationSafety.classify(
                hasCodeResources: true,
                staticCodeStatus: errSecSuccess,
                signingInformationStatus: errSecCSUnsigned
            ),
            .signed
        )
        XCTAssertEqual(
            AppBundleMutationSafety.classify(
                hasCodeResources: false,
                staticCodeStatus: errSecSuccess,
                signingInformationStatus: errSecSuccess,
                hasSignatureInformation: true
            ),
            .signed
        )
        XCTAssertEqual(
            AppBundleMutationSafety.classify(
                hasCodeResources: false,
                staticCodeStatus: errSecSuccess,
                signingInformationStatus: errSecSuccess,
                hasSignatureInformation: false
            ),
            .unsigned
        )
        XCTAssertEqual(
            AppBundleMutationSafety.classify(
                hasCodeResources: false,
                staticCodeStatus: errSecSuccess,
                signingInformationStatus: errSecSuccess,
                hasSignatureInformation: nil
            ),
            .uninspectable
        )
        XCTAssertEqual(
            AppBundleMutationSafety.classify(
                hasCodeResources: false,
                staticCodeStatus: errSecParam,
                signingInformationStatus: nil
            ),
            .uninspectable
        )
    }

    func testSliceRangeRejectsOverflowAndOutOfFileBounds() {
        XCTAssertNil(
            MachOSafety.validatedSliceRange(
                offset: UInt64.max - 2,
                size: 8,
                fileSize: UInt64.max
            )
        )
        XCTAssertNil(
            MachOSafety.validatedSliceRange(
                offset: 90,
                size: 11,
                fileSize: 100
            )
        )
        XCTAssertEqual(
            MachOSafety.validatedSliceRange(
                offset: 20,
                size: 30,
                fileSize: 100
            ),
            20..<50
        )
    }

    func testMalformedFatSliceDoesNotModifyFile() throws {
        let fileURL = temporaryFileURL()
        var malformed = Data()
        appendBigEndian(MachOSafety.fatMagic, to: &malformed)
        appendBigEndian(UInt32(1), to: &malformed)
        appendBigEndian(MachOSafety.arm64CPUType, to: &malformed)
        appendBigEndian(UInt32(0), to: &malformed)
        appendBigEndian(UInt32.max - 4, to: &malformed)
        appendBigEndian(UInt32(10), to: &malformed)
        appendBigEndian(UInt32(0), to: &malformed)
        try malformed.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        XCTAssertFalse(
            thinMachOBinary(
                at: fileURL,
                targetCPUType: MachOSafety.arm64CPUType
            )
        )
        XCTAssertEqual(try Data(contentsOf: fileURL), malformed)
    }

    func testDryRunInspectionDoesNotModifyFatBinary() throws {
        let fileURL = temporaryFileURL()
        let binary = makeValidFatBinary()
        try binary.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let sizes = try XCTUnwrap(
            getArchitectureSliceSizes(from: fileURL.path)
        )

        XCTAssertEqual(sizes.arm, 16)
        XCTAssertEqual(sizes.intel, 16)
        XCTAssertEqual(try Data(contentsOf: fileURL), binary)
    }

    func testThinningUsesAtomicReplacementAndPreservesExecutableMode() throws {
        let fileURL = temporaryFileURL()
        let binary = makeValidFatBinary()
        try binary.write(to: fileURL)
        try FileManager.default.setAttributes(
            [
                .posixPermissions: 0o755,
                .modificationDate: Date(timeIntervalSince1970: 1_700_000_000)
            ],
            ofItemAtPath: fileURL.path
        )
        let originalAttributes = try FileManager.default.attributesOfItem(
            atPath: fileURL.path
        )
        let attributeName = "com.pearcleaner.tests.lipo"
        let attributeValue = Data("metadata".utf8)
        let setAttributeResult = attributeValue.withUnsafeBytes { bytes in
            setxattr(
                fileURL.path,
                attributeName,
                bytes.baseAddress,
                bytes.count,
                0,
                0
            )
        }
        XCTAssertEqual(setAttributeResult, 0)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        XCTAssertTrue(
            thinMachOBinary(
                at: fileURL,
                targetCPUType: MachOSafety.arm64CPUType
            )
        )

        XCTAssertEqual(try Data(contentsOf: fileURL), makeThinSlice(
            cpuType: MachOSafety.arm64CPUType,
            marker: 0xAA
        ))
        let attributes = try FileManager.default.attributesOfItem(
            atPath: fileURL.path
        )
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o755
        )
        XCTAssertEqual(
            (attributes[.ownerAccountID] as? NSNumber)?.uint64Value,
            (originalAttributes[.ownerAccountID] as? NSNumber)?.uint64Value
        )
        XCTAssertEqual(
            (attributes[.groupOwnerAccountID] as? NSNumber)?.uint64Value,
            (originalAttributes[.groupOwnerAccountID] as? NSNumber)?.uint64Value
        )
        XCTAssertEqual(
            attributes[.modificationDate] as? Date,
            originalAttributes[.modificationDate] as? Date
        )

        let attributeLength = getxattr(
            fileURL.path,
            attributeName,
            nil,
            0,
            0,
            0
        )
        XCTAssertEqual(attributeLength, attributeValue.count)
        var restoredAttribute = Data(count: max(attributeLength, 0))
        let restoredLength = restoredAttribute.withUnsafeMutableBytes { bytes in
            getxattr(
                fileURL.path,
                attributeName,
                bytes.baseAddress,
                bytes.count,
                0,
                0
            )
        }
        XCTAssertEqual(restoredLength, attributeValue.count)
        XCTAssertEqual(restoredAttribute, attributeValue)
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "Pearcleaner-LipoSafety-\(UUID().uuidString)"
        )
    }

    private func makeValidFatBinary() -> Data {
        let armSlice = makeThinSlice(
            cpuType: MachOSafety.arm64CPUType,
            marker: 0xAA
        )
        let intelSlice = makeThinSlice(
            cpuType: MachOSafety.x86_64CPUType,
            marker: 0xBB
        )
        let armOffset: UInt32 = 64
        let intelOffset: UInt32 = armOffset + UInt32(armSlice.count)

        var data = Data()
        appendBigEndian(MachOSafety.fatMagic, to: &data)
        appendBigEndian(UInt32(2), to: &data)

        appendBigEndian(MachOSafety.arm64CPUType, to: &data)
        appendBigEndian(UInt32(0), to: &data)
        appendBigEndian(armOffset, to: &data)
        appendBigEndian(UInt32(armSlice.count), to: &data)
        appendBigEndian(UInt32(0), to: &data)

        appendBigEndian(MachOSafety.x86_64CPUType, to: &data)
        appendBigEndian(UInt32(0), to: &data)
        appendBigEndian(intelOffset, to: &data)
        appendBigEndian(UInt32(intelSlice.count), to: &data)
        appendBigEndian(UInt32(0), to: &data)

        data.append(Data(repeating: 0, count: Int(armOffset) - data.count))
        data.append(armSlice)
        data.append(intelSlice)
        return data
    }

    private func makeThinSlice(cpuType: UInt32, marker: UInt8) -> Data {
        var data = Data()
        appendLittleEndian(UInt32(0xfeedfacf), to: &data)
        appendLittleEndian(cpuType, to: &data)
        data.append(Data(repeating: marker, count: 8))
        return data
    }

    private func appendBigEndian(_ value: UInt32, to data: inout Data) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) {
            data.append(contentsOf: $0)
        }
    }

    private func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        var encoded = value.littleEndian
        withUnsafeBytes(of: &encoded) {
            data.append(contentsOf: $0)
        }
    }
}
