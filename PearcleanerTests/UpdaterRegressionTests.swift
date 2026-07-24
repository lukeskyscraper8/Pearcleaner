//
//  UpdaterRegressionTests.swift
//  PearcleanerTests
//
//  Added for the independently maintained Pearcleaner fork.
//

import Foundation
import XCTest
@testable import Pearcleaner

final class UpdaterRegressionTests: XCTestCase {
    func testVersionComparisonChecksAllTrailingComponents() {
        let extended = Version(versionNumber: "1.2.0.1", buildNumber: nil)
        let short = Version(versionNumber: "1.2", buildNumber: nil)

        XCTAssertGreaterThan(extended, short)
        XCTAssertLessThan(short, extended)
        XCTAssertEqual(
            Version(versionNumber: "1.2.0.0", buildNumber: nil),
            short
        )
    }

    func testVersionComparisonIsSymmetricAndReflexive() {
        let first = Version(versionNumber: "1", buildNumber: "1")
        let second = Version(versionNumber: "1", buildNumber: "2")
        let empty = Version(versionNumber: nil, buildNumber: nil)

        XCTAssertEqual(first == second, second == first)
        XCTAssertFalse(first == second)
        XCTAssertTrue(first < second)
        XCTAssertTrue(second > first)
        XCTAssertEqual(empty, empty)
        XCTAssertFalse(empty < empty)
    }

    func testVersionComparisonIsTransitive() {
        let first = Version(versionNumber: "1", buildNumber: "1")
        let second = Version(versionNumber: "1", buildNumber: "2")
        let third = Version(versionNumber: "1", buildNumber: "3")

        XCTAssertTrue(first < second)
        XCTAssertTrue(second < third)
        XCTAssertTrue(first < third)
    }

    func testVersionComparisonOrdersMissingBuildMetadataDeterministically() {
        let noBuild = Version(versionNumber: "1", buildNumber: nil)
        let firstBuild = Version(versionNumber: "1", buildNumber: "1")
        let secondBuild = Version(versionNumber: "1", buildNumber: "2")

        XCTAssertLessThan(noBuild, firstBuild)
        XCTAssertLessThan(firstBuild, secondBuild)
        XCTAssertLessThan(noBuild, secondBuild)
        XCTAssertGreaterThan(firstBuild, noBuild)
        XCTAssertNotEqual(noBuild, firstBuild)
    }

    func testVersionComparisonDoesNotMixBuildAndDisplayVersion() {
        let installed = Version(versionNumber: "1.2", buildNumber: "100")
        let remote = Version(versionNumber: "1.3", buildNumber: nil)

        XCTAssertLessThan(installed, remote)
        XCTAssertGreaterThan(remote, installed)
        XCTAssertFalse(installed == remote)
        XCTAssertFalse(remote == installed)
    }

    func testVersionComparisonComparableLawsAcrossMissingMetadata() {
        let versions = [
            Version(versionNumber: nil, buildNumber: nil),
            Version(versionNumber: nil, buildNumber: "1"),
            Version(versionNumber: nil, buildNumber: "2"),
            Version(versionNumber: "1", buildNumber: nil),
            Version(versionNumber: "1", buildNumber: "1"),
            Version(versionNumber: "1", buildNumber: "2"),
            Version(versionNumber: "2", buildNumber: nil),
            Version(versionNumber: "2", buildNumber: "1")
        ]

        for lhs in versions {
            XCTAssertEqual(lhs, lhs)
            XCTAssertFalse(lhs < lhs)

            for rhs in versions {
                XCTAssertEqual(lhs == rhs, rhs == lhs)
                XCTAssertFalse(lhs < rhs && rhs < lhs)
                if lhs != rhs {
                    XCTAssertNotEqual(lhs < rhs, rhs < lhs)
                }

                for third in versions
                where lhs < rhs && rhs < third {
                    XCTAssertLessThan(lhs, third)
                }
            }
        }
    }

