//
//  UpdateManager.swift
//  Pearcleaner
//
//  Created by Alin Lupascu on 10/13/25.
//
//  Modified for the independently maintained Pearcleaner fork.

import Foundation
import SwiftUI
import AlinFoundation

enum UpdaterStateLogic {
    typealias IgnoredAppsStore = [String: [String: String?]]

    struct EntryIdentity: Hashable {
        let bundleIdentifier: String
        let source: UpdateSource

        init(bundleIdentifier: String, source: UpdateSource) {
            self.bundleIdentifier = bundleIdentifier
            self.source = source
        }

        init(app: UpdateableApp) {
            self.init(bundleIdentifier: app.uniqueIdentifier, source: app.source)
        }
    }

    struct BatchSelectionCandidate: Equatable {
        let physicalAppIdentity: String
        let source: UpdateSource
    }

    enum SparkleCompletionDisposition: Equatable {
        case installed
        case noUpdate
        case failed
    }

    enum IgnoreState: Equatable {
        case notIgnored
        case permanentlyIgnored
        case skippedVersion(String)
    }

    static func sparkleCompletionDisposition(
        success: Bool,
        hasError: Bool
    ) -> SparkleCompletionDisposition {
        if success {
            return hasError ? .noUpdate : .installed
        }
        return .failed
    }

    static func storingIgnore(
        in store: IgnoredAppsStore,
        bundleIdentifier: String,
        source: UpdateSource,
        version: String?
    ) -> IgnoredAppsStore {
        var result = store
        var sourceVersions = result[bundleIdentifier] ?? [:]

        // Dictionary subscripts use nil to remove a key. Wrap the optional so
        // a permanent ignore is stored as an explicit JSON null instead.
        sourceVersions[source.rawValue] = .some(version)
        result[bundleIdentifier] = sourceVersions
        return result
    }

    static func ignoreState(
        in store: IgnoredAppsStore,
        bundleIdentifier: String,
        source: UpdateSource
    ) -> IgnoreState {
        switch store[bundleIdentifier]?[source.rawValue] {
        case .none:
            return .notIgnored
        case .some(.none):
            return .permanentlyIgnored
        case .some(.some(let version)):
            return .skippedVersion(version)
        }
    }

    static func canInferCurrent(
        isAppStore: Bool,
        hasHomebrew: Bool,
        hasSparkle: Bool,
        checkedSources: Set<UpdateSource>,
        ignoredSources: Set<UpdateSource>,
        hasKnownUpdate: Bool
    ) -> Bool {
        guard !hasKnownUpdate else { return false }

        var supportedSources = Set<UpdateSource>()
        if isAppStore { supportedSources.insert(.appStore) }
        if hasHomebrew { supportedSources.insert(.homebrew) }
        if hasSparkle { supportedSources.insert(.sparkle) }

        guard !supportedSources.isEmpty,
              supportedSources.isSubset(of: checkedSources),
              supportedSources.isDisjoint(with: ignoredSources) else {
            return false
        }
        return true
    }

