import XCTest
@testable import ProjectScannerCore

final class ScannerModuleTests: XCTestCase {
    func testSchemaStartsAtOne() {
        XCTAssertEqual(ScannerModule.schemaVersion, 1)
    }
}
