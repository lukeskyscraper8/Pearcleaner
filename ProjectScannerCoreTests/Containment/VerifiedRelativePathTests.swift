import Foundation
import XCTest
@testable import ProjectScannerCore

final class VerifiedRelativePathTests: XCTestCase {
    func testRawComponentsPreserveCaseAndBytesWithoutUnicodeFolding() throws {
        let uppercase = Data("File".utf8)
        let lowercase = Data("file".utf8)
        let composed = Data([0xC3, 0xA9])
        let decomposed = Data([0x65, 0xCC, 0x81])

        let components = try [uppercase, lowercase, composed, decomposed]
            .map(VerifiedPathComponent.init(bytes:))
        let path = try VerifiedRelativePath(components: components)

        XCTAssertEqual(path.identityComponents, [uppercase, lowercase, composed, decomposed])
        XCTAssertNotEqual(components[0], components[1])
        XCTAssertNotEqual(components[2], components[3])
    }

    func testComponentRejectsEmptyDotDotDotSlashAndNUL() throws {
        let invalidComponents = [
            Data(),
            Data(".".utf8),
            Data("..".utf8),
            Data("a/b".utf8),
            Data([0x61, 0x00, 0x62]),
        ]

        for bytes in invalidComponents {
            XCTAssertThrowsError(try VerifiedPathComponent(bytes: bytes)) { error in
                XCTAssertEqual(error as? ContainmentError, .invalidSelection)
            }
        }

        XCTAssertThrowsError(try VerifiedPathComponent(bytes: Data(repeating: 0x61, count: 256))) { error in
            XCTAssertEqual(error as? ContainmentError, .pathTooLong)
        }
    }

    func testRelativePathCountsRawBytesIncludingSeparators() throws {
        let path = try VerifiedRelativePath(components: [
            VerifiedPathComponent(bytes: Data([0xC3, 0xA9])),
            VerifiedPathComponent(bytes: Data("abc".utf8)),
        ])

        XCTAssertEqual(path.rawByteCount, 6)

        let boundary = try VerifiedRelativePath(components: (0..<16).map { _ in
            try VerifiedPathComponent(bytes: Data(repeating: 0x61, count: 255))
        })
        XCTAssertEqual(boundary.rawByteCount, 4_095)

        let tooLong = boundary.components + [try VerifiedPathComponent(bytes: Data([0x62]))]
        XCTAssertThrowsError(try VerifiedRelativePath(components: tooLong)) { error in
            XCTAssertEqual(error as? ContainmentError, .pathTooLong)
        }
    }

    func testRelativePathRejectsMoreThanOneHundredTwentyEightComponents() throws {
        let component = try VerifiedPathComponent(bytes: Data([0x61]))

        XCTAssertNoThrow(try VerifiedRelativePath(components: Array(repeating: component, count: 128)))
        XCTAssertThrowsError(
            try VerifiedRelativePath(components: Array(repeating: component, count: 129))
        ) { error in
            XCTAssertEqual(error as? ContainmentError, .pathTooLong)
        }
    }

    func testDisplayEscapesInvalidUTF8ControlsAndBidirectionalScalars() throws {
        let mixed = try VerifiedPathComponent(bytes: Data([
            0x6F, 0x6B,
            0xFF,
            0xC2, 0xA3,
            0x0A,
            0xC2, 0x85,
            0xE2, 0x80, 0xAA,
            0xF0, 0x9F, 0x98, 0x80,
            0xC3,
            0x5A,
        ]))
        let bidiIsolate = try VerifiedPathComponent(bytes: Data([0xE2, 0x81, 0xA6]))
        let path = try VerifiedRelativePath(components: [mixed, bidiIsolate])

        XCTAssertEqual(
            path.escapedForDisplay().text,
            "ok\\xFF£\\u{A}\\u{85}\\u{202A}😀\\xC3Z/\\u{2066}"
        )
    }
}
