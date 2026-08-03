//
//  FolderPreferencesTests.swift
//  PearcleanerTests
//
//  Added for the independently maintained Pearcleaner fork.
//

import XCTest
@testable import Pearcleaner

final class FolderPreferencesTests: XCTestCase {
    private var testDomains: [String] = []

    override func tearDown() {
        for domain in testDomains {
            clearTestDomain(domain)
        }
        testDomains.removeAll()
        super.tearDown()
    }

    func testProductionStoreUsesSharedApplicationDomain() {
        XCTAssertEqual(
            PearcleanerPreferencesStore.currentDomainIdentifier,
            "com.lukerow.Pearcleaner"
        )
        XCTAssertEqual(
            PearcleanerPreferencesStore.migrationDomainIdentifiers,
            ["com.alienator88.Pearcleaner", "pear"]
        )
    }

    func testProductionDomainStoreInitializesWithoutSuiteDefaults() {
        let store = PearcleanerPreferencesStore(
            domainIdentifier: PearcleanerPreferencesStore.currentDomainIdentifier,
            migrationDomainIdentifiers: []
        )

        _ = store.stringArray(for: .applications)
    }

    func testStoreReadsAndWritesOnlyExplicitDomain() {
        let currentDomain = makeTestDomain("current")
        let otherDomain = makeTestDomain("other")
        setTestArray(["/Wrong Domain"], for: .applications, domain: otherDomain)

        let store = PearcleanerPreferencesStore(
            domainIdentifier: currentDomain,
            migrationDomainIdentifiers: []
        )
        XCTAssertNil(store.stringArray(for: .applications))

        store.set(["/Applications", "/Current Domain"], for: .applications)

        XCTAssertEqual(
            storedTestArray(for: .applications, domain: currentDomain),
            ["/Applications", "/Current Domain"]
        )
        XCTAssertEqual(
            storedTestArray(for: .applications, domain: otherDomain),
            ["/Wrong Domain"]
        )
    }

    func testMigrationUnionsBothSourcesAndDoesNotOverwriteCurrentValues() {
        let currentDomain = makeTestDomain("current")
        let legacyDomain = makeTestDomain("legacy")
        let symlinkDomain = makeTestDomain("pear")

        setTestArray([], for: .orphanExclusions, domain: currentDomain)
        setTestString("keep", key: "settings.existing", domain: currentDomain)
        setTestArray(["/Applications", "/Legacy Apps"], for: .applications, domain: legacyDomain)
        setTestArray(["legacy-orphan"], for: .orphanExclusions, domain: legacyDomain)
        setTestArray(
            ["shared", "/Legacy Exclusion"],
            for: .appFileExclusions,
            domain: legacyDomain
        )
        setTestString("do not migrate", key: "settings.unrelated", domain: legacyDomain)
        setTestArray(["/Applications", "/Pear Apps"], for: .applications, domain: symlinkDomain)
        setTestArray(["pear-orphan"], for: .orphanExclusions, domain: symlinkDomain)
        setTestArray(
            ["shared", "/Pear Exclusion"],
            for: .appFileExclusions,
            domain: symlinkDomain
        )

        let store = PearcleanerPreferencesStore(
            domainIdentifier: currentDomain,
            migrationDomainIdentifiers: [legacyDomain, symlinkDomain]
        )

        XCTAssertEqual(
            store.stringArray(for: .applications),
            ["/Applications", "/Legacy Apps", "/Pear Apps"]
        )
        XCTAssertEqual(store.stringArray(for: .orphanExclusions), [])
        XCTAssertEqual(
            store.stringArray(for: .appFileExclusions),
            ["shared", "/Legacy Exclusion", "/Pear Exclusion"]
        )
        XCTAssertNil(
            CFPreferencesCopyValue(
                "settings.unrelated" as CFString,
                currentDomain as CFString,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            )
        )
    }

