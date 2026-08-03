//
//  SentinelServiceManagerTests.swift
//  PearcleanerTests
//
//  Added for the independently maintained Pearcleaner fork.
//

import Foundation
import ServiceManagement
import XCTest
@testable import Pearcleaner

final class SentinelServiceManagerTests: XCTestCase {
    func testMigratesLegacySentinelPreferenceWhenCurrentValueIsMissing() {
        let fixture = DefaultsFixture()
        defer { fixture.cleanup() }
        fixture.defaults.setPersistentDomain(
            [SentinelPreferenceMigration.preferenceKey: true],
            forName: fixture.legacyDomain
        )

        XCTAssertTrue(
            SentinelPreferenceMigration.migrateIfNeeded(
                defaults: fixture.defaults,
                legacyDomain: fixture.legacyDomain
            )
        )
        XCTAssertTrue(
            fixture.defaults.bool(forKey: SentinelPreferenceMigration.preferenceKey)
        )
    }

    func testMigrationDoesNotOverwriteExplicitCurrentFalse() {
        let fixture = DefaultsFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(false, forKey: SentinelPreferenceMigration.preferenceKey)
        fixture.defaults.setPersistentDomain(
            [SentinelPreferenceMigration.preferenceKey: true],
            forName: fixture.legacyDomain
        )

        XCTAssertFalse(
            SentinelPreferenceMigration.migrateIfNeeded(
                defaults: fixture.defaults,
                legacyDomain: fixture.legacyDomain
            )
        )
        XCTAssertFalse(
            fixture.defaults.bool(forKey: SentinelPreferenceMigration.preferenceKey)
        )
    }

    func testMigrationLeavesCurrentPreferenceAbsentWithoutLegacyValue() {
        let fixture = DefaultsFixture()
        defer { fixture.cleanup() }

        XCTAssertFalse(
            SentinelPreferenceMigration.migrateIfNeeded(
                defaults: fixture.defaults,
                legacyDomain: fixture.legacyDomain
            )
        )
        XCTAssertNil(
            fixture.defaults.object(forKey: SentinelPreferenceMigration.preferenceKey)
        )
    }

    func testReconciliationPolicyUsesActualServiceStatus() {
        XCTAssertEqual(
            sentinelReconciliationAction(desiredEnabled: true, status: .notRegistered),
            .register
        )
        XCTAssertEqual(
            sentinelReconciliationAction(desiredEnabled: true, status: .enabled),
            .none
        )
        XCTAssertEqual(
            sentinelReconciliationAction(desiredEnabled: true, status: .requiresApproval),
            .none
        )
        XCTAssertEqual(
            sentinelReconciliationAction(desiredEnabled: true, status: .notFound),
            .register
        )
        XCTAssertEqual(
            sentinelReconciliationAction(desiredEnabled: false, status: .enabled),
            .unregister
        )
        XCTAssertEqual(
            sentinelReconciliationAction(desiredEnabled: false, status: .requiresApproval),
            .unregister
        )
        XCTAssertEqual(
            sentinelReconciliationAction(desiredEnabled: false, status: .notRegistered),
            .none
        )
    }

    func testLaunchReconciliationMigratesAndRegistersSentinel() {
        let fixture = DefaultsFixture()
        defer { fixture.cleanup() }
        fixture.defaults.setPersistentDomain(
            [SentinelPreferenceMigration.preferenceKey: true],
            forName: fixture.legacyDomain
        )
        let service = MockSentinelService(status: .notRegistered)
        let manager = makeManager(service: service, fixture: fixture)

        XCTAssertEqual(manager.reconcileAtLaunch(), .register)
        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertTrue(manager.desiredEnabled)
        XCTAssertTrue(manager.isActuallyEnabled)
        XCTAssertNil(manager.lastErrorMessage)
    }

    func testLaunchReconciliationRegistersWhenServiceRecordIsNotFound() {
        let fixture = DefaultsFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: SentinelPreferenceMigration.preferenceKey)
        let service = MockSentinelService(status: .notFound)
        let manager = makeManager(service: service, fixture: fixture)

