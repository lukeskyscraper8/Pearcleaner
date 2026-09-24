import Foundation
import GitEvidenceShared
import XCTest

final class FeasibilityManifestSignatureTests: XCTestCase {
    func testManifestWithoutSignaturesDecodesAndIsNotProductionSigned() throws {
        let json = """
        {"schemaVersion":1,"pearcleanerVersion":"5.4.5","harnessVersion":"5.4.5","runnerVersion":"1.0.0",
         "appleGitVersion":"git version 2.54.0 (Apple Git-157)","osBuildFamily":"macOS-27.0.0-26A428",
         "architecture":"arm64","testTimestamp":"2026-09-24T04:57:36Z","overallStatus":"passed","scenarios":[]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(FeasibilityManifest.self, from: Data(json.utf8))

        XCTAssertNil(manifest.runnerSignature)
        XCTAssertFalse(manifest.isProductionSigned)
    }

    func testProductionSignedNeedsEverySignatureDeveloperIDAndNotarized() {
        let good = signature(developerID: true, notarized: true)
        let unnotarized = signature(developerID: true, notarized: false)

        XCTAssertTrue(manifest(harness: good, service: good, runner: good).isProductionSigned)
        XCTAssertFalse(manifest(harness: good, service: good, runner: unnotarized).isProductionSigned)
        XCTAssertFalse(manifest(harness: good, service: nil, runner: good).isProductionSigned)
    }

    func testSignaturesRoundTrip() throws {
        let original = manifest(
            harness: signature(developerID: true, notarized: true),
            service: signature(developerID: false, notarized: false),
            runner: nil
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(FeasibilityManifest.self, from: original.encodedJSON())

        XCTAssertEqual(decoded, original)
    }

    private func signature(developerID: Bool, notarized: Bool) -> FeasibilityCodeSignature {
        FeasibilityCodeSignature(
            identifier: "com.lukerow.Pearcleaner.GitRunner",
            teamIdentifier: "68583N3MNF",
            cdhash: "00",
            leafAuthority: "Developer ID Application: Example (68583N3MNF)",
            developerIDSigned: developerID,
            notarized: notarized
        )
    }

    private func manifest(
        harness: FeasibilityCodeSignature?,
        service: FeasibilityCodeSignature?,
        runner: FeasibilityCodeSignature?
    ) -> FeasibilityManifest {
        FeasibilityManifest(
            pearcleanerVersion: "5.4.5",
            harnessVersion: "5.4.5",
            runnerVersion: "1.0.0",
            appleGitVersion: "git version 2.54.0 (Apple Git-157)",
            osBuildFamily: "macOS-27.0.0-26A428",
            architecture: "arm64",
            testTimestamp: Date(timeIntervalSince1970: 1_790_000_000),
            overallStatus: .passed,
            scenarios: [],
            harnessSignature: harness,
            serviceSignature: service,
            runnerSignature: runner
        )
    }
}
