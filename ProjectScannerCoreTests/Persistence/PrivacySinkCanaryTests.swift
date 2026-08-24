import Foundation
import XCTest
@testable import ProjectScannerCore

final class PrivacySinkCanaryTests: XCTestCase {
    func testStateIsNeverWrittenToSelectedRootUserDefaultsOrAppGroup() async throws {
        let fixture = try await StateStoreFixture.make(); defer { fixture.remove() }
        let selectedMarker = fixture.selectedRoot.appendingPathComponent("privacy-marker")
        let appGroup = fixture.parentURL.deletingLastPathComponent().appendingPathComponent("AppGroupCanary")
        try FileManager.default.createDirectory(at: appGroup, withIntermediateDirectories: true)
        let appGroupMarker = appGroup.appendingPathComponent("marker")
        let allCanaryBytes = Data(PrivacyCanaries.all.joined(separator: "|").utf8)
        try allCanaryBytes.write(to: appGroupMarker)
        let selectedSnapshot = try Data(contentsOf: selectedMarker)
        let appGroupSnapshot = try Data(contentsOf: appGroupMarker)
        let outsideSnapshot = try Data(contentsOf: fixture.outsideCanary)
        let suite = "ProjectStatePrivacy-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(PrivacyCanaries.all.joined(separator: "|"), forKey: "canary")
        let registration = try await fixture.register(label: PrivacyCanaries.label)
        _ = try await fixture.store.recordAttempt(projectID: registration.projectID, coverage: nonCompleteCoverage(.partial), finishedAt: Date(timeIntervalSince1970: 1), metadata: try AttemptSummaryMetadata(advisoryCacheSchemaVersion: nil, advisory: nil), lease: fixture.lease)
        _ = try await fixture.store.addSuppression(projectID: registration.projectID, record: try privacySuppression(), lease: fixture.lease)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.selectedRoot.path), ["privacy-marker"])
        XCTAssertEqual(try Data(contentsOf: selectedMarker), selectedSnapshot)
        XCTAssertEqual(defaults.string(forKey: "canary"), PrivacyCanaries.all.joined(separator: "|"))
        XCTAssertEqual(try Data(contentsOf: appGroupMarker), appGroupSnapshot)
        XCTAssertEqual(try Data(contentsOf: fixture.outsideCanary), outsideSnapshot)
        let stateNames = try FileManager.default.contentsOfDirectory(atPath: fixture.stateDirectory.path)
        XCTAssertFalse(stateNames.contains(where: { $0.hasSuffix("-wal") || $0.hasSuffix("-journal") || $0.hasSuffix("-shm") || $0.hasSuffix(".sqlite") }))
    }

    func testPersistentBytesExcludeFindingPathPackageVersionAdvisoryScriptAndSecret() async throws {
        let fixture = try await StateStoreFixture.make(); defer { fixture.remove() }
        let registration = try await fixture.register(label: PrivacyCanaries.label)
        _ = try await fixture.store.recordAttempt(projectID: registration.projectID, coverage: completeCoverage(), finishedAt: Date(timeIntervalSince1970: 1), metadata: try testAttemptMetadata(), lease: fixture.lease)
        _ = try await fixture.store.addSuppression(projectID: registration.projectID, record: try privacySuppression(), lease: fixture.lease)
        let bytes = try Data(contentsOf: fixture.stateFile)
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.contains(PrivacyCanaries.label))
        for canary in PrivacyCanaries.all { XCTAssertFalse(text.contains(canary), "Persisted forbidden canary") }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(object["label"] as? String, PrivacyCanaries.label)
        let bookmarkBase64 = try XCTUnwrap(object["bookmark"] as? String)
        let decodedBookmark = try XCTUnwrap(Data(base64Encoded: bookmarkBase64))
        XCTAssertNotNil(decodedBookmark.range(of: Data(fixture.selectedRoot.path.utf8)))
        XCTAssertNotNil(decodedBookmark.range(of: Data(PrivacyCanaries.path.utf8)))
        for (path, rendered) in flattenedJSON(object) where path != "label" && path != "bookmark" {
            for canary in PrivacyCanaries.all + [PrivacyCanaries.label] { XCTAssertFalse(rendered.contains(canary), "Canary escaped into \(path)") }
        }
    }

    func testLogsErrorsAndTemporaryNamesExcludePrivacyCanaries() async throws {
        let fixture = try await StateStoreFixture.make(); defer { fixture.remove() }
        let registration = try await fixture.register(label: PrivacyCanaries.label)
        let operations = ScriptedStateFileSystemOperations(failingSite: .syncStagingFile, failure: .failBefore(5))
        let failingStore = try await ProjectStateStore(parent: fixture.parent, keyCoordinator: fixture.coordinator, uuid: ScriptedUUID([UUID()]), operations: operations, backupOperations: SystemBackupExclusionOperations())
        let before = try Data(contentsOf: fixture.stateFile)
        do { _ = try await failingStore.recordAttempt(projectID: registration.projectID, coverage: nonCompleteCoverage(.failed), finishedAt: Date(timeIntervalSince1970: 2), metadata: try AttemptSummaryMetadata(advisoryCacheSchemaVersion: nil, advisory: nil), lease: fixture.lease); XCTFail("Injected write failure ignored") }
        catch {
            let renderedError = String(describing: error)
            let renderedEvents = operations.snapshot().map(\.rawValue).joined(separator: ",")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: fixture.stateDirectory.path)) ?? []
            for canary in PrivacyCanaries.all + [PrivacyCanaries.label] {
                XCTAssertFalse(renderedError.contains(canary)); XCTAssertFalse(renderedEvents.contains(canary))
                XCTAssertFalse(names.contains(where: { $0.contains(canary) }))
            }
            XCTAssertFalse(names.contains(where: { $0.hasSuffix(".tmp") }))
            XCTAssertEqual(try Data(contentsOf: fixture.stateFile), before)
            XCTAssertEqual(try Data(contentsOf: fixture.outsideCanary), fixture.outsideSnapshot)
        }
    }
}

private func flattenedJSON(_ value: Any, path: String = "") -> [(String, String)] {
    if let dictionary = value as? [String: Any] {
        return dictionary.keys.sorted().flatMap { key in flattenedJSON(dictionary[key]!, path: path.isEmpty ? key : "\(path).\(key)") }
    }
    if let array = value as? [Any] {
        return array.enumerated().flatMap { flattenedJSON($0.element, path: "\(path)[\($0.offset)]") }
    }
    return [(path, String(describing: value))]
}

private func privacySuppression() throws -> SuppressionRecord {
    try SuppressionRecord(
        fingerprint: SuppressionFingerprintPersistence.decode(Data(repeating: 0xC7, count: 32)),
        ruleID: RuleID(rawValue: "privacy-rule")!, ruleVersion: 1,
        createdAt: Date(timeIntervalSince1970: 1)
    )
}
