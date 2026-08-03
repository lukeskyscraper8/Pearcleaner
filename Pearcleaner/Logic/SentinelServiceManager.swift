//
//  SentinelServiceManager.swift
//  Pearcleaner
//
//  Added for the independently maintained Pearcleaner fork.
//

import Combine
import Foundation
import ServiceManagement

protocol SentinelServiceControlling {
    var status: SMAppService.Status { get }

    func register() throws
    func unregister() throws
}

extension SMAppService: SentinelServiceControlling {}

enum SentinelReconciliationAction: Equatable {
    case none
    case register
    case unregister
}

func sentinelReconciliationAction(
    desiredEnabled: Bool,
    status: SMAppService.Status
) -> SentinelReconciliationAction {
    if desiredEnabled {
        switch status {
        case .notRegistered, .notFound:
            return .register
        case .enabled, .requiresApproval:
            return .none
        @unknown default:
            return .none
        }
    }

    switch status {
    case .enabled, .requiresApproval:
        return .unregister
    case .notRegistered, .notFound:
        return .none
    @unknown default:
        return .none
    }
}

enum SentinelPreferenceMigration {
    static let preferenceKey = "settings.sentinel.enable"
    static let legacyDomain = "com.alienator88.Pearcleaner"

    @discardableResult
    static func migrateIfNeeded(
        defaults: UserDefaults = .standard,
        legacyDomain: String = SentinelPreferenceMigration.legacyDomain
    ) -> Bool {
        guard defaults.object(forKey: preferenceKey) == nil else {
            return false
        }

        guard
            let legacyValue = defaults.persistentDomain(forName: legacyDomain)?[preferenceKey]
                as? Bool
        else {
            return false
        }

        defaults.set(legacyValue, forKey: preferenceKey)
        return true
    }
}

func isBundleInstalledInApplications(_ bundleURL: URL) -> Bool {
    let path = bundleURL.standardizedFileURL.path
    return path == "/Applications" || path.hasPrefix("/Applications/")
}

final class SentinelServiceManager: ObservableObject {
    static let shared = SentinelServiceManager()

    private static let plistName = "com.lukerow.PearcleanerSentinel.plist"

    @Published private(set) var desiredEnabled: Bool
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var lastErrorMessage: String?

    private let service: SentinelServiceControlling
    private let defaults: UserDefaults
    private let legacyDomain: String
    private let bundleURL: URL

    init(
        service: SentinelServiceControlling = SMAppService.agent(
            plistName: SentinelServiceManager.plistName
        ),
        defaults: UserDefaults = .standard,
        legacyDomain: String = SentinelPreferenceMigration.legacyDomain,
        bundleURL: URL = Bundle.main.bundleURL
    ) {
        self.service = service
        self.defaults = defaults
        self.legacyDomain = legacyDomain
        self.bundleURL = bundleURL
        self.desiredEnabled = defaults.bool(forKey: SentinelPreferenceMigration.preferenceKey)
        self.status = service.status
    }

    var isActuallyEnabled: Bool {
        status == .enabled
    }

    var requiresApproval: Bool {
        status == .requiresApproval
    }

    var actualStatusDescription: String {
        switch status {
        case .notRegistered:
            return String(localized: "Not registered")
        case .enabled:
            return String(localized: "Enabled and eligible to run")
        case .requiresApproval:
            return String(localized: "Registered, but requires approval in System Settings")
        case .notFound:
            return String(localized: "Sentinel is not available in this copy of Pearcleaner")
        @unknown default:
            return String(localized: "Unknown status (\(status.rawValue))")
        }
    }

    @discardableResult
    func reconcileAtLaunch() -> SentinelReconciliationAction {
        SentinelPreferenceMigration.migrateIfNeeded(
            defaults: defaults,
            legacyDomain: legacyDomain
        )
        return reconcileStoredPreference()
    }

    @discardableResult
    func reconcileStoredPreference() -> SentinelReconciliationAction {
        desiredEnabled = defaults.bool(forKey: SentinelPreferenceMigration.preferenceKey)
        return reconcile(desiredEnabled: desiredEnabled)
    }

    @discardableResult
    func setDesiredEnabled(_ enabled: Bool) -> SentinelReconciliationAction {
        defaults.set(enabled, forKey: SentinelPreferenceMigration.preferenceKey)
        desiredEnabled = enabled
        return reconcile(desiredEnabled: enabled)
    }

    func refreshStatus() {
        status = service.status
    }

    func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    @discardableResult
    private func reconcile(desiredEnabled: Bool) -> SentinelReconciliationAction {
        refreshStatus()
        lastErrorMessage = nil

        let action = sentinelReconciliationAction(
            desiredEnabled: desiredEnabled,
            status: status
        )

        if action == .register && !isBundleInstalledInApplications(bundleURL) {
            lastErrorMessage = String(
                localized: "Move Pearcleaner to the Applications folder before enabling Sentinel. Development and build copies are not registered."
            )
            return .none
        }

        do {
            switch action {
            case .none:
                break
            case .register:
                try service.register()
            case .unregister:
                try service.unregister()
            }
        } catch {
            refreshStatus()
            if !actualStatusSatisfies(desiredEnabled: desiredEnabled) {
                lastErrorMessage = error.localizedDescription
            }
            return action
        }

        refreshStatus()
        return action
    }

    private func actualStatusSatisfies(desiredEnabled: Bool) -> Bool {
        if desiredEnabled {
            return status == .enabled || status == .requiresApproval
        }
        return status == .notRegistered || status == .notFound
    }
}