    static func physicalAppIdentity(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func unambiguousBatchAppIdentities(
        _ candidates: [BatchSelectionCandidate]
    ) -> Set<String> {
        let grouped = Dictionary(
            grouping: candidates,
            by: \.physicalAppIdentity
        )
        return Set(
            grouped.compactMap { identity, entries in
                entries.count == 1 ? identity : nil
            }
        )
    }

    static func batchProgress(completed: Int, total: Int) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

@MainActor
class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    @Published var updatesBySource: [UpdateSource: [UpdateableApp]] = [:]
    @Published var hiddenUpdates: [UpdateableApp] = []
    @Published var isScanning: Bool = false
    @Published var lastScanDate: Date?
    @Published var scanningSources: Set<UpdateSource> = []
    @Published var currentScanTask: Task<Void, Never>?

    // Batch update tracking
    @Published var isUpdatingAll: Bool = false
    @Published var totalAppsToUpdate: Int = 0
    @Published private var completedBatchApps: Int = 0

    // Consolidated settings (2 Data properties total)
    @AppStorage("settings.updater.sources") private var sourcesData: Data = UpdaterSourcesSettings.defaultEncoded()
    @AppStorage("settings.updater.display") private var displayData: Data = UpdaterDisplaySettings.defaultEncoded()

    @AppStorage("settings.updater.debugLogging") private var debugLogging: Bool = true
    @AppStorage("settings.updater.hiddenAppsData") private var hiddenAppsData: Data = Data()
    @AppStorage("settings.updater.ignoredAppsData") private var ignoredAppsData: Data = Data()

    // Computed properties for convenient access to nested structs
    private var sources: UpdaterSourcesSettings {
        get {
            UpdaterSourcesSettings.decode(from: sourcesData)
        }
        set {
            sourcesData = newValue.encode()
        }
    }

    private var display: UpdaterDisplaySettings {
        get {
            UpdaterDisplaySettings.decode(from: displayData)
        }
        set {
            displayData = newValue.encode()
        }
    }

    // Backward-compatible convenience properties
    private var checkAppStore: Bool { sources.appStore.enabled }
    private var checkHomebrew: Bool { sources.homebrew.enabled }
    private var checkSparkle: Bool { sources.sparkle.enabled }
    private var showAutoUpdatesInHomebrew: Bool { sources.homebrew.showAutoUpdates }
    private var includeSparklePreReleases: Bool { sources.sparkle.includePreReleases }
    private var showUnsupported: Bool { display.showUnsupported }
    private var showCurrent: Bool { display.showCurrent }

    private var hasAutoScannedOnce = false

    private init() {
        // Migrate old settings to new consolidated format
        migrateSettingsIfNeeded()

        // Migrate old hiddenApps data to new ignoredApps format on first launch
        migrateHiddenAppsIfNeeded()

        // Subscribe to notification for automatic background scanning
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAllAppsFullyLoaded),
            name: NSNotification.Name("AllAppsFullyLoaded"),
            object: nil
        )
    }

    /// Migrate old individual settings to new consolidated structs (one-time migration)
    private func migrateSettingsIfNeeded() {
        // Check if migration already happened by seeing if new settings exist
        if sourcesData.isEmpty {
            // Read old settings from UserDefaults
            let oldCheckAppStore = UserDefaults.standard.bool(forKey: "settings.updater.checkAppStore")
            let oldCheckHomebrew = UserDefaults.standard.bool(forKey: "settings.updater.checkHomebrew")
            let oldCheckSparkle = UserDefaults.standard.bool(forKey: "settings.updater.checkSparkle")
            let oldShowAutoUpdates = UserDefaults.standard.bool(forKey: "settings.updater.showAutoUpdatesInHomebrew")
            let oldIncludePreReleases = UserDefaults.standard.bool(forKey: "settings.updater.includeSparklePreReleases")

            // Check if any old settings exist (they default to false if never set)
            let hasOldSettings = UserDefaults.standard.object(forKey: "settings.updater.checkAppStore") != nil ||
                                UserDefaults.standard.object(forKey: "settings.updater.checkHomebrew") != nil ||
                                UserDefaults.standard.object(forKey: "settings.updater.checkSparkle") != nil

            if hasOldSettings {
                // Migrate to new format
                var newSources = UpdaterSourcesSettings()
                newSources.appStore.enabled = oldCheckAppStore
                newSources.homebrew.enabled = oldCheckHomebrew
                newSources.homebrew.showAutoUpdates = oldShowAutoUpdates
                newSources.sparkle.enabled = oldCheckSparkle
                newSources.sparkle.includePreReleases = oldIncludePreReleases

                sources = newSources
            }
        }

        if displayData.isEmpty {
            // Read old showUnsupported setting
            let oldShowUnsupported = UserDefaults.standard.bool(forKey: "settings.updater.showUnsupported")

            if UserDefaults.standard.object(forKey: "settings.updater.showUnsupported") != nil {
                var newDisplay = UpdaterDisplaySettings()
                newDisplay.showUnsupported = oldShowUnsupported
                display = newDisplay
            }
        }
    }

    @objc private func handleAllAppsFullyLoaded() {
        // Only run once per app session
        guard !hasAutoScannedOnce else { return }
        hasAutoScannedOnce = true

        Task { @MainActor in
            await scanIfNeeded()
        }
    }

    /// Public entry point for triggering scans. Prevents duplicate scans through centralized logic.
    /// - Parameters:
    ///   - forceReload: If true, bypasses cache and forces a fresh scan
    ///   - sources: Optional set of specific sources to scan. If nil, scans all enabled sources.
    func scanIfNeeded(forceReload: Bool = false, sources: Set<UpdateSource>? = nil) async {
        // Prevent duplicate scans
        guard !isScanning else { return }

        // Trigger scan if forcing reload OR specific sources requested
        if forceReload || sources != nil {
            await scanForUpdates(forceReload: forceReload, sources: sources)
            return
        }

        // Otherwise, only scan if no data exists yet
        guard lastScanDate == nil else { return }
        await scanForUpdates()
    }

    var hasUpdates: Bool {
        updatesBySource.values.contains { !$0.isEmpty } || !hiddenUpdates.isEmpty
    }

    var totalUpdateCount: Int {
        updatesBySource
            .filter { $0.key != .unsupported && $0.key != .current }
            .values
            .reduce(0) { $0 + $1.count }
    }

    /// Progress of batch update (0.0 to 1.0)
    var updateAllProgress: Double {
        UpdaterStateLogic.batchProgress(
            completed: completedBatchApps,
            total: totalAppsToUpdate
        )
    }

    /// Number of completed apps in batch update
    var completedAppsCount: Int {
        completedBatchApps
    }

    /// Computed property for easy access to hidden apps mapping (bundleID -> source)
    private var hiddenApps: [String: UpdateSource] {
        get {
            guard let decoded = try? JSONDecoder().decode([String: String].self, from: hiddenAppsData) else {
                return [:]
            }
            // Convert String to UpdateSource
            return decoded.compactMapValues { UpdateSource(rawValue: $0) }
        }
        set {
            // Convert UpdateSource to String for storage
            let stringDict = newValue.mapValues { $0.rawValue }
            hiddenAppsData = (try? JSONEncoder().encode(stringDict)) ?? Data()
        }
    }

    /// Unified ignored apps storage: bundleID -> [source -> version?]
    /// nil version = permanently ignored, string version = skip until newer version
    private var ignoredApps: UpdaterStateLogic.IgnoredAppsStore {
        get {
            guard let decoded = try? JSONDecoder().decode([String: [String: String?]].self, from: ignoredAppsData) else {
                return [:]
            }
            return decoded
        }
        set {
            ignoredAppsData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    private func isPermanentlyIgnored(bundleID: String, source: UpdateSource) -> Bool {
        UpdaterStateLogic.ignoreState(
            in: ignoredApps,
            bundleIdentifier: bundleID,
            source: source
        ) == .permanentlyIgnored
    }

    private func versionsMatch(_ lhs: String, _ rhs: String) -> Bool {
        let left = Version(versionNumber: lhs, buildNumber: nil)
        let right = Version(versionNumber: rhs, buildNumber: nil)
        if !left.isEmpty, !right.isEmpty {
            return left == right
        }
        return lhs == rhs
    }

    private func hiddenIdentity(for app: UpdateableApp) -> UpdaterStateLogic.EntryIdentity {
        UpdaterStateLogic.EntryIdentity(app: app)
    }

    private func upsertHiddenUpdate(_ app: UpdateableApp) {
        let identity = hiddenIdentity(for: app)
        if let index = hiddenUpdates.firstIndex(where: {
            hiddenIdentity(for: $0) == identity
        }) {
            hiddenUpdates[index] = app
        } else {
            hiddenUpdates.append(app)
        }
    }

    /// The legacy store can represent only one source per bundle. Keep it
    /// aligned with any remaining permanent ignore so downgrades retain the
    /// safest available state without affecting the multi-source store.
    private func syncLegacyHiddenApp(
        bundleID: String,
        ignored: [String: [String: String?]]
    ) {
        let permanentSources = ignored[bundleID, default: [:]].compactMap {
            sourceRawValue, ignoredVersion -> UpdateSource? in
            guard ignoredVersion == nil else { return nil }
            return UpdateSource(rawValue: sourceRawValue)
        }.sorted { $0.rawValue < $1.rawValue }

        var hidden = hiddenApps
        if let source = permanentSources.first {
            hidden[bundleID] = source
        } else {
            hidden.removeValue(forKey: bundleID)
        }
        hiddenApps = hidden
    }

    /// Migrate old hiddenApps data to new ignoredApps format (one-time migration)
    private func migrateHiddenAppsIfNeeded() {
        // Only migrate if old data exists and new data is empty
        guard !hiddenAppsData.isEmpty, ignoredAppsData.isEmpty else { return }

        var migrated: [String: [String: String?]] = [:]
        for (bundleID, source) in hiddenApps {
            // Convert to new format with nil version (permanent ignore)
            migrated = UpdaterStateLogic.storingIgnore(
                in: migrated,
                bundleIdentifier: bundleID,
                source: source,
                version: nil
            )
        }

        ignoredApps = migrated
        // Keep old data for now in case user downgrades
    }

    /// Get the ignored version for a specific app and source
    /// - Parameter app: The app to check
    /// - Returns: nil if permanently ignored, version string if skipped, or nil if not ignored for this source
    func getIgnoredVersion(for app: UpdateableApp) -> String? {
        return ignoredApps[app.uniqueIdentifier]?[app.source.rawValue] ?? nil
    }

    /// Update the fetched release notes for a specific app
    /// - Parameters:
    ///   - appId: The UUID of the app to update
    ///   - content: The fetched release notes content
    func updateFetchedReleaseNotes(for appId: UUID, content: String) {
        // Find and update the app in updatesBySource
        for (source, apps) in updatesBySource {
            if let index = apps.firstIndex(where: { $0.id == appId }) {
                var updatedApp = apps[index]
                updatedApp.fetchedReleaseNotes = content
                updatesBySource[source]?[index] = updatedApp
                return
            }
        }
    }

    /// Hide an app permanently or skip a specific version
    /// - Parameters:
    ///   - app: The app to ignore
    ///   - skipVersion: Optional version to skip. If nil, app is permanently ignored. If provided, only that version is skipped.
    func hideApp(_ app: UpdateableApp, skipVersion: String? = nil) {
        // Add to new unified ignored apps storage
        let ignored = UpdaterStateLogic.storingIgnore(
            in: ignoredApps,
            bundleIdentifier: app.uniqueIdentifier,
            source: app.source,
            version: skipVersion
        )

        ignoredApps = ignored
        syncLegacyHiddenApp(bundleID: app.uniqueIdentifier, ignored: ignored)

        // Immediately remove from visible lists for instant UI feedback
        updatesBySource[app.source]?.removeAll { $0.uniqueIdentifier == app.uniqueIdentifier }

        // Add to hidden list for sidebar display
        upsertHiddenUpdate(app)
    }

    /// Rescan a single app to get fresh update data
    func recheckUpdate(for app: UpdateableApp) async -> UpdateableApp? {
        // Get fresh AppInfo from sortedApps (handles case where app was updated externally)
        guard let freshAppInfo = AppState.shared.sortedApps.first(where: {
            $0.bundleIdentifier == app.uniqueIdentifier
        }) else {
            return nil // App no longer exists
        }

        // Call appropriate source-specific checker based on app.source
        switch app.source {
        case .homebrew:
            let results = await HomebrewUpdateChecker.checkForUpdates(
                apps: [freshAppInfo],
                includeFormulae: false,
                showAutoUpdatesInHomebrew: showAutoUpdatesInHomebrew
            )
            return results.first

        case .appStore:
            let results = await AppStoreUpdateChecker.checkForUpdates(apps: [freshAppInfo])
            return results.first

        case .sparkle:
            let results = await SparkleUpdateChecker.checkForUpdates(
                apps: [freshAppInfo],
                includePreReleases: includeSparklePreReleases
            )
            return results.first

        case .unsupported:
            return nil // Can't check unsupported apps

        case .current:
            return nil // Already current, no update available
        }
    }

    /// Unhide an app (remove from hidden filter and restore to visible list if it has an update)
    func unhideApp(_ app: UpdateableApp) async {
        // Remove from new unified ignored apps storage
        var ignored = ignoredApps
        ignored[app.uniqueIdentifier]?.removeValue(forKey: app.source.rawValue)
        if ignored[app.uniqueIdentifier]?.isEmpty == true {
            ignored.removeValue(forKey: app.uniqueIdentifier)
        }
        ignoredApps = ignored

        // Keep a remaining permanent ignore represented in the legacy store.
        syncLegacyHiddenApp(bundleID: app.uniqueIdentifier, ignored: ignored)

        // Immediately remove only this source's hidden entry.
        let identity = hiddenIdentity(for: app)
        hiddenUpdates.removeAll { hiddenIdentity(for: $0) == identity }

        // Rescan the app to get fresh update data
        if let refreshedApp = await recheckUpdate(for: app) {
            // Add refreshed app to visible list
            if var apps = updatesBySource[app.source] {
                apps.append(refreshedApp)
                // Sort alphabetically after adding using sortKey extension
                apps.sort { $0.appInfo.appName.sortKey < $1.appInfo.appName.sortKey }
                updatesBySource[app.source] = apps
            } else {
                updatesBySource[app.source] = [refreshedApp]
            }
        }
        // If nil returned, no update available anymore - don't add to visible list
    }

    /// Toggle selection state for an app in the update queue
    func toggleAppSelection(_ app: UpdateableApp) {
        guard var apps = updatesBySource[app.source],
              let index = apps.firstIndex(where: { $0.id == app.id }) else { return }

        apps[index].isSelectedForUpdate.toggle()
        updatesBySource[app.source] = apps
    }

    func scanForUpdates(forceReload: Bool = false, sources: Set<UpdateSource>? = nil) async {
        // Double-check to prevent race condition where multiple scans pass the guard
        guard !isScanning else { return }
        isScanning = true
        defer {
            isScanning = false
            scanningSources.removeAll()  // Always clear scanning state on exit
        }

        // Determine which sources to scan
        var sourcesToScan: Set<UpdateSource>
        if let sources = sources {
            // Selective scan - only scan specified sources
            sourcesToScan = sources

            // Only clear specified sources from updatesBySource (preserve others)
            for source in sources {
                updatesBySource[source] = nil
            }
            // Clear only entries owned by rescanned sources. Unscanned source
            // state remains visible until it is independently refreshed.
            hiddenUpdates.removeAll { sourcesToScan.contains($0.source) }
        } else {
            // Full scan - scan all enabled sources (current behavior)
            sourcesToScan = []
            if checkAppStore { sourcesToScan.insert(.appStore) }
            if checkHomebrew { sourcesToScan.insert(.homebrew) }
            if checkSparkle { sourcesToScan.insert(.sparkle) }

            // Clear all results
            updatesBySource = [:]
            hiddenUpdates = []  // Clear to prevent stale entries (will be rebuilt from persistent storage)
        }

        scanningSources = sourcesToScan

        // Only flush caches and reload apps if explicitly requested or debug mode enabled
        // This significantly improves performance for regular update checks
        if forceReload || debugLogging || AppState.shared.sortedApps.isEmpty {
            // Flush bundle caches (useful for testing with fake versions in debug mode)
            Pearcleaner.flushBundleCaches(for: AppState.shared.sortedApps)

            // Reload apps from disk to detect newly installed/uninstalled apps
            let folderPaths = await MainActor.run {
                FolderSettingsManager.shared.folderPaths
            }
            await loadAppsAsync(folderPaths: folderPaths, useStreaming: false)
        }

        // Check for cancellation after loading apps
        if Task.isCancelled {
            return
        }

        // Use apps from AppState (either freshly loaded or existing)
        let apps = AppState.shared.sortedApps

        // Launch concurrent scans with progressive updates
        await withTaskGroup(of: (UpdateSource, [UpdateableApp]).self) { group in
            if sourcesToScan.contains(.homebrew) {
                let visibleApps = apps.filter {
                    !isPermanentlyIgnored(bundleID: $0.bundleIdentifier, source: .homebrew)
                }
                group.addTask {
                    let results = await HomebrewUpdateChecker.checkForUpdates(apps: visibleApps, includeFormulae: false, showAutoUpdatesInHomebrew: self.showAutoUpdatesInHomebrew)
                    return (.homebrew, results)
                }
            }

            if sourcesToScan.contains(.appStore) {
                let visibleApps = apps.filter {
                    !isPermanentlyIgnored(bundleID: $0.bundleIdentifier, source: .appStore)
                }
                group.addTask {
                    // Use pre-categorized flag (instant check vs expensive receipt verification)
                    let appStoreApps = visibleApps.filter { $0.isAppStore }
                    let results = await AppStoreUpdateChecker.checkForUpdates(apps: appStoreApps)
                    return (.appStore, results)
                }
            }

            if sourcesToScan.contains(.sparkle) {
                let visibleApps = apps.filter {
                    !isPermanentlyIgnored(bundleID: $0.bundleIdentifier, source: .sparkle)
                }
                group.addTask {
                    // Show all apps with Sparkle, regardless of other update sources
                    // This allows users to see version differences across App Store/Homebrew/Sparkle
                    // and choose which source to update from
                    let sparkleApps = visibleApps.filter { $0.hasSparkle }

                    let results = await SparkleUpdateChecker.checkForUpdates(apps: sparkleApps, includePreReleases: self.includeSparklePreReleases)
                    return (.sparkle, results)
                }
            }

            // Process results as they complete
            for await (source, apps) in group {
                // Check for cancellation between source results
                if Task.isCancelled {
                    // Still process results with empty arrays to trigger cleanup
                    for source in scanningSources {
                        await processSourceResults(source: source, apps: [])
                    }
                    break
                }
                await processSourceResults(source: source, apps: apps)
            }
        }

        // Check for cancellation before final processing
        if Task.isCancelled {
            return
        }

        // Deduplicate: Remove Homebrew apps that also exist in Sparkle (when auto_updates=true and toggle is ON)
        // Rationale: If an app has both Homebrew cask and Sparkle framework with auto_updates=true,
        // prefer the developer's choice (built-in Sparkle updater) and avoid showing in both categories
        if showAutoUpdatesInHomebrew, let homebrewApps = updatesBySource[.homebrew], let sparkleApps = updatesBySource[.sparkle] {
            // Build set of Sparkle app paths for quick lookup
            let sparkleAppPaths = Set(sparkleApps.map { $0.appInfo.path })

            // Filter out Homebrew apps that have both:
            // 1. auto_updates=true (developer chose built-in updater)
            // 2. Sparkle framework (exists in Sparkle category)
            let deduplicatedHomebrew = homebrewApps.filter { brewApp in
                guard let autoUpdates = brewApp.appInfo.autoUpdates, autoUpdates else {
                    return true  // Keep: no auto_updates flag
                }

                // Exclude if app also exists in Sparkle (prefer Sparkle)
                return !sparkleAppPaths.contains(brewApp.appInfo.path)
            }

            // Update with deduplicated list
            updatesBySource[.homebrew] = deduplicatedHomebrew
        }

        // Calculate unsupported apps (always calculate - it's instant, toggle only controls UI visibility)
        let unsupportedApps = apps.filter { app in
            // Not a web app (web apps update with browser)
            !app.webApp &&
            // Not an App Store app
            !app.isAppStore &&
            // Not a Homebrew cask/formula
            app.cask == nil &&
            // Doesn't have Sparkle
            !app.hasSparkle
        }.map { app in
            // Create UpdateableApp with unsupported source
            UpdateableApp(
                appInfo: app,
                availableVersion: nil,  // Can't check updates
                availableBuildNumber: nil,
                source: .unsupported,
                adamID: nil,
                appStoreURL: nil,
                status: .idle,
                progress: 0.0,
                isSelectedForUpdate: false,  // Can't update unsupported apps
                releaseTitle: nil,
                releaseDescription: nil,
                releaseNotesLink: nil,
                releaseDate: nil,
                isPreRelease: false,
                isIOSApp: false,
                foundInRegion: nil,
                appcastItem: nil
            )
        }

        await processSourceResults(source: .unsupported, apps: unsupportedApps)

        // Infer "Current" only when every update mechanism supported by the
        // app was checked in this scan. A disabled/unchecked or permanently
        // ignored source is unknown, not evidence that the app is current.
        let knownUpdatePaths = Set(
            updatesBySource
                .filter {
                    $0.key == .homebrew ||
                    $0.key == .appStore ||
                    $0.key == .sparkle
                }
                .values
                .flatMap { $0 }
                .map {
                    UpdaterStateLogic.physicalAppIdentity(
                        for: $0.appInfo.path
                    )
                }
        ).union(
            hiddenUpdates.map {
                UpdaterStateLogic.physicalAppIdentity(
                    for: $0.appInfo.path
                )
            }
        )
        let ignored = ignoredApps

        // Calculate current apps (supported but up-to-date - no updates available)
        let currentApps = apps.filter { app in
            let permanentlyIgnoredSources = Set(
                UpdateSource.allCases.filter { source in
                    UpdaterStateLogic.ignoreState(
                        in: ignored,
                        bundleIdentifier: app.bundleIdentifier,
                        source: source
                    ) == .permanentlyIgnored
                }
            )
            let appIdentity = UpdaterStateLogic.physicalAppIdentity(
                for: app.path
            )

            // Not a web app
            return !app.webApp &&
                UpdaterStateLogic.canInferCurrent(
                    isAppStore: app.isAppStore,
                    hasHomebrew: app.cask != nil,
                    hasSparkle: app.hasSparkle,
                    checkedSources: sourcesToScan,
                    ignoredSources: permanentlyIgnoredSources,
                    hasKnownUpdate: knownUpdatePaths.contains(appIdentity)
                )
        }.map { app in
            // Create UpdateableApp with current source
            UpdateableApp(
                appInfo: app,
                availableVersion: app.appVersion,  // Already up-to-date
                availableBuildNumber: nil,
                source: .current,
                adamID: nil,
                appStoreURL: nil,
                status: .idle,
                progress: 0.0,
                isSelectedForUpdate: false,  // Already current, no update needed
                releaseTitle: nil,
                releaseDescription: nil,
                releaseNotesLink: nil,
                releaseDate: nil,
                isPreRelease: false,
                isIOSApp: false,
                foundInRegion: nil,
                fetchedReleaseNotes: nil,
                appcastItem: nil
            )
        }

        await processSourceResults(source: .current, apps: currentApps)

        // Rebuild hidden apps list for display
        // This ensures ALL hidden apps appear in the sidebar, even those without updates
        await rebuildHiddenAppsList(allApps: apps)

        lastScanDate = Date()

        // Print formatted debug report to console after scan completes
        if debugLogging {
            printOS("\n" + UpdaterDebugLogger.shared.generateDebugReport())
        }

        // Clear task reference on completion
        currentScanTask = nil

    }

    /// Rebuild hidden apps list from storage for display in sidebar
    /// This populates hiddenUpdates with ALL hidden apps (even those without updates)
    private func rebuildHiddenAppsList(allApps: [AppInfo]) async {
        var ignored = ignoredApps
        var legacyHidden = hiddenApps

        // The unified store can contain independent entries for multiple
        // sources. Only permanent ignores need synthetic rows; version skips
        // are added by processSourceResults when that exact version is found.
        for (bundleID, ignoredSources) in Array(ignored) {
            guard let appInfo = allApps.first(where: { $0.bundleIdentifier == bundleID }) else {
                // App no longer exists, remove all persisted and in-memory
                // entries for this bundle.
                ignored.removeValue(forKey: bundleID)
                legacyHidden.removeValue(forKey: bundleID)
                hiddenUpdates.removeAll { $0.uniqueIdentifier == bundleID }
                continue
            }

            for (sourceRawValue, ignoredVersion) in ignoredSources {
                guard ignoredVersion == nil,
                      let source = UpdateSource(rawValue: sourceRawValue) else {
                    continue
                }

                let identity = UpdaterStateLogic.EntryIdentity(
                    bundleIdentifier: bundleID,
                    source: source
                )
                guard !hiddenUpdates.contains(where: {
                    hiddenIdentity(for: $0) == identity
                }) else {
                    continue
                }

                upsertHiddenUpdate(
                    UpdateableApp(
                        appInfo: appInfo,
                        availableVersion: nil,
                        availableBuildNumber: nil,
                        source: source,
                        adamID: nil,
                        appStoreURL: nil,
                        status: .idle,
                        progress: 0.0,
                        isSelectedForUpdate: false,
                        releaseTitle: nil,
                        releaseDescription: nil,
                        releaseNotesLink: nil,
                        releaseDate: nil,
                        isPreRelease: false,
                        isIOSApp: false,
                        foundInRegion: nil,
                        appcastItem: nil
                    )
                )
            }
        }

        if ignored != ignoredApps {
            ignoredApps = ignored
        }
        if legacyHidden != hiddenApps {
            hiddenApps = legacyHidden
        }

        var deduplicated: [UpdaterStateLogic.EntryIdentity: UpdateableApp] = [:]
        for app in hiddenUpdates {
            let identity = hiddenIdentity(for: app)
            if let existing = deduplicated[identity],
               existing.availableVersion != nil || app.availableVersion == nil {
                continue
            }
            deduplicated[identity] = app
        }
        hiddenUpdates = Array(deduplicated.values)
        hiddenUpdates.sort {
            let order = $0.appInfo.appName.sortKey.compare($1.appInfo.appName.sortKey)
            if order == .orderedSame {
                return $0.source.rawValue < $1.source.rawValue
            }
            return order == .orderedAscending
        }
    }

    private func processSourceResults(source: UpdateSource, apps: [UpdateableApp]) async {
        // A source result is authoritative for that source. Drop its previous
        // hidden rows before rebuilding them from the current response.
        hiddenUpdates.removeAll { $0.source == source }

        // Sort alphabetically
        let sortedApps = apps.sorted { $0.appInfo.appName.sortKey < $1.appInfo.appName.sortKey }

        // Filter ignored and version-skipped apps
        let ignored = ignoredApps
        let visible = sortedApps.filter { app in
            // Check if app is in ignored list
            guard let ignoredVersions = ignored[app.uniqueIdentifier],
                  let ignoredVersion = ignoredVersions[source.rawValue] else {
                return true // Not ignored, show it
            }

            // If ignoredVersion is nil, permanently ignored
            if ignoredVersion == nil {
                return false
            }

            // If ignoredVersion matches availableVersion, skip this version
            if let availableVersion = app.availableVersion,
               let ignoredVersion,
               versionsMatch(availableVersion, ignoredVersion) {
                return false
            }

            // Newer version available, show it
            return true
        }
        let hiddenAppsFromSource = sortedApps.filter { app in
            guard let ignoredVersions = ignored[app.uniqueIdentifier],
                  let ignoredVersion = ignoredVersions[source.rawValue] else {
                return false
            }
            guard let ignoredVersion else { return true }
            guard let availableVersion = app.availableVersion else { return false }
            return versionsMatch(availableVersion, ignoredVersion)
        }

        // Update results (set to empty array even if no visible results to indicate "completed")
        updatesBySource[source] = visible

        // Add hidden apps to hidden list
        for app in hiddenAppsFromSource {
            upsertHiddenUpdate(app)
        }

        // Mark source as no longer scanning
        scanningSources.remove(source)
    }

    /// Cancel the current scan operation
    func cancelScan() {
        isScanning = false  // Immediately update UI state
        currentScanTask?.cancel()
        currentScanTask = nil
        scanningSources.removeAll()  // Clear scanning state for all sources
    }

    /// Remove pre-release apps from a specific source without rescanning
    /// This is more efficient than rescanning when toggling off pre-releases
    func removePreReleaseApps(from source: UpdateSource) {
        guard var apps = updatesBySource[source] else { return }

        // Filter out pre-release apps
        apps = apps.filter { !$0.isPreRelease }

        // Update the source with filtered apps
        updatesBySource[source] = apps
    }

    func updateApp(_ app: UpdateableApp) async {
        switch app.source {
        case .homebrew:
            if let cask = app.appInfo.cask {
                GlobalConsoleManager.shared.appendOutput("Starting Homebrew update for \(app.appInfo.appName) (\(cask))...\n", source: CurrentPage.updater.title)

                // Update the app status
                if var apps = updatesBySource[.homebrew],
                   let index = apps.firstIndex(where: { $0.id == app.id }) {
                    apps[index].status = .downloading
                    updatesBySource[.homebrew] = apps
                }

                // Perform upgrade
                do {
                    try await HomebrewController.shared.upgradePackage(name: cask, cask: true)

                    GlobalConsoleManager.shared.appendOutput("✓ Successfully updated \(app.appInfo.appName) to version \(app.availableVersion ?? "unknown")\n", source: CurrentPage.updater.title)

                    // Only remove from list if upgrade succeeded
                    updatesBySource[.homebrew]?.removeAll { $0.id == app.id }

                    // Refresh apps (only flush updated app's bundle for performance)
                    await refreshApps(updatedApp: app.appInfo)
                } catch {
                    GlobalConsoleManager.shared.appendOutput("✗ Failed to update \(app.appInfo.appName): \(error.localizedDescription)\n", source: CurrentPage.updater.title)

                    // Update status to failed on error
                    if var apps = updatesBySource[.homebrew],
                       let index = apps.firstIndex(where: { $0.id == app.id }) {
                        apps[index].status = .failed(error.localizedDescription)
                        apps[index].progress = 0.0  // Reset progress indicator
                        updatesBySource[.homebrew] = apps
                    }
                    printOS("Error updating Homebrew package \(cask): \(error)")
                }
            }

        case .appStore:
            if let adamID = app.adamID {
                GlobalConsoleManager.shared.appendOutput("Starting App Store update for \(app.appInfo.appName) (adamID: \(adamID))...\n", source: CurrentPage.updater.title)

                // Update the app status
                if var apps = updatesBySource[.appStore],
                   let index = apps.firstIndex(where: { $0.id == app.id }) {
                    apps[index].status = .downloading
                    updatesBySource[.appStore] = apps
                }

                // Perform update (new API throws errors)
                do {
                    try await AppStoreUpdater.shared.updateApp(adamID: adamID, appPath: app.appInfo.path, isIOSApp: app.isIOSApp) { [weak self] progress, status in
                        Task { @MainActor in
                            guard let self = self else { return }
                            if var apps = self.updatesBySource[.appStore],
                               let index = apps.firstIndex(where: { $0.id == app.id }) {
                                apps[index].progress = progress

                                // Update status based on App Store phase
                                if status.contains("Downloading") || status.contains("Preparing") {
                                    // Phase 0 or 4: Downloading or preparing
                                    apps[index].status = .downloading
                                    self.updatesBySource[.appStore] = apps
                                } else if status.contains("Installing") {
                                    // Phase 1: Installing
                                    apps[index].status = .installing
                                    self.updatesBySource[.appStore] = apps
                                } else if status.contains("Completed") || status.contains("Already up to date") {
                                    // Phase 5 or no download needed: Complete - remove from list and refresh
                                    Task {
                                        await self.removeFromUpdatesList(appID: app.id, source: .appStore)
                                        await self.refreshApps(updatedApp: app.appInfo)
                                    }
                                } else {
                                    // Other phases: Keep updating progress but maintain current status
                                    self.updatesBySource[.appStore] = apps
                                }
                            }
                        }
                    }

                    // Update succeeded - refresh happens via completion callback above
                    UpdaterDebugLogger.shared.log(.appStore, "✅ App Store update completed for adamID \(adamID)")
                    GlobalConsoleManager.shared.appendOutput("✓ Successfully updated \(app.appInfo.appName) from App Store\n", source: CurrentPage.updater.title)

                } catch {
                    // Handle errors from the new throwing API
                    let message = error.localizedDescription
                    printOS("❌ App Store update failed for adamID \(adamID): \(message)")
                    GlobalConsoleManager.shared.appendOutput("✗ Failed to update \(app.appInfo.appName) from App Store: \(message)\n", source: CurrentPage.updater.title)

                    // Update UI to show error (matching Sparkle's error display pattern)
                    if var apps = updatesBySource[.appStore],
                       let index = apps.firstIndex(where: { $0.id == app.id }) {
                        apps[index].status = .failed(message)
                        apps[index].progress = 0.0
                        updatesBySource[.appStore] = apps
                    }
                }
            }

        case .sparkle:
            // Use Sparkle's updater via UpdateQueue to prevent concurrent update conflicts
            // SPUUpdater will automatically get feed URL from Info.plist via delegate

            // Check if update already queued/running for this app
            if UpdateQueue.shared.containsOperation(for: app.appInfo.bundleIdentifier) {
                UpdaterDebugLogger.shared.log(.sparkle, "⚠️ Update already queued for \(app.appInfo.appName)")
                printOS("Update already queued for \(app.appInfo.appName)")
                GlobalConsoleManager.shared.appendOutput("⚠ Update already queued for \(app.appInfo.appName)\n", source: CurrentPage.updater.title)
                return
            }

            GlobalConsoleManager.shared.appendOutput("Starting Sparkle update for \(app.appInfo.appName) (target version: \(app.availableVersion ?? "unknown"))...\n", source: CurrentPage.updater.title)

            UpdaterDebugLogger.shared.log(.sparkle, "═══ Initiating update for \(app.appInfo.appName)")
            UpdaterDebugLogger.shared.log(.sparkle, "  Bundle ID: \(app.appInfo.bundleIdentifier)")
            UpdaterDebugLogger.shared.log(.sparkle, "  Current version: \(app.appInfo.appVersion)")
            UpdaterDebugLogger.shared.log(.sparkle, "  Target version: \(app.availableVersion ?? "unknown")")

            // Set initial downloading status
            updateStatus(for: app, status: .downloading, progress: 0.0)

            // Create Sparkle update operation (blocks until completion)
            let operation = SparkleUpdateOperation(
                app: app,
                includePreReleases: self.includeSparklePreReleases,
                progressCallback: { [weak self] progress, status in
                    guard let self = self else { return }
                    Task { @MainActor in
                        self.updateStatus(for: app, status: status, progress: progress)
                    }
                },
                completionCallback: { [weak self] success, error in
                    guard let self = self else { return }
                    Task { @MainActor in
                        switch UpdaterStateLogic.sparkleCompletionDisposition(
                            success: success,
                            hasError: error != nil
                        ) {
                        case .noUpdate:
                            let message = error?.localizedDescription ?? "No update available"
                            UpdaterDebugLogger.shared.log(.sparkle, "═══ No update installed for \(app.appInfo.appName): \(message)")
                            // The earlier check produced a stale row. The
                            // terminal Sparkle result disproves it, but did not
                            // install anything, so remove only that row.
                            await self.removeFromUpdatesList(appID: app.id, source: .sparkle)

                        case .installed:
                            UpdaterDebugLogger.shared.log(.sparkle, "═══ Update completed successfully for \(app.appInfo.appName)")
                            GlobalConsoleManager.shared.appendOutput("✓ Successfully updated \(app.appInfo.appName) via Sparkle\n", source: CurrentPage.updater.title)
                            // Update completed - remove from list and refresh (only flush updated app's bundle)
                            await self.removeFromUpdatesList(appID: app.id, source: .sparkle)
                            await self.refreshApps(updatedApp: app.appInfo)

                        case .failed:
                            // Update failed - show error
                            let message = error?.localizedDescription ?? "Unknown error"
                            UpdaterDebugLogger.shared.log(.sparkle, "═══ Update failed for \(app.appInfo.appName): \(message)")
                            GlobalConsoleManager.shared.appendOutput("✗ Failed to update \(app.appInfo.appName) via Sparkle: \(message)\n", source: CurrentPage.updater.title)
                            self.updateStatus(for: app, status: .failed(message), progress: 0.0)
                        }
                    }
                }
            )

            // Add to queue (limits concurrent operations to prevent Sparkle conflicts)
            UpdateQueue.shared.addOperation(operation)

        case .unsupported:
            // Unsupported apps cannot be updated - do nothing
            UpdaterDebugLogger.shared.log(.sparkle, "⚠️ Cannot update unsupported app: \(app.appInfo.appName)")
            break

        case .current:
            // Current apps are already up-to-date - do nothing
            UpdaterDebugLogger.shared.log(.sparkle, "ℹ️ App is already current: \(app.appInfo.appName)")
            break
        }
    }

    /// Update an iOS app from the App Store
    func updateIOSApp(_ app: UpdateableApp) async {
        guard app.isIOSApp, let adamID = app.adamID else {
            printOS("❌ Not an iOS app or missing adamID")
            GlobalConsoleManager.shared.appendOutput("✗ Not an iOS app or missing adamID for \(app.appInfo.appName)\n", source: CurrentPage.updater.title)
            return
        }

        GlobalConsoleManager.shared.appendOutput("Starting iOS app update for \(app.appInfo.appName) (adamID: \(adamID))...\n", source: CurrentPage.updater.title)

        // Update status
        if var apps = updatesBySource[.appStore],
           let index = apps.firstIndex(where: { $0.id == app.id }) {
            apps[index].status = .downloading
            apps[index].progress = 0.0
            updatesBySource[.appStore] = apps
        }

        // Call AppStoreUpdater to download (which will trigger our observer)
        do {
            try await AppStoreUpdater.shared.updateApp(
                adamID: adamID,
                appPath: app.appInfo.path,
                isIOSApp: true,
                progress: { [weak self] progress, status in
                    Task { @MainActor in
                        guard let self = self else { return }
                        if var apps = self.updatesBySource[.appStore],
                           let index = apps.firstIndex(where: { $0.id == app.id }) {
                            apps[index].progress = progress

                            // Update status based on App Store phase (match real updateApp logic)
                            if status.contains("Downloading") || status.contains("Preparing") {
                                // Phase 0 or 4: Downloading or preparing
                                apps[index].status = .downloading
                                self.updatesBySource[.appStore] = apps
                            } else if status.contains("Installing") {
                                // Phase 1: Installing
                                apps[index].status = .installing
                                self.updatesBySource[.appStore] = apps
                            } else if status.contains("Completed") || status.contains("Already up to date") {
                                // Phase 5 or no download needed: Complete - remove from list and refresh
                                Task {
                                    await self.removeFromUpdatesList(appID: app.id, source: .appStore)
                                    await self.refreshApps(updatedApp: app.appInfo)
                                }
                            } else {
                                // Other phases: Keep updating progress but maintain current status
                                self.updatesBySource[.appStore] = apps
                            }
                        }
                    }
                }
            )
            GlobalConsoleManager.shared.appendOutput("✓ Successfully updated iOS app \(app.appInfo.appName)\n", source: CurrentPage.updater.title)
        } catch {
            printOS("❌ iOS app update failed: \(error)")
            GlobalConsoleManager.shared.appendOutput("✗ Failed to update iOS app \(app.appInfo.appName): \(error.localizedDescription)\n", source: CurrentPage.updater.title)
            if var apps = updatesBySource[.appStore],
               let index = apps.firstIndex(where: { $0.id == app.id }) {
                apps[index].status = .failed("Open in App Store to update using the App Store button to the left.")
                updatesBySource[.appStore] = apps
            }
        }
    }

    func updateAll(source: UpdateSource) async {
        guard let apps = updatesBySource[source] else { return }

        let candidates = apps
            .filter { $0.isSelectedForUpdate }
            .map {
                (
                    app: $0,
                    identity: UpdaterStateLogic.physicalAppIdentity(
                        for: $0.appInfo.path
                    )
                )
            }
        let permittedIdentities =
            UpdaterStateLogic.unambiguousBatchAppIdentities(
                candidates.map {
                    UpdaterStateLogic.BatchSelectionCandidate(
                        physicalAppIdentity: $0.identity,
                        source: $0.app.source
                    )
                }
            )
        let selectedApps = candidates.compactMap {
            permittedIdentities.contains($0.identity) && !$0.app.isIOSApp
                ? $0.app
                : nil
        }

        GlobalConsoleManager.shared.appendOutput("Starting batch update for \(selectedApps.count) app(s) from \(source.rawValue)...\n", source: CurrentPage.updater.title)

        for app in selectedApps {
            await updateApp(app)
        }

        let attemptedIDs = Set(selectedApps.map(\.id))
        let failedCount = (updatesBySource[source] ?? []).filter { app in
            guard attemptedIDs.contains(app.id) else { return false }
            if case .failed = app.status { return true }
            return false
        }.count
        GlobalConsoleManager.shared.appendOutput(
            "Finished starting \(selectedApps.count) \(source.rawValue) update attempt(s); \(failedCount) reported failure.\n",
            source: CurrentPage.updater.title
        )
    }

    /// Update selected physical apps once, in deterministic source order.
    func updateSelectedApps() async {
        var candidates: [(app: UpdateableApp, identity: String)] = []

        for source in UpdateSource.allCases
        where source != .unsupported && source != .current {
            for app in updatesBySource[source] ?? []
            where app.isSelectedForUpdate {
                let identity = UpdaterStateLogic.physicalAppIdentity(
                    for: app.appInfo.path
                )
                candidates.append((app, identity))
            }
        }

        let permittedIdentities =
            UpdaterStateLogic.unambiguousBatchAppIdentities(
                candidates.map {
                    UpdaterStateLogic.BatchSelectionCandidate(
                        physicalAppIdentity: $0.identity,
                        source: $0.app.source
                    )
                }
            )
        let ambiguousCandidates = candidates.filter {
            !permittedIdentities.contains($0.identity)
        }
        let selectedApps = candidates.compactMap {
            permittedIdentities.contains($0.identity) && !$0.app.isIOSApp
                ? $0.app
                : nil
        }
        for identity in Set(ambiguousCandidates.map { $0.identity }) {
            let matching = ambiguousCandidates.filter {
                $0.identity == identity
            }
            let appName = matching.first?.app.appInfo.appName ?? identity
            let sourceNames = Set(matching.map { $0.app.source.rawValue })
                .sorted()
                .joined(separator: ", ")
            GlobalConsoleManager.shared.appendOutput(
                "Skipped \(appName): select only one update source (\(sourceNames)).\n",
                source: CurrentPage.updater.title
            )
        }

        let totalSelected = selectedApps.count
        totalAppsToUpdate = totalSelected
        completedBatchApps = 0
        isUpdatingAll = true

        defer {
            isUpdatingAll = false
            totalAppsToUpdate = 0
            completedBatchApps = 0
        }

        GlobalConsoleManager.shared.appendOutput("Starting updates for \(totalSelected) selected app(s) across all sources...\n", source: CurrentPage.updater.title)

        // Source installers can replace the same bundle and refresh shared app
        // state. Serialize the deduplicated work so a stale result from one
        // source cannot overwrite another source's freshly installed app.
        for app in selectedApps {
            await updateApp(app)
            completedBatchApps += 1
        }

        let attemptedIDs = Set(selectedApps.map(\.id))
        let failedCount = updatesBySource.values
            .flatMap { $0 }
            .filter { app in
                guard attemptedIDs.contains(app.id) else { return false }
                if case .failed = app.status { return true }
                return false
            }
            .count
        GlobalConsoleManager.shared.appendOutput(
            "Finished starting \(totalSelected) selected update attempt(s); \(failedCount) reported failure.\n",
            source: CurrentPage.updater.title
        )
    }

    /// Update the status and progress of an app in the updates list
    private func updateStatus(for app: UpdateableApp, status: UpdateStatus, progress: Double) {
        if var apps = updatesBySource[app.source],
           let index = apps.firstIndex(where: { $0.id == app.id }) {
            apps[index].status = status
            apps[index].progress = progress
            updatesBySource[app.source] = apps
        }
    }

    // REMOVED: refreshSparkleAppWithURL - no longer needed with simplified Sparkle approach
    // Alternate feed URLs are not supported when using SPUUpdater directly

    /// Remove an app from the updates list
    private func removeFromUpdatesList(appID: UUID, source: UpdateSource) async {
        updatesBySource[source]?.removeAll { $0.id == appID }
    }

    /// Refresh all apps after an update
    /// - Parameter updatedApp: Optional specific app that was updated (only flushes that bundle for performance)
    private func refreshApps(updatedApp: AppInfo? = nil) async {
        let folderPaths = await MainActor.run {
            FolderSettingsManager.shared.folderPaths
        }

        // Only flush cache for the app that was just updated (or all if none specified)
        if let app = updatedApp {
            Pearcleaner.flushBundleCaches(for: [app])
        } else {
            Pearcleaner.flushBundleCaches(for: AppState.shared.sortedApps)
        }

        await loadAppsAsync(folderPaths: folderPaths, useStreaming: false)
    }
}
