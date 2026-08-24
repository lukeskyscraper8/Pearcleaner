import Foundation
import XCTest
@testable import ProjectScannerCore

final class ScanLimitsTests: XCTestCase {
    func testDefaultsAndHardCeilingsMatchTheApprovedSpec() {
        XCTAssertEqual(ScanLimits.defaults.generalFiles, 100_000)
        XCTAssertEqual(ScanLimits.hardCeilings.generalFiles, 500_000)
        XCTAssertEqual(ScanLimits.defaults.secretFileBytes, 5 * 1_024 * 1_024)
        XCTAssertEqual(ScanLimits.hardCeilings.secretFileBytes, 50 * 1_024 * 1_024)
        XCTAssertEqual(ScanLimits.defaults.lockfileBytes, 50 * 1_024 * 1_024)
        XCTAssertEqual(ScanLimits.hardCeilings.lockfileBytes, 100 * 1_024 * 1_024)
        XCTAssertEqual(ScanLimits.defaults.manifestBytes, 2 * 1_024 * 1_024)
        XCTAssertEqual(ScanLimits.hardCeilings.manifestBytes, 4 * 1_024 * 1_024)
        XCTAssertEqual(ScanLimits.defaults.installedManifests, 50_000)
        XCTAssertEqual(ScanLimits.hardCeilings.installedManifests, 100_000)
        XCTAssertEqual(ScanLimits.defaults.directories, 50_000)
        XCTAssertEqual(ScanLimits.hardCeilings.directories, 200_000)
        XCTAssertEqual(ScanLimits.defaults.directoryEntries, 250_000)
        XCTAssertEqual(ScanLimits.hardCeilings.directoryEntries, 1_000_000)
        XCTAssertEqual(ScanLimits.defaults.dependencyNodesPerLockfile, 250_000)
        XCTAssertEqual(ScanLimits.hardCeilings.dependencyNodesPerLockfile, 1_000_000)
        XCTAssertEqual(ScanLimits.defaults.dependencyNodesPerSession, 500_000)
        XCTAssertEqual(ScanLimits.hardCeilings.dependencyNodesPerSession, 2_000_000)
        XCTAssertEqual(ScanLimits.defaults.inputBytes, 2 * 1_024 * 1_024 * 1_024)
        XCTAssertEqual(ScanLimits.hardCeilings.inputBytes, 8 * 1_024 * 1_024 * 1_024)
        XCTAssertEqual(ScanLimits.defaults.wallTimeMilliseconds, 5 * 60 * 1_000)
        XCTAssertEqual(ScanLimits.hardCeilings.wallTimeMilliseconds, 30 * 60 * 1_000)
        XCTAssertEqual(ScanLimits.defaults.traversalDepth, 128)
        XCTAssertEqual(ScanLimits.defaults.relativePathBytes, 4_096)
        XCTAssertEqual(ScanLimits.defaults.structuredDataDepth, 128)
        XCTAssertEqual(ScanLimits.defaults.parsedScalarBytes, 1 * 1_024 * 1_024)
        XCTAssertEqual(ScanLimits.defaults.findingsPerFile, 2_000)
        XCTAssertEqual(ScanLimits.defaults.findingsPerSession, 10_000)
        XCTAssertEqual(ScanLimits.defaults.maximumLinkHops, 16)
        XCTAssertEqual(ScanLimits.defaults.gitMetadataDescriptors, 1_024)
        XCTAssertEqual(ScanLimits.defaults.gitDescriptorReserve, 128)
        XCTAssertEqual(ScanLimits.defaults.gitOperationMilliseconds, 30_000)
        XCTAssertEqual(ScanLimits.defaults.gitOutputBytes, 32 * 1_024 * 1_024)
        XCTAssertEqual(ScanLimits.defaults.retainedInputBytes, 256 * 1_024 * 1_024)
        XCTAssertEqual(ScanLimits.defaults.parserArenaBytes, 256 * 1_024 * 1_024)
        XCTAssertEqual(ScanLimits.defaults.findingModelBytes, 128 * 1_024 * 1_024)
        XCTAssertEqual(ScanLimits.defaults.rssSoftBytes, 512 * 1_024 * 1_024)
        XCTAssertEqual(ScanLimits.defaults.rssHardBytes, 1_024 * 1_024 * 1_024)
        XCTAssertEqual(ScanLimits.defaults.progressIntervalMilliseconds, 250)
        XCTAssertEqual(ScanLimits.defaults.cancellationLatencyMilliseconds, 500)
        XCTAssertEqual(ScanLimits.defaults.activeWorkers, 4)
        XCTAssertEqual(ScanLimits.defaults.activeProjectScans, 1)

        XCTAssertEqual(ScanLimits.hardCeilings.traversalDepth, ScanLimits.defaults.traversalDepth)
        XCTAssertEqual(ScanLimits.hardCeilings.activeWorkers, ScanLimits.defaults.activeWorkers)
        XCTAssertEqual(ScanLimits.hardCeilings.rssHardBytes, ScanLimits.defaults.rssHardBytes)
    }

