import Foundation
import XCTest
@testable import ProjectScannerCore

final class SecretFingerprintTests: XCTestCase {
    func testSameInputsProduceSameSecretSuppressionFingerprint() throws {
        let keyMaterial = try makeKeyMaterial()
        let input = try makeInput()

        let first = try fingerprint(input, keyMaterial: keyMaterial)
        let second = try fingerprint(input, keyMaterial: keyMaterial)

        XCTAssertEqual(first, second)
    }

    func testProjectUUIDChangeChangesSecretSuppressionFingerprint() throws {
        let keyMaterial = try makeKeyMaterial()
        let input = try makeInput()
        let alternate = SecretFingerprintInput(
            projectID: ProjectID(rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!),
            path: input.path,
            ruleID: input.ruleID,
            ruleVersion: input.ruleVersion,
            matchIdentity: input.matchIdentity
        )

        XCTAssertNotEqual(
            try fingerprint(input, keyMaterial: keyMaterial),
            try fingerprint(alternate, keyMaterial: keyMaterial)
        )
    }

    func testRuleVersionChangeChangesSecretSuppressionFingerprint() throws {
        let keyMaterial = try makeKeyMaterial()
        let input = try makeInput()
        let alternate = SecretFingerprintInput(
            projectID: input.projectID,
            path: input.path,
            ruleID: input.ruleID,
            ruleVersion: input.ruleVersion + 1,
            matchIdentity: input.matchIdentity
        )

        XCTAssertNotEqual(
            try fingerprint(input, keyMaterial: keyMaterial),
            try fingerprint(alternate, keyMaterial: keyMaterial)
        )
    }

    func testPathChangeChangesSecretSuppressionFingerprint() throws {
        let keyMaterial = try makeKeyMaterial()
        let input = try makeInput()
        let alternatePath = try verifiedPath("other.env")
        let alternate = SecretFingerprintInput(
            projectID: input.projectID,
            path: alternatePath,
            ruleID: input.ruleID,
            ruleVersion: input.ruleVersion,
            matchIdentity: input.matchIdentity
        )

        XCTAssertNotEqual(
            try fingerprint(input, keyMaterial: keyMaterial),
            try fingerprint(alternate, keyMaterial: keyMaterial)
        )
    }

    func testMatchIdentityChangeChangesSecretSuppressionFingerprint() throws {
        let keyMaterial = try makeKeyMaterial()
        let input = try makeInput()
        let alternateIdentity = try alternateIdentity(for: input.matchIdentity)
        let alternate = SecretFingerprintInput(
            projectID: input.projectID,
            path: input.path,
            ruleID: input.ruleID,
            ruleVersion: input.ruleVersion,
            matchIdentity: alternateIdentity
        )

        XCTAssertNotEqual(
            try fingerprint(input, keyMaterial: keyMaterial),
            try fingerprint(alternate, keyMaterial: keyMaterial)
        )
    }

    func testDomainSeparationChangesSecretSuppressionFingerprint() throws {
        let keyMaterial = try makeKeyMaterial()
        let input = try makeInput()

        let standard = try fingerprint(input, keyMaterial: keyMaterial)
        let alternate = try SecretSuppressionFingerprintTestSupport.fingerprintWithAlternateDomain(
            projectID: input.projectID,
            path: input.path,
            ruleID: input.ruleID,
            ruleVersion: input.ruleVersion,
            matchIdentity: input.matchIdentity,
            keyMaterial: keyMaterial
        )

        XCTAssertNotEqual(standard, alternate)
    }

    func testSecretSuppressionFingerprintMatchesDirectHMACOfCanonicalMessage() throws {
        let keyBytes = Data(0..<32)
        let keyMaterial = try makeKeyMaterial(keyBytes: keyBytes)
        let input = try makeInput(
            projectID: ProjectID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!),
            pathComponents: [Data("config.env".utf8)],
            token: "ghp_" + String(repeating: "a", count: 36)
        )
        let message = try secretSuppressionMessage(for: input)
        let digest = try hmacSHA256(message: message, key: keyBytes)

