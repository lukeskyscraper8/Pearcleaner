import Foundation
import GitEvidenceShared
import XCTest

final class GitOutputParserTests: XCTestCase {
    func testValidNulDelimitedPaths() throws {
        let data = Data("src/main.swift\u{0}tests/Unit.swift\u{0}".utf8)
        let paths = try GitOutputParser.parseNulDelimitedPaths(from: data)
        XCTAssertEqual(paths, ["src/main.swift", "tests/Unit.swift"])
    }

    func testRejectsEmptyPathComponent() {
        let data = Data("src//main.swift\u{0}".utf8)

        XCTAssertThrowsError(try GitOutputParser.parseNulDelimitedPaths(from: data)) { error in
            XCTAssertEqual(error as? GitOutputParserError, .invalidPathComponent(""))
        }
    }

    func testRejectsDotDotComponent() {
        let data = Data("src/../secret\u{0}".utf8)

        XCTAssertThrowsError(try GitOutputParser.parseNulDelimitedPaths(from: data)) { error in
            XCTAssertEqual(error as? GitOutputParserError, .invalidPathComponent(".."))
        }
    }

    func testRejectsMalformedOID() {
        let data = Data("100644 blob notanoid\tREADME\u{0}".utf8)

        XCTAssertThrowsError(
            try GitOutputParser.parseLsTreeRecords(from: data, hashAlgorithm: .sha1)
        ) { error in
            XCTAssertEqual(error as? GitOutputParserError, .malformedOID("notanoid"))
        }
    }

    func testRejectsOutOfOrderCatFileResponses() throws {
        let expectedFirst = String(repeating: "a", count: 40)
        let expectedSecond = String(repeating: "b", count: 40)
        let actualFirst = String(repeating: "b", count: 40)
        let chunk = Data("\(actualFirst) blob 5\u{0A}hello\u{0A}".utf8)

        var parser = try GitCatFileBatchHeaderParser(
            expectedOIDs: [expectedFirst, expectedSecond],
            hashAlgorithm: .sha1
        )

        XCTAssertThrowsError(try parser.append(chunk)) { error in
            XCTAssertEqual(
                error as? GitOutputParserError,
                .outOfOrderCatFileResponse(expected: expectedFirst, actual: actualFirst)
            )
        }
    }

    func testParsesValidCatFileHeaders() throws {
        let firstOID = String(repeating: "1", count: 40)
        let secondOID = String(repeating: "2", count: 40)
        let chunk = Data(
            "\(firstOID) blob 5\u{0A}hello\u{0A}\(secondOID) blob 5\u{0A}world\u{0A}".utf8
        )

        var parser = try GitCatFileBatchHeaderParser(
            expectedOIDs: [firstOID, secondOID],
            hashAlgorithm: .sha1
        )
        let firstBatch = try parser.append(chunk)
        let secondBatch = try parser.append(Data())
        let headers = firstBatch + secondBatch

        XCTAssertEqual(headers.count, 2)
        XCTAssertEqual(headers[0].oid, firstOID)
        XCTAssertEqual(headers[0].type, "blob")
        XCTAssertEqual(headers[0].size, 5)
        XCTAssertEqual(headers[1].oid, secondOID)
        XCTAssertEqual(headers[1].type, "blob")
        XCTAssertEqual(headers[1].size, 5)
        try parser.finish()
    }
}