    func testOverrideAboveHardCeilingIsRejectedRatherThanClamped() {
        let overrides = ScanLimitOverrides(generalFiles: 500_001)

        XCTAssertThrowsError(try overrides.applying(to: .defaults)) { error in
            XCTAssertEqual(error as? ScanLimitError, .exceedsHardCeiling(.generalFiles))
        }
    }

    func testOverrideZeroValueIsRejected() {
        let overrides = ScanLimitOverrides(generalFiles: 0)

        XCTAssertThrowsError(try overrides.applying(to: .defaults)) { error in
            XCTAssertEqual(error as? ScanLimitError, .invalidValue(.generalFiles))
        }
    }

    func testStrictDecoderRejectsUnknownAndFixedFields() throws {
        let unknown = try XCTUnwrap(#"{"generalFiles": 1, "futureLimit": 2}"#.data(using: .utf8))
        let fixed = try XCTUnwrap(#"{"activeWorkers": 2}"#.data(using: .utf8))

        XCTAssertThrowsError(try JSONDecoder().decode(ScanLimitOverrides.self, from: unknown))
        XCTAssertThrowsError(try JSONDecoder().decode(ScanLimitOverrides.self, from: fixed))
    }

    func testOnlyFieldsWithHigherCeilingsAreOverridable() throws {
        let overrides = ScanLimitOverrides(
            generalFiles: 100_001,
            secretFileBytes: 5 * 1_024 * 1_024 + 1,
            lockfileBytes: 50 * 1_024 * 1_024 + 1,
            manifestBytes: 2 * 1_024 * 1_024 + 1,
            installedManifests: 50_001,
            directories: 50_001,
            directoryEntries: 250_001,
            dependencyNodesPerLockfile: 250_001,
            dependencyNodesPerSession: 500_001,
            inputBytes: 2 * 1_024 * 1_024 * 1_024 + 1,
            wallTimeMilliseconds: 300_001
        )
        let limits = try overrides.applying(to: .defaults)

        XCTAssertEqual(limits.generalFiles, 100_001)
        XCTAssertEqual(limits.secretFileBytes, 5 * 1_024 * 1_024 + 1)
        XCTAssertEqual(limits.lockfileBytes, 50 * 1_024 * 1_024 + 1)
        XCTAssertEqual(limits.manifestBytes, 2 * 1_024 * 1_024 + 1)
        XCTAssertEqual(limits.installedManifests, 50_001)
        XCTAssertEqual(limits.directories, 50_001)
        XCTAssertEqual(limits.directoryEntries, 250_001)
        XCTAssertEqual(limits.dependencyNodesPerLockfile, 250_001)
        XCTAssertEqual(limits.dependencyNodesPerSession, 500_001)
        XCTAssertEqual(limits.inputBytes, 2 * 1_024 * 1_024 * 1_024 + 1)
        XCTAssertEqual(limits.wallTimeMilliseconds, 300_001)
        XCTAssertEqual(limits.activeWorkers, ScanLimits.defaults.activeWorkers)
    }
}