        XCTAssertEqual(
            SuppressionFingerprintPersistence.encode(try fingerprint(input, keyMaterial: keyMaterial)),
            digest
        )
    }

    func testSecretCanaryNeverAppearsInCorrelatedSessionStoreOrDiagnostics() async throws {
        let path = try verifiedPath(PrivacyCanaries.path)
        let token = "ghp_" + String(repeating: "a", count: 36)
        let identityKey = try SecretMatchIdentityKey.makeEphemeral()
        let match = try XCTUnwrap(
            SecretDetector().scanData(
                Data("export const token = \"\(token)\";".utf8),
                identityKey: identityKey
            ).first
        )
        let displayPath = try XCTUnwrap(path.escapedForDisplay())
        let correlator = SecretMatchCorrelator()
        let correlated = correlator.correlate(
            observations: [
                SecretMatchObservation(path: path, sourceView: .workingTree, match: match, displayPath: displayPath),
                SecretMatchObservation(path: path, sourceView: .index, match: match, displayPath: displayPath),
            ],
            gitFacts: nil
        )
        let keyLease = try persistentLease()
        let projectID = ProjectID(rawValue: UUID())
        let transaction = CoverageTransactionID(rawValue: UUID())
        let findings = try correlator.makeSessionFindings(
            from: try XCTUnwrap(correlated.first),
            transaction: transaction,
            projectID: projectID,
            keyLease: keyLease
        )

        let store = SessionStore(limits: .defaults)
        for finding in findings {
            let appendResult = await store.append(finding)
            XCTAssertEqual(appendResult, .appended)
        }
        let snapshot = await store.snapshot()

        let sink = RecordingSecretDiagnosticSink()
        await sink.record(
            ScannerDiagnosticEvent(
                sessionID: ScanSessionID(rawValue: UUID()),
                detector: .secret,
                code: .detectorFinished,
                reason: nil,
                count: UInt64(findings.count),
                bytes: nil,
                durationMilliseconds: 12,
                systemCategory: nil
            )
        )
        let events = await sink.snapshot()

        XCTAssertFalse(snapshot.compactMap(\.evidence?.text).joined().contains(token))
        XCTAssertTrue(snapshot.allSatisfy { $0.evidence?.text.contains("[REDACTED]") == true })
        XCTAssertEqual(snapshot.first?.displayPath?.text, PrivacyCanaries.path)
        for canary in PrivacyCanaries.all where canary != PrivacyCanaries.path {
            XCTAssertFalse(snapshot.compactMap(\.evidence?.text).joined().contains(canary))
            XCTAssertFalse(snapshot.compactMap(\.displayPath?.text).joined().contains(canary))
        }
        for canary in PrivacyCanaries.all {
            XCTAssertFalse(events.flatMap(allDiagnosticStrings).contains { $0.contains(canary) })
        }
        XCTAssertEqual(
            try correlator.suppressionFingerprint(
                observation: try XCTUnwrap(correlated.first?.observations.first),
                projectID: projectID,
                keyMaterial: keyLease.material
            ),
            try SecretSuppressionFingerprintEncoder.fingerprint(
                projectID: projectID,
                path: path,
                ruleID: match.ruleID,
                ruleVersion: match.ruleVersion,
                matchIdentity: match.identity,
                keyMaterial: keyLease.material
            )
        )
    }

    func testSecretSuppressionPersistsWithoutRawSecretBytes() async throws {
        let fixture = try await StateStoreFixture.make()
        defer { fixture.remove() }
        let registration = try await fixture.register(label: PrivacyCanaries.label)
        let observation = try makePrivacyObservation()
        let correlator = SecretMatchCorrelator()
        let fingerprint = try correlator.suppressionFingerprint(
            observation: observation,
            projectID: registration.projectID,
            keyMaterial: fixture.lease.material
        )
        let record = try SuppressionRecord(
            fingerprint: fingerprint,
            ruleID: observation.match.ruleID,
            ruleVersion: observation.match.ruleVersion,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        _ = try await fixture.store.addSuppression(
            projectID: registration.projectID,
            record: record,
            lease: fixture.lease
        )

        let bytes = try Data(contentsOf: fixture.stateFile)
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(text.contains(PrivacyCanaries.secret))
        XCTAssertTrue(text.contains(PrivacyCanaries.label))
    }
}

private struct SecretFingerprintInput {
    let projectID: ProjectID
    let path: VerifiedRelativePath
    let ruleID: RuleID
    let ruleVersion: UInt32
    let matchIdentity: SecretMatchIdentity
}

private actor RecordingSecretDiagnosticSink: ScannerDiagnosticSinking {
    private var events: [ScannerDiagnosticEvent] = []

    func record(_ event: ScannerDiagnosticEvent) async {
        events.append(event)
    }

    func snapshot() -> [ScannerDiagnosticEvent] {
        events
    }
}

private func makeInput(
    projectID: ProjectID = ProjectID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!),
    pathComponents: [Data] = [Data("config.env".utf8)],
    token: String = "ghp_" + String(repeating: "a", count: 36)
) throws -> SecretFingerprintInput {
    let path = try verifiedPath(pathComponents)
    let identityKey = try SecretMatchIdentityKey.makeEphemeral()
    let match = try XCTUnwrap(
        SecretDetector().scanData(Data(token.utf8), identityKey: identityKey).first
    )
    return SecretFingerprintInput(
        projectID: projectID,
        path: path,
        ruleID: match.ruleID,
        ruleVersion: match.ruleVersion,
        matchIdentity: match.identity
    )
}

