//
//  AppStoreUpdater.swift
//  Pearcleaner
//
//  Created by Alin Lupascu on 10/13/25.
//
//  Modified for the independently maintained Pearcleaner fork.

import Foundation
import CommerceKit
import StoreFoundation
import AlinFoundation

// MARK: - Error Types

enum AppStoreUpdateError: Error, LocalizedError {
    case noDownloads
    case downloadFailed(String)
    case downloadCancelled
    case networkError(Error)
    case iosUpdatesUnavailable
    case manualAppStoreUpdateRequired

    var errorDescription: String? {
        switch self {
        case .noDownloads:
            return "No App Store download was created. Open the App Store to update this app."
        case .downloadFailed(let message):
            return message
        case .downloadCancelled:
            return "The App Store download was cancelled."
        case .networkError(let error):
            return error.localizedDescription
        case .iosUpdatesUnavailable:
            return "iPhone and iPad app updates must be installed using the App Store."
        case .manualAppStoreUpdateRequired:
            return "This macOS version requires this update to be installed using the App Store."
        }
    }
}

enum AppStoreUpdateRoute: Equatable {
    case commerceKit
    case iosAppStore
    case affectedMacOSAppStore
}

// MARK: - AppStoreUpdater

class AppStoreUpdater {
    static let shared = AppStoreUpdater()

    private init() {}

    static func updateRoute(
        isIOSApp: Bool,
        operatingSystemVersion: OperatingSystemVersion
    ) -> AppStoreUpdateRoute {
        if isIOSApp {
            return .iosAppStore
        }
        if needsInstalldWorkaround(for: operatingSystemVersion) {
            return .affectedMacOSAppStore
        }
        return .commerceKit
    }

    /// Check if running macOS version affected by installd bug.
    /// Affected: macOS 14.8.2+, 15.7.2+, and 26.1+.
    static func needsInstalldWorkaround(for version: OperatingSystemVersion) -> Bool {
        // ProcessInfo returns the macOS product version, not the Darwin
        // kernel version. Compare the components lexicographically.
        if isOperatingSystem(version, atLeast: OperatingSystemVersion(
            majorVersion: 26,
            minorVersion: 1,
            patchVersion: 0
        )) {
            return true
        }

        if version.majorVersion == 15,
           isOperatingSystem(version, atLeast: OperatingSystemVersion(
               majorVersion: 15,
               minorVersion: 7,
               patchVersion: 2
           )) {
            return true
        }

        if version.majorVersion == 14,
           isOperatingSystem(version, atLeast: OperatingSystemVersion(
               majorVersion: 14,
               minorVersion: 8,
               patchVersion: 2
           )) {
            return true
        }

        return false
    }

    private static func isOperatingSystem(
        _ lhs: OperatingSystemVersion,
        atLeast rhs: OperatingSystemVersion
    ) -> Bool {
        if lhs.majorVersion != rhs.majorVersion {
            return lhs.majorVersion > rhs.majorVersion
        }
        if lhs.minorVersion != rhs.minorVersion {
            return lhs.minorVersion > rhs.minorVersion
        }
        return lhs.patchVersion >= rhs.patchVersion
    }

    /// Update an app from the App Store with progress tracking
    /// - Parameters:
    ///   - adamID: The App Store ID of the app
    ///   - appPath: Path to the installed app (for receipt injection)
    ///   - progress: Progress callback (percent: 0.0-1.0, status message)
    ///   - attemptCount: Number of retry attempts for network errors (default: 3)
    func updateApp(
        adamID: UInt64,
        appPath: URL,
        isIOSApp: Bool = false,
        progress: @escaping @Sendable (Double, String) -> Void,
        attemptCount: UInt32 = 3
    ) async throws {
        switch Self.updateRoute(
            isIOSApp: isIOSApp,
            operatingSystemVersion:
                ProcessInfo.processInfo.operatingSystemVersion
        ) {
        case .iosAppStore:
            progress(0.0, "Update in App Store")
            throw AppStoreUpdateError.iosUpdatesUnavailable
        case .affectedMacOSAppStore:
            progress(0.0, "Update in App Store")
            throw AppStoreUpdateError.manualAppStoreUpdateRequired
        case .commerceKit:
            break
        }

        await GlobalConsoleManager.shared.appendOutput("Initiating App Store download for adamID \(adamID)...\n", source: CurrentPage.updater.title)

        do {
            // Create SSPurchase for downloading (purchasing: false = update existing app)
            // NOTE: For iOS apps, all entity types ("software", "macSoftware", "desktopSoftware")
            // download the same universal variant, which is NOT Mac-compatible.
            // iOS app updates are currently non-functional due to Apple's CDN serving wrong variant.
            let purchase = await SSPurchase(adamID: adamID, purchasing: false, kind: "software")

            // Mark as update to indicate this is a redownload of owned app
            purchase.isUpdate = true

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // NOTE: iOS apps will show "Current Version Not Compatible" dialog
                // User must click "Download Last Compatible" to proceed with download
                CKPurchaseController.shared().perform(purchase, withOptions: 0) { _, _, error, response in
                    if let error = error {
                        Task {
                            await GlobalConsoleManager.shared.appendOutput("✗ App Store purchase failed: \(error.localizedDescription)\n", source: CurrentPage.updater.title)
                        }
                        continuation.resume(throwing: error)
                    } else if response?.downloads?.isEmpty == false {
                        // Download started - create observer to track it
                        Task {
                            await GlobalConsoleManager.shared.appendOutput("Download started, monitoring progress...\n", source: CurrentPage.updater.title)
                            do {
                                let observer = AppStoreDownloadObserver(
                                    adamID: adamID,
                                    progress: progress
                                )
                                try await observer.observeDownloadQueue()
                                await GlobalConsoleManager.shared.appendOutput("Download and installation completed successfully\n", source: CurrentPage.updater.title)
                                continuation.resume()
                            } catch {
                                await GlobalConsoleManager.shared.appendOutput("✗ Download/installation failed: \(error.localizedDescription)\n", source: CurrentPage.updater.title)
                                continuation.resume(throwing: error)
                            }
                        }
                    } else {
                        // An empty response is ambiguous. Do not report success
                        // without a download/install completion signal.
                        Task {
                            await GlobalConsoleManager.shared.appendOutput("✗ App Store returned no download\n", source: CurrentPage.updater.title)
                        }
                        progress(0.0, "Update in App Store")
                        continuation.resume(
                            throwing: AppStoreUpdateError.noDownloads
                        )
                    }
                }
            }
        } catch {
            // Retry logic for network errors (like mas does)
            guard attemptCount > 1 else {
                await GlobalConsoleManager.shared.appendOutput("✗ Update failed after retries: \(error.localizedDescription)\n", source: CurrentPage.updater.title)
                throw error
            }

            // Only retry network errors
            guard (error as NSError).domain == NSURLErrorDomain else {
                await GlobalConsoleManager.shared.appendOutput("✗ Non-network error, not retrying: \(error.localizedDescription)\n", source: CurrentPage.updater.title)
                throw error
            }

            let remainingAttempts = attemptCount - 1
            await GlobalConsoleManager.shared.appendOutput("Network error, retrying... (\(remainingAttempts) attempts remaining)\n", source: CurrentPage.updater.title)
            try await updateApp(adamID: adamID, appPath: appPath, isIOSApp: isIOSApp, progress: progress, attemptCount: remainingAttempts)
        }
    }
}

