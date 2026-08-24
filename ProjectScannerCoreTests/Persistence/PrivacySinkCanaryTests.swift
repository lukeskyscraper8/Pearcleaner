import Darwin
import Foundation
import XCTest
@testable import ProjectScannerCore

final class PrivacySinkCanaryTests: XCTestCase {
    func testStateIsNeverWrittenToSelectedRootUserDefaultsOrAppGroup() async throws {
        let fixture = try await StateStoreFixture.make(); defer { fixture.remove() }
        let selectedMarker = fixture.selectedRoot.appendingPathComponent("privacy-marker")
        let selectedSnapshot = try Data(contentsOf: selectedMarker)
        let outsideSnapshot = try Data(contentsOf: fixture.outsideCanary)

        let registration = try await fixture.register(label: PrivacyCanaries.label)
        _ = try await fixture.store.recordAttempt(projectID: registration.projectID, coverage: nonCompleteCoverage(.partial), finishedAt: Date(timeIntervalSince1970: 1), metadata: try AttemptSummaryMetadata(advisoryCacheSchemaVersion: nil, advisory: nil), lease: fixture.lease)
        _ = try await fixture.store.addSuppression(
            projectID: registration.projectID,
            record: try privacySuppression(for: fixture).record,
            lease: fixture.lease
        )

        let failingOperations = ScriptedStateFileSystemOperations(
            failingSite: .syncStagingFile,
            failure: .failBefore(EIO)
        )
        let failingStore = try await ProjectStateStore(
            parent: fixture.parent,
            keyCoordinator: fixture.coordinator,
            uuid: ScriptedUUID([UUID()]),
            operations: failingOperations,
            backupOperations: SystemBackupExclusionOperations()
        )
        await XCTAssertThrowsProjectState(.stateUnavailable) {
            _ = try await failingStore.recordAttempt(
                projectID: registration.projectID,
                coverage: nonCompleteCoverage(.failed),
                finishedAt: Date(timeIntervalSince1970: 2),
                metadata: try AttemptSummaryMetadata(
                    advisoryCacheSchemaVersion: nil,
                    advisory: nil
                ),
                lease: fixture.lease
            )
        }

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.selectedRoot.path), ["privacy-marker"])
        XCTAssertEqual(try Data(contentsOf: selectedMarker), selectedSnapshot)
        XCTAssertEqual(try Data(contentsOf: fixture.outsideCanary), outsideSnapshot)
        XCTAssertFalse(
            recursiveFixtureNames(under: fixture.parentURL.deletingLastPathComponent())
                .contains(where: isPersistenceSidecar),
            "A recursive disposable-container search found a forbidden persistence sidecar"
        )
    }

    func testPersistentBytesExcludeFindingPathPackageVersionAdvisoryScriptAndSecret() async throws {
        let fixture = try await StateStoreFixture.make(); defer { fixture.remove() }
        let registration = try await fixture.register(label: PrivacyCanaries.label)
        _ = try await fixture.store.recordAttempt(projectID: registration.projectID, coverage: completeCoverage(), finishedAt: Date(timeIntervalSince1970: 1), metadata: try testAttemptMetadata(), lease: fixture.lease)
        let suppression = try privacySuppression(for: fixture)
        _ = try await fixture.store.addSuppression(
            projectID: registration.projectID,
            record: suppression.record,
            lease: fixture.lease
        )
        let bytes = try Data(contentsOf: fixture.stateFile)
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.contains(PrivacyCanaries.label))
        for canary in PrivacyCanaries.all { XCTAssertFalse(text.contains(canary), "Persisted forbidden canary") }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(object["label"] as? String, PrivacyCanaries.label)
        let suppressions = try XCTUnwrap(object["suppressions"] as? [[String: Any]])
        let persistedSuppression = try XCTUnwrap(suppressions.first)
        XCTAssertEqual(
            persistedSuppression["fingerprint"] as? String,
            suppression.encodedFingerprint,
            "The persisted fingerprint must be derived from the canary-bearing scanner fields"
        )
        let bookmarkBase64 = try XCTUnwrap(object["bookmark"] as? String)
        let decodedBookmark = try XCTUnwrap(Data(base64Encoded: bookmarkBase64))
        XCTAssertNotNil(decodedBookmark.range(of: Data(fixture.selectedRoot.path.utf8)))
        XCTAssertNotNil(decodedBookmark.range(of: Data(PrivacyCanaries.path.utf8)))
        for canary in PrivacyCanaries.all where canary != PrivacyCanaries.path {
            XCTAssertNil(decodedBookmark.range(of: Data(canary.utf8)))
        }
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
            let names = recursiveFixtureNames(
                under: fixture.parentURL.deletingLastPathComponent()
            )
            XCTAssertNotNil(error as? ProjectStateError)
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

private struct PrivacySuppressionFixture {
    let record: SuppressionRecord
    let encodedFingerprint: String
}

private func privacySuppression(
    for fixture: StateStoreFixture
) throws -> PrivacySuppressionFixture {
    let path = try VerifiedRelativePath(components: [
        try VerifiedPathComponent(bytes: Data(PrivacyCanaries.path.utf8)),
    ])
    let vector = FramedMACTestVector(
        fixedInteger: 1,
        fixedBytes: framedPrivacyFixedBytes(),
        relativePath: path
    )
    let secret = Data(PrivacyCanaries.secret.utf8)
    let fingerprint = try secret.withUnsafeBytes {
        try FramedMACTestSupport.fingerprint(
            vector,
            borrowedField: $0,
            keyMaterial: fixture.lease.material
        )
    }
    let encodedFingerprint = SuppressionFingerprintPersistence.encode(fingerprint)
        .base64EncodedString()
    let record = try SuppressionRecord(
        fingerprint: fingerprint,
        ruleID: RuleID(rawValue: "privacy-rule")!, ruleVersion: 1,
        createdAt: Date(timeIntervalSince1970: 1)
    )
    return PrivacySuppressionFixture(
        record: record,
        encodedFingerprint: encodedFingerprint
    )
}

private func framedPrivacyFixedBytes() -> Data {
    var result = Data()
    for value in [
        PrivacyCanaries.package,
        PrivacyCanaries.version,
        PrivacyCanaries.advisory,
        PrivacyCanaries.script,
    ] {
        let bytes = Data(value.utf8)
        var length = UInt32(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        result.append(bytes)
    }
    return result
}

private func recursiveFixtureNames(under root: URL) -> [String] {
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: nil
    ) else { return [] }
    var names: [String] = []
    while let url = enumerator.nextObject() as? URL {
        names.append(url.path.replacingOccurrences(of: root.path, with: ""))
    }
    return names
}

private func isPersistenceSidecar(_ name: String) -> Bool {
    let lowercased = name.lowercased()
    return lowercased.hasSuffix("-wal")
        || lowercased.hasSuffix("-journal")
        || lowercased.hasSuffix("-shm")
        || lowercased.hasSuffix(".sqlite")
}
