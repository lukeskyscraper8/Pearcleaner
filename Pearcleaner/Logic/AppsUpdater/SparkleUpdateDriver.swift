//
//  SparkleUpdateDriver.swift
//  Pearcleaner
//
//  Custom SPUUserDriver for programmatically controlling Sparkle updates.
//  Allows Pearcleaner to download and install updates for third-party Sparkle apps directly.
//
//  Modified for the independently maintained Pearcleaner fork.

import Foundation
import Sparkle

enum SparkleUpdateDriverError: LocalizedError {
    case invalidAppBundle(URL)

    var errorDescription: String? {
        switch self {
        case .invalidAppBundle(let url):
            return "The app at \(url.path) is no longer a valid bundle."
        }
    }
}

class SparkleUpdateDriver: NSObject, SPUUserDriver, SPUUpdaterDelegate, @unchecked Sendable {

    // MARK: - Properties

    private let appBundle: Bundle
    private let includePreReleases: Bool
    private let cachedAppcastItem: SUAppcastItem?  // Pre-validated item from check phase
    private var updater: SPUUpdater?
    private let progressCallback: (Double, UpdateStatus) -> Void
    private let completionCallback: (Bool, Error?) -> Void

    private var downloadedBytes: Int64 = 0
    private var totalBytes: Int64 = 0
    private let completionLock = NSLock()
    private var hasCompleted = false

    private let logger = UpdaterDebugLogger.shared

    // MARK: - Initialization

    init?(appInfo: AppInfo,
          includePreReleases: Bool,
          cachedAppcastItem: SUAppcastItem?,
          progressCallback: @escaping (Double, UpdateStatus) -> Void,
          completionCallback: @escaping (Bool, Error?) -> Void) {
        guard let bundle = Bundle(url: appInfo.path) else {
            return nil
        }
        self.appBundle = bundle
        self.includePreReleases = includePreReleases
        self.cachedAppcastItem = cachedAppcastItem
        self.progressCallback = progressCallback
        self.completionCallback = completionCallback
        super.init()

        // Debug: Log cached item status in driver
        if let cachedItem = cachedAppcastItem {
            logger.log(.sparkle, "  🔍 DEBUG: SparkleUpdateDriver received cached item: \(cachedItem.displayVersionString) (build: \(cachedItem.versionString))")
        } else {
            logger.log(.sparkle, "  ⚠️ DEBUG: SparkleUpdateDriver received nil cached item")
        }
    }

    // MARK: - Public Methods

    private func finish(success: Bool, error: Error?) {
        completionLock.lock()
        guard !hasCompleted else {
            completionLock.unlock()
            return
        }
        hasCompleted = true
        completionLock.unlock()
        completionCallback(success, error)

        // SPUUpdater retains its user driver. Release our reference on the next
        // main-actor turn, after Sparkle's synchronous acknowledgement returns,
        // so terminal update checks cannot leak the driver/updater cycle.
        Task { @MainActor [weak self] in
            self?.updater = nil
        }
    }

    func startUpdate() {
        logger.log(.sparkle, "━━━ Starting Sparkle update for \(appBundle.bundleIdentifier ?? "unknown")")
        logger.log(.sparkle, "  App path: \(appBundle.bundlePath)")

        Task { @MainActor in
            GlobalConsoleManager.shared.appendOutput("Initializing Sparkle updater for \(appBundle.bundleURL.lastPathComponent)...\n", source: CurrentPage.updater.title)
        }

        // Check for public key
        if let publicKey = appBundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String {
            logger.log(.sparkle, "  ✓ Found SUPublicEDKey: \(publicKey.prefix(20))...")
        } else {
            logger.log(.sparkle, "  ⚠️ No SUPublicEDKey found")
        }

        updater = SPUUpdater(
            hostBundle: appBundle,
            applicationBundle: appBundle,
            userDriver: self,
            delegate: self
        )

        do {
            try updater?.start()
            logger.log(.sparkle, "  ✓ Sparkle updater started successfully")
            updater?.checkForUpdates()
            logger.log(.sparkle, "  ✓ Triggered user-initiated update check (forces SPUUserDriver callbacks)")
        } catch {
            logger.log(.sparkle, "  ❌ Failed to start updater: \(error.localizedDescription)")
            Task { @MainActor in
                GlobalConsoleManager.shared.appendOutput("✗ Failed to start Sparkle updater: \(error.localizedDescription)\n", source: CurrentPage.updater.title)
            }
            finish(success: false, error: error)
        }
    }