    func testSelfUpdaterUsesSemanticVersionOrdering() {
        XCTAssertTrue(SelfUpdateValidation.isNewer(remote: "5.10.0", than: "5.9.0"))
        XCTAssertTrue(SelfUpdateValidation.isNewer(remote: "v6.0.0", than: "5.10.0"))
        XCTAssertFalse(SelfUpdateValidation.isNewer(remote: "5.9.0", than: "5.10.0"))
        XCTAssertFalse(SelfUpdateValidation.isNewer(remote: "5.10.0", than: "5.10.0"))
    }

    func testSelfUpdaterValidatesDigestMetadata() {
        let digest = String(repeating: "A1", count: 32)

        XCTAssertEqual(
            SelfUpdateValidation.normalizedSHA256Digest("sha256:\(digest)"),
            digest.lowercased()
        )
        XCTAssertNil(SelfUpdateValidation.normalizedSHA256Digest(nil))
        XCTAssertNil(SelfUpdateValidation.normalizedSHA256Digest("sha1:\(digest)"))
        XCTAssertNil(SelfUpdateValidation.normalizedSHA256Digest("sha256:not-a-digest"))
    }

    func testSelfUpdaterAcceptsOnlyDirectPearcleanerAppArchiveEntries() {
        let validEntries = [
            "Pearcleaner.app/",
            "Pearcleaner.app/Contents/",
            "Pearcleaner.app/Contents/Info.plist",
        ]
        XCTAssertTrue(
            SelfUpdateValidation.archivePreflightIsSafe(
                entries: validEntries,
                zipInfoSummary: "3 files, 7 bytes uncompressed, 7 bytes compressed:  0.0%"
            )
        )
        XCTAssertFalse(
            SelfUpdateValidation.archivePreflightIsSafe(
                entries: validEntries,
                zipInfoSummary: "2 files, 7 bytes uncompressed, 7 bytes compressed:  0.0%"
            )
        )

        let unsafeListings = [
            ["Pearcleaner.app/", "README.txt"],
            ["Pearcleaner.app/../escape"],
            ["/Pearcleaner.app/Contents/Info.plist"],
            ["Payload/Pearcleaner.app/Contents/Info.plist"],
            [#"Pearcleaner.app\Contents\Info.plist"#],
            ["Pearcleaner.app//Contents/Info.plist"],
            ["Pearcleaner.app/Contents/./Info.plist"],
            ["Pearcleaner.app/Contents/\u{0009}Info.plist"],
        ]

        for listing in unsafeListings {
            XCTAssertFalse(
                SelfUpdateValidation.archiveContainsOnlyExpectedApp(listing),
                "Unexpectedly accepted archive listing: \(listing)"
            )
        }
    }

    func testSelfUpdaterCapsArchiveExpansionFromFailClosedSummary() {
        XCTAssertEqual(
            SelfUpdateValidation.archiveMetrics(
                fromZipInfoSummary: "1 file, 0 bytes uncompressed, 0 bytes compressed:  0.0%"
            ),
            .init(entryCount: 1, uncompressedBytes: 0)
        )
        XCTAssertEqual(
            SelfUpdateValidation.archiveMetrics(
                fromZipInfoSummary: "100000 files, 2147483648 bytes uncompressed, 1 bytes compressed:  99.9%"
            ),
            .init(entryCount: 100_000, uncompressedBytes: 2_147_483_648)
        )

        let rejectedSummaries = [
            "100001 files, 1 bytes uncompressed, 1 bytes compressed:  0.0%",
            "1 file, 2147483649 bytes uncompressed, 1 bytes compressed:  0.0%",
            "999999999999999999999999 files, 1 bytes uncompressed, 1 bytes compressed:  0.0%",
            "1 file, 999999999999999999999999 bytes uncompressed, 1 bytes compressed:  0.0%",
            "0 files, 0 bytes uncompressed, 0 bytes compressed:  0.0%",
            "1 Datei, 1 Byte unkomprimiert",
            "1 file, 1 bytes uncompressed, 1 bytes compressed:  0.0%\nuntrusted",
        ]
        for summary in rejectedSummaries {
            XCTAssertNil(
                SelfUpdateValidation.archiveMetrics(fromZipInfoSummary: summary),
                "Unexpectedly accepted ZIP summary: \(summary)"
            )
        }
    }

    func testSelfUpdaterRejectsExtraOrSymlinkedExtractionRootEntries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PearcleanerExtraction-\(UUID().uuidString)")
        let app = root.appendingPathComponent("Pearcleaner.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: app,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            SelfUpdateValidation.validatedAppURL(in: root)?
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path,
            app.resolvingSymlinksInPath().standardizedFileURL.path
        )

        let sibling = root.appendingPathComponent("README.txt")
        try Data("unrelated".utf8).write(to: sibling)
        XCTAssertNil(SelfUpdateValidation.validatedAppURL(in: root))

        try FileManager.default.removeItem(at: sibling)
        try FileManager.default.removeItem(at: app)
        let target = root.appendingPathComponent("Elsewhere.app", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: app, withDestinationURL: target)

        XCTAssertNil(SelfUpdateValidation.validatedAppURL(in: root))
    }