    func testStoredFolderSettingsRemainExportCompatible() throws {
        let currentDomain = makeTestDomain("export")
        let store = PearcleanerPreferencesStore(
            domainIdentifier: currentDomain,
            migrationDomainIdentifiers: []
        )
        let applications = ["/Applications", "/Exported Apps"]
        store.set(applications, for: .applications)
        let userDefaultsDomain = try XCTUnwrap(
            UserDefaults.standard.persistentDomain(forName: currentDomain)
        )

        XCTAssertEqual(
            userDefaultsDomain[FolderPreferenceKey.applications.rawValue] as? [String],
            applications
        )

        let exported = try SettingsExportCodec.exportData(from: userDefaultsDomain)
        let imported = try SettingsExportCodec.importSettings(from: exported)

        XCTAssertEqual(
            imported[FolderPreferenceKey.applications.rawValue] as? [String],
            applications
        )
    }

    func testInjectedManagerPersistsAllFolderSettingsInSelectedStore() {
        let currentDomain = makeTestDomain("manager")
        let store = PearcleanerPreferencesStore(
            domainIdentifier: currentDomain,
            migrationDomainIdentifiers: []
        )
        let defaultPaths = ["/Applications", "/Test Home/Applications"]
        let manager = FolderSettingsManager(preferences: store, defaultPaths: defaultPaths)

        manager.addPath("/Additional Apps")
        manager.addKeywordZ("ignored-orphan")
        manager.addPathApps("/Library/Application Support/Protected Vendor")

        let reloadedManager = FolderSettingsManager(preferences: store, defaultPaths: defaultPaths)
        XCTAssertEqual(
            reloadedManager.folderPaths,
            ["/Applications", "/Test Home/Applications", "/Additional Apps"]
        )
        XCTAssertEqual(reloadedManager.fileFolderPathsZ, ["ignored-orphan"])
        XCTAssertEqual(
            reloadedManager.fileFolderPathsApps,
            ["/Library/Application Support/Protected Vendor"]
        )
    }

    func testAppPathExclusionMatcherConsumesInjectedManagerValues() {
        let currentDomain = makeTestDomain("exclusions")
        let store = PearcleanerPreferencesStore(
            domainIdentifier: currentDomain,
            migrationDomainIdentifiers: []
        )
        let manager = FolderSettingsManager(
            preferences: store,
            defaultPaths: ["/Applications", "/Test Home/Applications"]
        )
        manager.addPathApps("/Library/Application Support/Protected Vendor")
        let formattedExclusions = manager.fileFolderPathsApps.map { $0.pearFormat() }

        XCTAssertTrue(
            appPathMatchesFormattedExclusions(
                URL(fileURLWithPath: "/Library/Application Support/Protected Vendor/cache.db"),
                formattedExclusions: formattedExclusions
            )
        )
        XCTAssertFalse(
            appPathMatchesFormattedExclusions(
                URL(fileURLWithPath: "/Library/Application Support/Different Vendor/cache.db"),
                formattedExclusions: formattedExclusions
            )
        )
    }

    private func makeTestDomain(_ component: String) -> String {
        let domain = "com.lukerow.PearcleanerTests.\(component).\(UUID().uuidString)"
        testDomains.append(domain)
        return domain
    }

    private func setTestArray(
        _ value: [String],
        for key: FolderPreferenceKey,
        domain: String
    ) {
        CFPreferencesSetValue(
            key.rawValue as CFString,
            value as CFArray,
            domain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        synchronizeTestDomain(domain)
    }

    private func setTestString(_ value: String, key: String, domain: String) {
        CFPreferencesSetValue(
            key as CFString,
            value as CFString,
            domain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        synchronizeTestDomain(domain)
    }

    private func storedTestArray(for key: FolderPreferenceKey, domain: String) -> [String]? {
        synchronizeTestDomain(domain)
        return CFPreferencesCopyValue(
            key.rawValue as CFString,
            domain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? [String]
    }

    private func clearTestDomain(_ domain: String) {
        let keys = FolderPreferenceKey.allCases.map(\.rawValue) + [
            "settings.existing",
            "settings.unrelated",
        ]
        for key in keys {
            CFPreferencesSetValue(
                key as CFString,
                nil,
                domain as CFString,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            )
        }
        synchronizeTestDomain(domain)
    }

    private func synchronizeTestDomain(_ domain: String) {
        CFPreferencesSynchronize(
            domain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
    }
}