    // MARK: - SPUUserDriver Protocol (Auto-approve installation, track progress)

    func show(_ request: SPUUpdatePermissionRequest,
             reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Auto-approve without showing permission dialog
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true,
                                        sendSystemProfile: false))
    }

    func showUpdateFound(with appcastItem: SUAppcastItem,
                        state: SPUUserUpdateState,
                        reply: @escaping (SPUUserUpdateChoice) -> Void) {
        logger.log(.sparkle, "  ✓ Update found: \(appcastItem.displayVersionString) (build \(appcastItem.versionString))")
        if let fileURL = appcastItem.fileURL {
            logger.log(.sparkle, "  Download URL: \(fileURL.absoluteString)")
        }
        logger.log(.sparkle, "  Auto-approving installation...")

        Task { @MainActor in
            GlobalConsoleManager.shared.appendOutput("Found update: \(appcastItem.displayVersionString), starting download...\n", source: CurrentPage.updater.title)
        }

        // Auto-approve installation (no UI)
        progressCallback(0.0, .downloading)
        reply(.install)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        totalBytes = Int64(expectedContentLength)
        let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(expectedContentLength), countStyle: .file)
        logger.log(.sparkle, "  Starting download (\(sizeStr))...")

        Task { @MainActor in
            GlobalConsoleManager.shared.appendOutput("Downloading update (\(sizeStr))...\n", source: CurrentPage.updater.title)
        }
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        downloadedBytes += Int64(length)
        let progress = totalBytes > 0 ? Double(downloadedBytes) / Double(totalBytes) : 0.0

        // Log at 25%, 50%, 75% milestones
        let percentage = Int(progress * 100)
        if percentage > 0 && percentage % 25 == 0 {
            let downloaded = ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            logger.log(.sparkle, "  Download progress: \(percentage)% (\(downloaded) / \(total))")
        }

        // Download = 0-75% of total progress
        progressCallback(progress * 0.75, .downloading)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        let percentage = Int(progress * 100)
        if percentage > 0 && percentage % 25 == 0 {
            logger.log(.sparkle, "  Extraction progress: \(percentage)%")
        }

        // Log extraction start (once at 0%)
        if percentage == 0 {
            Task { @MainActor in
                GlobalConsoleManager.shared.appendOutput("Extracting update...\n", source: CurrentPage.updater.title)
            }
        }

        // Extraction = 75-95% of total progress
        progressCallback(0.75 + (progress * 0.20), .extracting)
    }

    func showInstallingUpdate(withApplicationTerminated: Bool,
                            retryTerminatingApplication: @escaping () -> Void) {
        if withApplicationTerminated {
            logger.log(.sparkle, "  ✓ Target app terminated, installing update...")
            Task { @MainActor in
                GlobalConsoleManager.shared.appendOutput("Target app terminated, installing update...\n", source: CurrentPage.updater.title)
            }
        } else {
            logger.log(.sparkle, "  Installing update (app will be terminated)...")
            Task { @MainActor in
                GlobalConsoleManager.shared.appendOutput("Installing update (app will be terminated)...\n", source: CurrentPage.updater.title)
            }
        }
        // Installing = 95-100%
        progressCallback(0.95, .installing)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool,
                                         acknowledgement: @escaping () -> Void) {
        logger.log(.sparkle, "  ✓✓✓ Update installed successfully!")
        if relaunched {
            logger.log(.sparkle, "  App relaunched")
        }

        Task { @MainActor in
            GlobalConsoleManager.shared.appendOutput("✓ Sparkle update installed successfully\n", source: CurrentPage.updater.title)
            if relaunched {
                GlobalConsoleManager.shared.appendOutput("App relaunched\n", source: CurrentPage.updater.title)
            }
        }

        progressCallback(1.0, .completed)
        finish(success: true, error: nil)
        acknowledgement()
    }

    func showUpdaterError(_ error: Error,
                         acknowledgement: @escaping () -> Void) {
        logger.log(.sparkle, "  ❌❌❌ Sparkle updater error:")
        logger.log(.sparkle, "    \(error.localizedDescription)")
        if let nsError = error as NSError? {
            logger.log(.sparkle, "    Domain: \(nsError.domain), Code: \(nsError.code)")
            if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
                logger.log(.sparkle, "    Underlying: \(underlyingError.localizedDescription)")
            }
        }

        Task { @MainActor in
            GlobalConsoleManager.shared.appendOutput("✗ Sparkle updater error: \(error.localizedDescription)\n", source: CurrentPage.updater.title)
        }

        finish(success: false, error: error)
        acknowledgement()
    }

    // MARK: - SPUUserDriver Protocol (Stubbed UI methods)

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        // No UI - stub
    }

    func dismissUserInitiatedUpdateCheck() {
        // No UI - stub
    }

    func showUpdateNotFoundWithError(_ error: Error,
                                    acknowledgement: @escaping () -> Void) {
        logger.log(.sparkle, "  ℹ️ No update found: \(error.localizedDescription)")

        Task { @MainActor in
            GlobalConsoleManager.shared.appendOutput("No update available: \(error.localizedDescription)\n", source: CurrentPage.updater.title)
        }

        // The queued operation waits on its completion callback. Treat a
        // no-update response as a successful terminal state so the next app
        // can proceed, while preserving the error so callers do not report
        // that an installation occurred.
        progressCallback(0.0, .idle)
        finish(success: true, error: error)
        acknowledgement()
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // No UI - stub
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        // No UI - stub
    }

    func showUpdateInFocus() {
        // No UI - stub
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        // No UI - stub
    }

    func showDownloadDidStartExtractingUpdate() {
        // No UI - stub
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // Auto-approve installation
        reply(.install)
    }

    func showSendingTerminationSignal() {
        // No UI - stub
    }

    func dismissUpdateInstallation() {
        // No UI - stub
    }

    func showCanCheck(forUpdates canCheckForUpdates: Bool) {
        // No UI - stub
    }

    // MARK: - SPUUpdaterDelegate Protocol

    func feedURLString(for updater: SPUUpdater) -> String? {
        // Provide DevMate fallback for apps without SUFeedURL in Info.plist
        // SPUUpdater automatically reads SUFeedURL from Info.plist first, then calls this delegate
        return SparkleUpdateChecker.feedURL(from: updater.hostBundle)?.absoluteString
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        // If pre-releases are enabled, allow common pre-release channels
        // If disabled, return empty set (only default/stable channel)
        guard includePreReleases else {
            return []
        }

        // Common pre-release channel names used by Sparkle apps
        return ["beta", "alpha", "nightly", "rc", "dev"]
    }

    func bestValidUpdate(in appcast: SUAppcast, for updater: SPUUpdater) -> SUAppcastItem? {
        // If we have a cached appcast item from the check phase, use it
        // This ensures consistent version selection between check and install
        if let cachedItem = cachedAppcastItem {
            logger.log(.sparkle, "  ✅ Using cached appcast item: \(cachedItem.displayVersionString) (build: \(cachedItem.versionString))")
            logger.log(.sparkle, "     Skipping re-validation - item was already validated during check phase")
            return cachedItem
        }

        // No cached item - shouldn't happen in normal flow, but fall back to nil
        // Sparkle will use its own bestValidUpdate logic
        logger.log(.sparkle, "  ⚠️ No cached appcast item - using Sparkle's default validation")
        return nil
    }
}