    func testSelfUpdaterRestrictsRedirectHosts() {
        XCTAssertTrue(SelfUpdateValidation.isTrustedGitHubHost("github.com"))
        XCTAssertTrue(SelfUpdateValidation.isTrustedGitHubHost("objects.githubusercontent.com"))
        XCTAssertFalse(SelfUpdateValidation.isTrustedGitHubHost("github.com.example.org"))
        XCTAssertFalse(SelfUpdateValidation.isTrustedGitHubHost("example.org"))
        XCTAssertFalse(SelfUpdateValidation.isTrustedGitHubHost(nil))
    }

    func testSelfUpdaterReadsReplacementMetadataWithoutBundleCache() throws {
        let appURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PearcleanerMetadata-\(UUID().uuidString).app")
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: contentsURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: appURL) }

        func writeVersion(_ version: String) throws {
            let data = try PropertyListSerialization.data(
                fromPropertyList: [
                    "CFBundleIdentifier": "com.lukerow.Pearcleaner",
                    "CFBundleShortVersionString": version
                ],
                format: .binary,
                options: 0
            )
            try data.write(
                to: contentsURL.appendingPathComponent("Info.plist"),
                options: .atomic
            )
        }

        try writeVersion("5.4.4")
        XCTAssertEqual(
            SelfUpdateValidation.bundleMetadata(at: appURL)?.version,
            "5.4.4"
        )

        try writeVersion("5.5.0")
        XCTAssertEqual(
            SelfUpdateValidation.bundleMetadata(at: appURL)?.version,
            "5.5.0"
        )
    }

    func testInstalldWorkaroundUsesMacOSProductVersions() {
        XCTAssertFalse(AppStoreUpdater.needsInstalldWorkaround(for: osVersion(14, 8, 1)))
        XCTAssertTrue(AppStoreUpdater.needsInstalldWorkaround(for: osVersion(14, 8, 2)))
        XCTAssertTrue(AppStoreUpdater.needsInstalldWorkaround(for: osVersion(15, 7, 2)))
        XCTAssertFalse(AppStoreUpdater.needsInstalldWorkaround(for: osVersion(26, 0, 0)))
        XCTAssertTrue(AppStoreUpdater.needsInstalldWorkaround(for: osVersion(26, 1, 0)))
        XCTAssertTrue(AppStoreUpdater.needsInstalldWorkaround(for: osVersion(27, 0, 0)))
        XCTAssertEqual(
            AppStoreUpdater.updateRoute(
                isIOSApp: false,
                operatingSystemVersion: osVersion(15, 7, 1)
            ),
            .commerceKit
        )
        XCTAssertEqual(
            AppStoreUpdater.updateRoute(
                isIOSApp: false,
                operatingSystemVersion: osVersion(15, 7, 2)
            ),
            .affectedMacOSAppStore
        )
        XCTAssertEqual(
            AppStoreUpdater.updateRoute(
                isIOSApp: true,
                operatingSystemVersion: osVersion(15, 7, 1)
            ),
            .iosAppStore
        )
    }

    func testPermanentIgnoreSurvivesJSONPersistence() throws {
        let stored = UpdaterStateLogic.storingIgnore(
            in: [:],
            bundleIdentifier: "com.example.permanent",
            source: .appStore,
            version: nil
        )
        XCTAssertEqual(
            UpdaterStateLogic.ignoreState(
                in: stored,
                bundleIdentifier: "com.example.permanent",
                source: .appStore
            ),
            .permanentlyIgnored
        )

        let encoded = try JSONEncoder().encode(stored)
        let decoded = try JSONDecoder().decode(
            UpdaterStateLogic.IgnoredAppsStore.self,
            from: encoded
        )
        XCTAssertEqual(
            UpdaterStateLogic.ignoreState(
                in: decoded,
                bundleIdentifier: "com.example.permanent",
                source: .appStore
            ),
            .permanentlyIgnored
        )
    }

    func testIgnoredOrUncheckedSourceCannotBeInferredCurrent() {
        XCTAssertFalse(
            UpdaterStateLogic.canInferCurrent(
                isAppStore: true,
                hasHomebrew: false,
                hasSparkle: true,
                checkedSources: [.appStore],
                ignoredSources: [],
                hasKnownUpdate: false
            )
        )
        XCTAssertFalse(
            UpdaterStateLogic.canInferCurrent(
                isAppStore: true,
                hasHomebrew: false,
                hasSparkle: false,
                checkedSources: [.appStore],
                ignoredSources: [.appStore],
                hasKnownUpdate: false
            )
        )
        XCTAssertTrue(
            UpdaterStateLogic.canInferCurrent(
                isAppStore: true,
                hasHomebrew: false,
                hasSparkle: true,
                checkedSources: [.appStore, .sparkle],
                ignoredSources: [],
                hasKnownUpdate: false
            )
        )
    }

    func testPhysicalAppIdentityResolvesEquivalentPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PearcleanerIdentity-\(UUID().uuidString)")
        let appURL = root.appendingPathComponent("Example.app", isDirectory: true)
        let aliasURL = root.appendingPathComponent("Alias.app")
        try FileManager.default.createDirectory(
            at: appURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: aliasURL,
            withDestinationURL: appURL
        )
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            UpdaterStateLogic.physicalAppIdentity(for: appURL),
            UpdaterStateLogic.physicalAppIdentity(for: aliasURL)
        )
    }

    func testBatchSelectionSkipsAmbiguousPhysicalApps() {
        let candidates = [
            UpdaterStateLogic.BatchSelectionCandidate(
                physicalAppIdentity: "/Applications/Dual.app",
                source: .homebrew
            ),
            UpdaterStateLogic.BatchSelectionCandidate(
                physicalAppIdentity: "/Applications/Dual.app",
                source: .appStore
            ),
            UpdaterStateLogic.BatchSelectionCandidate(
                physicalAppIdentity: "/Applications/Unique.app",
                source: .sparkle
            )
        ]

        XCTAssertEqual(
            UpdaterStateLogic.unambiguousBatchAppIdentities(candidates),
            Set(["/Applications/Unique.app"])
        )
    }

    func testBatchProgressUsesExactAttemptQueue() {
        XCTAssertEqual(
            UpdaterStateLogic.batchProgress(completed: 0, total: 1),
            0
        )
        XCTAssertEqual(
            UpdaterStateLogic.batchProgress(completed: 1, total: 1),
            1
        )
        XCTAssertEqual(
            UpdaterStateLogic.batchProgress(completed: 3, total: 1),
            1
        )
        XCTAssertEqual(
            UpdaterStateLogic.batchProgress(completed: 0, total: 0),
            0
        )
    }

    func testIOSUpdatesFailClosedBeforeStartingDownload() async {
        XCTAssertFalse(IOSAppInstaller.isInstallationSupported)

        do {
            try await AppStoreUpdater.shared.updateApp(
                adamID: 1,
                appPath: URL(fileURLWithPath: "/Applications/Example.app"),
                isIOSApp: true,
                progress: { _, _ in }
            )
            XCTFail("iOS update unexpectedly succeeded")
        } catch AppStoreUpdateError.iosUpdatesUnavailable {
            // Expected: no CommerceKit request or filesystem mutation occurs.
        } catch {
            XCTFail("Unexpected iOS update error: \(error)")
        }
    }

    func testHomebrewUpgradeArgumentsPreservePackageType() {
        XCTAssertEqual(
            HomebrewController.upgradeArguments(name: "transmission", cask: true),
            ["upgrade", "--cask", "transmission"]
        )
        XCTAssertEqual(
            HomebrewController.upgradeArguments(name: "ripgrep", cask: false),
            ["upgrade", "ripgrep"]
        )
    }

    func testHiddenUpdateIdentityIncludesSource() {
        let homebrew = UpdaterStateLogic.EntryIdentity(
            bundleIdentifier: "com.example.dual-source",
            source: .homebrew
        )
        let sparkle = UpdaterStateLogic.EntryIdentity(
            bundleIdentifier: "com.example.dual-source",
            source: .sparkle
        )

        XCTAssertNotEqual(homebrew, sparkle)

        var identities: Set = [homebrew, sparkle]
        identities.remove(homebrew)

        XCTAssertEqual(identities, [sparkle])
    }

    func testSparkleNoUpdateIsNotClassifiedAsInstallation() {
        XCTAssertEqual(
            UpdaterStateLogic.sparkleCompletionDisposition(
                success: true,
                hasError: false
            ),
            .installed
        )
        XCTAssertEqual(
            UpdaterStateLogic.sparkleCompletionDisposition(
                success: true,
                hasError: true
            ),
            .noUpdate
        )
        XCTAssertEqual(
            UpdaterStateLogic.sparkleCompletionDisposition(
                success: false,
                hasError: true
            ),
            .failed
        )
    }

    func testSparkleDriverRejectsMissingAppWithoutCrashing() {
        let missingAppURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Missing-\(UUID().uuidString).app")
        let appInfo = AppInfo(
            id: UUID(),
            path: missingAppURL,
            bundleIdentifier: "com.example.missing",
            appName: "Missing",
            appVersion: "1.0",
            appBuildNumber: nil,
            appIcon: nil,
            webApp: false,
            wrapped: false,
            system: false,
            arch: .empty,
            cask: nil,
            steam: false,
            hasSparkle: true,
            isAppStore: false,
            adamID: nil,
            autoUpdates: nil,
            bundleSize: 0,
            lipoSavings: nil,
            fileSize: [:],
            fileIcon: [:],
            creationDate: nil,
            contentChangeDate: nil,
            lastUsedDate: nil,
            dateAdded: nil,
            entitlements: nil,
            teamIdentifier: nil
        )

        let driver = SparkleUpdateDriver(
            appInfo: appInfo,
            includePreReleases: false,
            cachedAppcastItem: nil,
            progressCallback: { _, _ in },
            completionCallback: { _, _ in }
        )

        XCTAssertNil(driver)
    }

    private func osVersion(_ major: Int, _ minor: Int, _ patch: Int) -> OperatingSystemVersion {
        OperatingSystemVersion(
            majorVersion: major,
            minorVersion: minor,
            patchVersion: patch
        )
    }
}