private func fingerprint(
    _ input: SecretFingerprintInput,
    keyMaterial: ProjectKeyMaterial
) throws -> SuppressionFingerprint {
    try SecretSuppressionFingerprintEncoder.fingerprint(
        projectID: input.projectID,
        path: input.path,
        ruleID: input.ruleID,
        ruleVersion: input.ruleVersion,
        matchIdentity: input.matchIdentity,
        keyMaterial: keyMaterial
    )
}

private func alternateIdentity(for identity: SecretMatchIdentity) throws -> SecretMatchIdentity {
    let identityKey = try SecretMatchIdentityKey.makeEphemeral()
    let match = try XCTUnwrap(
        SecretDetector().scanData(
            Data("ghp_\(String(repeating: "b", count: 36))".utf8),
            identityKey: identityKey
        ).first
    )
    XCTAssertNotEqual(match.identity, identity)
    return match.identity
}

private func makePrivacyObservation() throws -> SecretMatchObservation {
    let path = try verifiedPath(PrivacyCanaries.path)
    let identityKey = try SecretMatchIdentityKey.makeEphemeral()
    let token = "ghp_" + String(repeating: "a", count: 36)
    let match = try XCTUnwrap(
        SecretDetector().scanData(
            Data("token=\(token)".utf8),
            identityKey: identityKey
        ).first
    )
    return SecretMatchObservation(
        path: path,
        sourceView: .workingTree,
        match: match,
        displayPath: try XCTUnwrap(path.escapedForDisplay())
    )
}

private func secretSuppressionMessage(for input: SecretFingerprintInput) throws -> Data {
    var message = Data()
    message.append(encodedUInt32(8))

    let domain = Data(
        "com.lukerow.Pearcleaner.project-scanner.suppression.secret.v1".utf8
    )
    try appendField(to: &message, tag: 0x01, bytes: domain)
    try appendField(to: &message, tag: 0x02, bytes: encodedUInt32(ScannerModule.schemaVersion))

    var projectUUID = input.projectID.rawValue.uuid
    try appendField(to: &message, tag: 0x03, bytes: withUnsafeBytes(of: &projectUUID) { Data($0) })
    try appendField(
        to: &message,
        tag: 0x04,
        bytes: Data(FindingKind.probableSecret.rawValue.utf8)
    )
    try appendField(to: &message, tag: 0x05, bytes: Data(input.ruleID.rawValue.utf8))
    try appendField(to: &message, tag: 0x06, bytes: encodedUInt32(input.ruleVersion))
    try appendPathField(to: &message, tag: 0x07, path: input.path)
    try appendField(to: &message, tag: 0x08, bytes: input.matchIdentity.suppressionFieldBytes)
    return message
}

private func appendField(to message: inout Data, tag: UInt8, bytes: Data) throws {
    message.append(tag)
    message.append(encodedUInt64(UInt64(bytes.count)))
    message.append(bytes)
}

private func appendPathField(
    to message: inout Data,
    tag: UInt8,
    path: VerifiedRelativePath
) throws {
    var framed = Data()
    framed.append(encodedUInt32(UInt32(path.components.count)))
    for component in path.components {
        framed.append(encodedUInt64(UInt64(component.bytes.count)))
        framed.append(component.bytes)
    }
    try appendField(to: &message, tag: tag, bytes: framed)
}

private func encodedUInt32(_ value: UInt32) -> Data {
    var bigEndian = value.bigEndian
    return withUnsafeBytes(of: &bigEndian) { Data($0) }
}

private func encodedUInt64(_ value: UInt64) -> Data {
    var bigEndian = value.bigEndian
    return withUnsafeBytes(of: &bigEndian) { Data($0) }
}

private func verifiedPath(_ components: [Data]) throws -> VerifiedRelativePath {
    try VerifiedRelativePath(components: components.map(VerifiedPathComponent.init(bytes:)))
}

private func verifiedPath(_ name: String) throws -> VerifiedRelativePath {
    try verifiedPath([Data(name.utf8)])
}

private func makeKeyMaterial(keyBytes: Data = Data(0..<32)) throws -> ProjectKeyMaterial {
    try ProjectKeyMaterial(
        generation: UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!,
        keyBytes: keyBytes
    )
}

private func persistentLease() throws -> ProjectKeyLease {
    ProjectKeyLease.persistent(try makeKeyMaterial())
}

private func allDiagnosticStrings(_ event: ScannerDiagnosticEvent) -> [String] {
    [
        event.sessionID.rawValue.uuidString,
        event.detector?.rawValue,
        event.code.rawValue,
        event.reason?.rawValue,
        event.systemCategory?.rawValue,
    ].compactMap { $0 }
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