// MARK: - AppStoreDownloadObserver

/// Per-download observer that tracks a single App Store download/update
/// This matches the architecture used by mas CLI tool
private final class AppStoreDownloadObserver: NSObject, CKDownloadQueueObserver {
    private let adamID: UInt64
    private let progressCallback: @Sendable (Double, String) -> Void
    private var completionHandler: (() -> Void)?
    private var errorHandler: ((Error) -> Void)?

    init(adamID: UInt64, progress: @escaping @Sendable (Double, String) -> Void) {
        self.adamID = adamID
        self.progressCallback = progress
        super.init()
    }

    /// Observe the download queue until this download completes
    /// Uses defer to ensure observer is always removed when done
    func observeDownloadQueue(_ queue: CKDownloadQueue = .shared()) async throws {
        let observerID = queue.add(self)
        defer {
            queue.removeObserver(observerID)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            completionHandler = { [weak self] in
                self?.completionHandler = nil
                self?.errorHandler = nil
                continuation.resume()
            }
            errorHandler = { [weak self] error in
                self?.completionHandler = nil
                self?.errorHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - CKDownloadQueueObserver Delegate Methods

    func downloadQueue(_ queue: CKDownloadQueue, changedWithAddition download: SSDownload) {
        // Download was added to queue - no action needed
    }

    func downloadQueue(_ queue: CKDownloadQueue, changedWithRemoval download: SSDownload) {
        guard let metadata = download.metadata,
              metadata.itemIdentifier == adamID,
              let status = download.status else {
            return
        }

        // This is the official completion signal from CommerceKit
        if status.isFailed {
            let error = status.error ?? AppStoreUpdateError.downloadFailed("Download failed")
            Task {
                await GlobalConsoleManager.shared.appendOutput("✗ App Store download failed: \(error.localizedDescription)\n", source: CurrentPage.updater.title)
            }
            errorHandler?(error)
        } else if status.isCancelled {
            Task {
                await GlobalConsoleManager.shared.appendOutput("Download cancelled by user\n", source: CurrentPage.updater.title)
            }
            errorHandler?(AppStoreUpdateError.downloadCancelled)
        } else {
            // Success!
            Task {
                await GlobalConsoleManager.shared.appendOutput("App Store download completed\n", source: CurrentPage.updater.title)
            }
            progressCallback(1.0, "Completed")
            completionHandler?()
        }
    }

    func downloadQueue(_ queue: CKDownloadQueue, statusChangedFor download: SSDownload) {
        guard let metadata = download.metadata,
              metadata.itemIdentifier == adamID,
              let status = download.status,
              let activePhase = status.activePhase else {
            return
        }

        let phaseType = activePhase.phaseType
        let percentComplete = status.percentComplete  // Float: 0.0 to 1.0
        let progress = max(0.0, min(1.0, Double(percentComplete)))

        // Report progress based on phase
        // Special case: at 100%, always show "Installing..." (CommerceKit sometimes resets to phase 0 at completion)
        if progress >= 1.0 {
            progressCallback(progress, "Installing...")
        } else {
            switch phaseType {
            case 0: // Downloading
                progressCallback(progress, "Downloading...")

            case 1: // Installing
                progressCallback(progress, "Installing...")

            case 4: // Initial/Preparing
                progressCallback(progress, "Preparing...")

            case 5: // Downloaded (not complete yet - wait for changedWithRemoval)
                progressCallback(progress, "Installing...")

            default:
                progressCallback(progress, "Processing...")
            }
        }
    }
}