        XCTAssertEqual(manager.reconcileAtLaunch(), .register)
        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertTrue(manager.desiredEnabled)
        XCTAssertTrue(manager.isActuallyEnabled)
        XCTAssertNil(manager.lastErrorMessage)
    }

    func testEnabledAndApprovalStatusesDoNotReregister() {
        for status in [SMAppService.Status.enabled, .requiresApproval] {
            let fixture = DefaultsFixture()
            defer { fixture.cleanup() }
            fixture.defaults.set(true, forKey: SentinelPreferenceMigration.preferenceKey)
            let service = MockSentinelService(status: status)
            let manager = makeManager(service: service, fixture: fixture)

            XCTAssertEqual(manager.reconcileStoredPreference(), .none)
            XCTAssertEqual(service.registerCallCount, 0)
            XCTAssertEqual(manager.status, status)
        }
    }

    func testDisabledPreferenceUnregistersEnabledService() {
        let fixture = DefaultsFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(false, forKey: SentinelPreferenceMigration.preferenceKey)
        let service = MockSentinelService(status: .enabled)
        let manager = makeManager(service: service, fixture: fixture)

        XCTAssertEqual(manager.reconcileStoredPreference(), .unregister)
        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(manager.status, .notRegistered)
    }

    func testRegistrationFailureKeepsDesiredStateAndSurfacesError() {
        let fixture = DefaultsFixture()
        defer { fixture.cleanup() }
        let service = MockSentinelService(status: .notRegistered)
        service.registerError = NSError(
            domain: "SentinelServiceManagerTests",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "Test registration failure"]
        )
        let manager = makeManager(service: service, fixture: fixture)

        XCTAssertEqual(manager.setDesiredEnabled(true), .register)
        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertTrue(manager.desiredEnabled)
        XCTAssertTrue(
            fixture.defaults.bool(forKey: SentinelPreferenceMigration.preferenceKey)
        )
        XCTAssertEqual(manager.status, .notRegistered)
        XCTAssertEqual(manager.lastErrorMessage, "Test registration failure")
    }

    func testDevelopmentBuildCannotRegisterSentinel() {
        let fixture = DefaultsFixture()
        defer { fixture.cleanup() }
        let service = MockSentinelService(status: .notRegistered)
        let manager = makeManager(
            service: service,
            fixture: fixture,
            bundleURL: URL(
                fileURLWithPath:
                    "/Users/example/Library/Developer/Xcode/DerivedData/Pearcleaner/Build/Products/Debug/Pearcleaner.app"
            )
        )

        XCTAssertEqual(manager.setDesiredEnabled(true), .none)
        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertTrue(manager.desiredEnabled)
        XCTAssertNotNil(manager.lastErrorMessage)
        XCTAssertEqual(manager.status, .notRegistered)
    }

    func testApplicationsGuardDoesNotAcceptSimilarPrefix() {
        XCTAssertTrue(
            isBundleInstalledInApplications(
                URL(fileURLWithPath: "/Applications/Pearcleaner.app")
            )
        )
        XCTAssertFalse(
            isBundleInstalledInApplications(
                URL(fileURLWithPath: "/ApplicationsBackup/Pearcleaner.app")
            )
        )
    }

    func testRefreshReadsLatestActualStatus() {
        let fixture = DefaultsFixture()
        defer { fixture.cleanup() }
        let service = MockSentinelService(status: .notRegistered)
        let manager = makeManager(service: service, fixture: fixture)

        service.status = .enabled
        manager.refreshStatus()

        XCTAssertTrue(manager.isActuallyEnabled)
        XCTAssertEqual(manager.status, .enabled)
    }

    private func makeManager(
        service: MockSentinelService,
        fixture: DefaultsFixture,
        bundleURL: URL = URL(fileURLWithPath: "/Applications/Pearcleaner.app")
    ) -> SentinelServiceManager {
        SentinelServiceManager(
            service: service,
            defaults: fixture.defaults,
            legacyDomain: fixture.legacyDomain,
            bundleURL: bundleURL
        )
    }
}

private final class MockSentinelService: SentinelServiceControlling {
    var status: SMAppService.Status
    var registerError: Error?
    var unregisterError: Error?
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        registerCallCount += 1
        if let registerError {
            throw registerError
        }
        status = .enabled
    }

    func unregister() throws {
        unregisterCallCount += 1
        if let unregisterError {
            throw unregisterError
        }
        status = .notRegistered
    }
}

private struct DefaultsFixture {
    let currentDomain: String
    let legacyDomain: String
    let defaults: UserDefaults

    init() {
        let currentDomain = "SentinelServiceManagerTests.current.\(UUID().uuidString)"
        let legacyDomain = "SentinelServiceManagerTests.legacy.\(UUID().uuidString)"
        self.currentDomain = currentDomain
        self.legacyDomain = legacyDomain
        self.defaults = UserDefaults(suiteName: currentDomain)!
        defaults.removePersistentDomain(forName: currentDomain)
        defaults.removePersistentDomain(forName: legacyDomain)
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: currentDomain)
        defaults.removePersistentDomain(forName: legacyDomain)
    }
}
