//
//  SettingsExportCodecTests.swift
//  PearcleanerTests
//
//  Added for the independently maintained Pearcleaner fork.
//

import XCTest
@testable import Pearcleaner

final class SettingsExportCodecTests: XCTestCase {
    func testRoundTripsDataAndPropertyListValues() throws {
        let hiddenPages = Data([0, 2, 4, 8])
        let exported = try SettingsExportCodec.exportData(from: [
            "settings.interface.hiddenPages": hiddenPages,
            "settings.interface.enabled": true,
            "settings.interface.scale": 1.25,
            "unrelated.key": "must not be exported"
        ])

        let imported = try SettingsExportCodec.importSettings(
            from: exported,
            allowedKeys: [
                "settings.interface.hiddenPages",
                "settings.interface.enabled",
                "settings.interface.scale"
            ]
        )

        XCTAssertEqual(imported["settings.interface.hiddenPages"] as? Data, hiddenPages)
        XCTAssertEqual(imported["settings.interface.enabled"] as? Bool, true)
        XCTAssertEqual(imported["settings.interface.scale"] as? Double, 1.25)
        XCTAssertNil(imported["unrelated.key"])
    }

    func testRoundTripsNestedDateAndDataValues() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let data = Data([1, 3, 5, 7])
        let exported = try SettingsExportCodec.exportData(from: [
            "settings.nested": [
                "values": [date, data]
            ]
        ])

        let imported = try SettingsExportCodec.importSettings(
            from: exported,
            allowedKeys: ["settings.nested"]
        )
        let nested = try XCTUnwrap(imported["settings.nested"] as? [String: Any])
        let values = try XCTUnwrap(nested["values"] as? [Any])

        XCTAssertEqual(values[0] as? Date, date)
        XCTAssertEqual(values[1] as? Data, data)
    }

    func testImportIgnoresKeysOutsideSettingsNamespace() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "settings.valid": true,
            "arbitrary.default": "rejected"
        ])

        let imported = try SettingsExportCodec.importSettings(
            from: data,
            allowedKeys: ["settings.valid"]
        )

        XCTAssertEqual(imported.keys.sorted(), ["settings.valid"])
    }

    func testImportRejectsMalformedTaggedData() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "settings.data": [
                "__pearcleaner_type": "data",
                "value": "not-base64!"
            ]
        ])

        XCTAssertThrowsError(try SettingsExportCodec.importSettings(from: data))
    }

    func testImportRejectsJSONNull() {
        let data = Data(#"{"settings.invalid":null}"#.utf8)

        XCTAssertThrowsError(try SettingsExportCodec.importSettings(from: data))
    }

    func testExportRejectsURLValues() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/settings"))

        XCTAssertThrowsError(try SettingsExportCodec.exportData(from: [
            "settings.invalid": ["nested": url]
        ]))
    }

    func testImportRejectsTaggedURLValues() {
        let data = Data(
            #"{"settings.invalid":{"__pearcleaner_type":"url","value":"https://example.com"}}"#
                .utf8
        )

        XCTAssertThrowsError(try SettingsExportCodec.importSettings(from: data))
    }
}
