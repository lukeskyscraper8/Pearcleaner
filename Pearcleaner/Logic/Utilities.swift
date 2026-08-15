//
//  Utilities.swift
//  Pearcleaner
//
//  Created by Alin Lupascu on 11/3/23.
//  Modified for the independently maintained Pearcleaner fork.
//

import Foundation
import SwiftUI
import AlinFoundation
import AppKit
import AudioToolbox
import OpenDirectory
import Security
import Darwin

extension String {
    var shellQuoted: String {
        "'\(replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

/// Removes credentials written by Pearcleaner versions that cached sudo
/// passwords. The cache is no longer supported because a reusable password
/// should never be exposed through an askpass command.
func removeLegacySudoPasswordCache() {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.lukerow.Pearcleaner.SudoPassword",
        kSecAttrAccount as String: NSUserName()
    ]
    SecItemDelete(query as CFDictionary)
    UserDefaults.standard.removeObject(forKey: "settings.general.sudoCacheTimeout")
}

func ifOSBelow(macOS major: Int, _ minor: Int = 0, _ patch: Int = 0) -> Bool {
    if !ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
    ) {
        return true
    } else {
        return false
    }
}

func playTrashSound(undo: Bool = false) {
    let soundName = undo ? "poof item off dock.aif" : "drag to trash.aif"
    let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/\(soundName)"
    let url = URL(fileURLWithPath: path)

    var soundID: SystemSoundID = 0
    AudioServicesCreateSystemSoundID(url as CFURL, &soundID)
    AudioServicesPlaySystemSound(soundID)
}


// Check if pear symlink exists
func checkCLISymlink() -> Bool {
    guard let executablePath = Bundle.main.executablePath else {
        return false
    }
    return managedCLISymlinkMatchesExecutable(
        at: "/usr/local/bin/pear",
        executablePath: executablePath
    )
}

func managedCLISymlinkMatchesExecutable(
    at symlinkPath: String,
    executablePath: String
) -> Bool {
    var fileInfo = stat()
    guard lstat(symlinkPath, &fileInfo) == 0,
          (fileInfo.st_mode & S_IFMT) == S_IFLNK else {
        return false
    }

    do {
        let destination = try FileManager.default.destinationOfSymbolicLink(
            atPath: symlinkPath
        )
        let destinationURL = destination.hasPrefix("/")
            ? URL(fileURLWithPath: destination)
            : URL(fileURLWithPath: symlinkPath)
                .deletingLastPathComponent()
                .appendingPathComponent(destination)
        return destinationURL.standardizedFileURL ==
            URL(fileURLWithPath: executablePath).standardizedFileURL
    } catch {
        return false
    }
}

func cliSymlinkAncestryAllowsPrivilege(
    _ requiredDirectories: [URL],
    isRealDirectory: (URL) -> Bool = pathIsDirectoryWithoutFollowingSymlinks,
    isWritable: (URL) -> Bool = {
        FileManager.default.isWritableFile(atPath: $0.path)
    }
) -> Bool {
    requiredDirectories.allSatisfy {
        isRealDirectory($0) && !isWritable($0)
    }
}

// Fix legacy pearcleaner symlink if it exists
func fixLegacySymlink() {
    let legacyPath = "/usr/local/bin/pearcleaner"
    if pathExistsWithoutFollowingSymlinks(URL(fileURLWithPath: legacyPath)) {
        manageSymlink(install: false, symlinkName: "pearcleaner")
        manageSymlink(install: true, symlinkName: "pear")
    }
}

// Install/uninstall symlink for CLI
func manageSymlink(install: Bool, symlinkName: String = "pear") {
    @AppStorage("settings.general.cli") var isCLISymlinked = false

    guard ["pear", "pearcleaner"].contains(symlinkName) else {
        printOS("Symlink operation rejected: Unsupported CLI symlink name.")
        return
    }

    guard let appPath = Bundle.main.executablePath else {
        printOS("Error: Unable to get the executable path.")
        return
    }

    let symlinkPath = "/usr/local/bin/\(symlinkName)"
    let symlinkURL = URL(fileURLWithPath: symlinkPath)
    let rootURL = URL(fileURLWithPath: "/", isDirectory: true)
    let usrURL = URL(fileURLWithPath: "/usr", isDirectory: true)
    let localURL = URL(fileURLWithPath: "/usr/local", isDirectory: true)
    let binURL = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
    let fileManager = FileManager.default
    let symlinkExists = pathExistsWithoutFollowingSymlinks(symlinkURL)

    if install && symlinkExists {
        if managedCLISymlinkMatchesExecutable(
            at: symlinkPath,
            executablePath: appPath
        ) {
            printOS("Symlink already exists at \(symlinkPath). No action needed.")
        } else {
            printOS(
                "Symlink creation rejected: An unmanaged item already exists at \(symlinkPath)."
            )
        }
        updateOnMain {
            isCLISymlinked = checkCLISymlink()
        }
        return
    }

    if !install && !symlinkExists {
        printOS("Symlink does not exist at \(symlinkPath). No action needed.")
        return
    }

    let privilegedRequiresExistingBin: Bool
    if install {
        guard pathIsDirectoryWithoutFollowingSymlinks(rootURL),
              pathIsDirectoryWithoutFollowingSymlinks(usrURL),
              pathIsDirectoryWithoutFollowingSymlinks(localURL) else {
            printOS(
                "Symlink creation rejected: /usr/local has an unexpected or symlinked path ancestry."
            )
            return
        }

        let binExists = pathExistsWithoutFollowingSymlinks(binURL)
        if binExists && !pathIsDirectoryWithoutFollowingSymlinks(binURL) {
            printOS(
                "Symlink creation rejected: /usr/local/bin is not a real directory."
            )
            return
        }

        if binExists && fileManager.isWritableFile(atPath: binURL.path) {
            do {
                guard !pathExistsWithoutFollowingSymlinks(symlinkURL) else {
                    throw NSError(
                        domain: "PearcleanerCLISymlink",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "The destination appeared before creation."]
                    )
                }
                try fileManager.createSymbolicLink(
                    at: symlinkURL,
                    withDestinationURL: URL(fileURLWithPath: appPath)
                )
            } catch {
                printOS("Symlink creation failed: \(error.localizedDescription)")
            }
            updateOnMain {
                isCLISymlinked = checkCLISymlink()
            }
            return
        }

        if !binExists && fileManager.isWritableFile(atPath: localURL.path) {
            do {
                try fileManager.createDirectory(
                    at: binURL,
                    withIntermediateDirectories: false
                )
                guard pathIsDirectoryWithoutFollowingSymlinks(binURL),
                      !pathExistsWithoutFollowingSymlinks(symlinkURL) else {
                    throw NSError(
                        domain: "PearcleanerCLISymlink",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "The CLI directory changed before creation."]
                    )
                }
                try fileManager.createSymbolicLink(
                    at: symlinkURL,
                    withDestinationURL: URL(fileURLWithPath: appPath)
                )
            } catch {
                printOS("Symlink creation failed: \(error.localizedDescription)")
            }
            updateOnMain {
                isCLISymlinked = checkCLISymlink()
            }
            return
        }

        let protectedDirectories = binExists
            ? [rootURL, usrURL, localURL, binURL]
            : [rootURL, usrURL, localURL]
        guard cliSymlinkAncestryAllowsPrivilege(protectedDirectories) else {
            printOS(
                "Symlink creation rejected: A user-writable ancestor could be swapped during authorization."
            )
            return
        }

        privilegedRequiresExistingBin = binExists
    } else {
        guard managedCLISymlinkMatchesExecutable(
            at: symlinkPath,
            executablePath: appPath
        ) else {
            printOS(
                "Symlink removal rejected: \(symlinkPath) is not a Pearcleaner-managed symlink."
            )
            updateOnMain {
                isCLISymlinked = checkCLISymlink()
            }
            return
        }

        guard [rootURL, usrURL, localURL, binURL].allSatisfy(
            pathIsDirectoryWithoutFollowingSymlinks
        ) else {
            printOS(
                "Symlink removal rejected: /usr/local/bin has an unexpected or symlinked path ancestry."
            )
            return
        }

        if fileManager.isWritableFile(atPath: binURL.path) {
            do {
                try fileManager.removeItem(at: symlinkURL)
            } catch {
                printOS("Symlink removal failed: \(error.localizedDescription)")
            }
            updateOnMain {
                isCLISymlinked = checkCLISymlink()
            }
            return
        }

        guard cliSymlinkAncestryAllowsPrivilege(
            [rootURL, usrURL, localURL, binURL]
        ) else {
            printOS(
                "Symlink removal rejected: A user-writable or symlinked ancestor could be swapped during authorization."
            )
            return
        }
        privilegedRequiresExistingBin = true
    }

    // Perform privileged commands using the unified wrapper.
    Task {
        do {
            let operation = install ? "create" : "remove"
            let protectedDirectories = privilegedRequiresExistingBin
                ? [rootURL, usrURL, localURL, binURL]
                : [rootURL, usrURL, localURL]
            guard cliSymlinkAncestryAllowsPrivilege(protectedDirectories),
                  (
                    privilegedRequiresExistingBin
                        ? pathIsDirectoryWithoutFollowingSymlinks(binURL)
                        : !pathExistsWithoutFollowingSymlinks(binURL)
                  ) else {
                printOS(
                    "CLI symlink \(operation) rejected: The path ancestry changed before authorization."
                )
                return
            }
            if install {
                guard !pathExistsWithoutFollowingSymlinks(symlinkURL) else {
                    printOS(
                        "CLI symlink creation rejected: The destination appeared before creation."
                    )
                    return
                }
            } else {
                guard managedCLISymlinkMatchesExecutable(
                    at: symlinkPath,
                    executablePath: appPath
                ) else {
                    printOS(
                        "CLI symlink removal rejected: The managed symlink changed before removal."
                    )
                    return
                }
            }

            let result = try await runSUOperation(
                name: install ? "create-cli-symlink" : "remove-cli-symlink",
                arguments: install
                    ? [appPath, symlinkName] + (privilegedRequiresExistingBin ? [] : ["mkdir"])
                    : [symlinkName],
                errorContext: "Failed to \(operation) CLI symlink",
                throwOnFailure: false
            )

            if !result.0 {
                printOS("Symlink \(operation) failed: \(result.1)")
            }
        } catch {
            printOS("CLI symlink operation failed: \(error.localizedDescription)")
        }

        updateOnMain {
            isCLISymlinked = checkCLISymlink()
        }
    }
}

func directoryExists(at path: String) -> Bool {
    let fileManager = FileManager.default
    return fileManager.fileExists(atPath: path, isDirectory: nil)
}

// Open trash folder
func openTrash() {
    if let trashURL = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
        NSWorkspace.shared.open(trashURL)
    }
}

// Check if restricted app
func isRestricted(atPath path: URL) -> Bool {
    if path.path.contains("/Applications/Safari") || path.path.contains(Bundle.main.name) || path.path.contains("/Applications/Utilities") {
        return true
    } else {
        return false
    }
}


// Check app bundle architecture
func checkAppBundleArchitecture(at appBundlePath: String) -> Arch {
    return autoreleasepool {
        let bundleURL = URL(fileURLWithPath: appBundlePath)
        let infoPlistURL = bundleURL.appendingPathComponent("Contents/Info.plist")

        // Read Info.plist in autoreleasepool to release immediately
        let executableName: String? = autoreleasepool {
            guard let infoDict = NSDictionary(contentsOf: infoPlistURL) as? [String: Any] else {
                return nil
            }
            return infoDict["CFBundleExecutable"] as? String
        }

        guard let execName = executableName else {
            return .empty
        }

        let executableURL = bundleURL.appendingPathComponent("Contents/MacOS").appendingPathComponent(execName)

        guard let layout = try? MachOSafety.inspect(executableURL) else {
            return .empty
        }

        switch layout {
        case .fat(let architectures, _):
            let hasArm = architectures.contains {
                $0.cpuType == MachOSafety.arm64CPUType
            }
            let hasIntel = architectures.contains {
                $0.cpuType == MachOSafety.x86_64CPUType
            }
            if hasArm && hasIntel {
                return .universal
            }
            if hasArm {
                return .arm
            }
            if hasIntel {
                return .intel
            }
            return .empty

        case .thin(let cpuType, _):
            if cpuType == MachOSafety.arm64CPUType {
                return .arm
            }
            if cpuType == MachOSafety.x86_64CPUType {
                return .intel
            }
            return .empty
        }
    }
}


enum BundleThinningOutcome {
    case succeeded([String: UInt64]?)
    case partiallySucceeded([String: UInt64]?, String)
    case blocked(AppBundleMutationEligibility)
    case failed(String)

    var succeeded: Bool {
        switch self {
        case .succeeded, .partiallySucceeded:
            return true
        case .blocked, .failed:
            return false
        }
    }

    var sizes: [String: UInt64]? {
        switch self {
        case .succeeded(let sizes), .partiallySucceeded(let sizes, _):
            return sizes
        case .blocked, .failed:
            return nil
        }
    }
}

func thinAppBundleArchitectureOutcome(
    at appBundlePath: URL,
    of arch: Arch,
    multi: Bool = false,
    dryRun: Bool = false,
    showAlert: Bool = true
) -> BundleThinningOutcome {
    _ = arch

    if !dryRun {
        let eligibility = AppBundleMutationSafety.inspect(appBundlePath)
        guard eligibility.allowsMutation else {
            return .blocked(eligibility)
        }
    }

    // Keep real thinning in-process. An installed helper may predate the
    // validated parser and atomic replacement path, and a lost mutating XPC
    // reply cannot be retried safely.
    let result = thinAppBundleDetailed(
        at: appBundlePath,
        dryRun: dryRun
    )
    let outcome: BundleThinningOutcome
    switch result.status {
    case .succeeded:
        outcome = .succeeded(result.sizes)
    case .partiallySucceeded:
        outcome = .partiallySucceeded(result.sizes, result.message)
    case .blocked(let eligibility):
        return .blocked(eligibility)
    case .failed:
        return .failed(result.message)
    }

    if !dryRun {
        let sizes = result.sizes
        if !multi {
            let calculatedSize = totalSizeOnDisk(for: appBundlePath)
            updateOnMain {
                if AppState.shared.appInfo.path == appBundlePath {
                    var updatedAppInfo = AppState.shared.appInfo
                    updatedAppInfo.bundleSize = calculatedSize
                    updatedAppInfo.fileSize[appBundlePath] = calculatedSize
                    if case .succeeded = outcome {
                        updatedAppInfo.arch = isOSArm() ? .arm : .intel
                    }
                    AppState.shared.appInfo = updatedAppInfo
                }

                if case .succeeded = outcome,
                   showAlert,
                   let bundleSizes = sizes,
                   let preSize = bundleSizes["pre"],
                   let postSize = bundleSizes["post"],
                   preSize > 0 {
                    let savedSize = preSize > postSize ? preSize - postSize : 0
                    let savingsPercentage = Int(
                        (Double(savedSize) / Double(preSize)) * 100
                    )
                    let title = String(
                        format: NSLocalizedString(
                            "Space Savings: %d%%",
                            comment: "Lipo result title"
                        ),
                        savingsPercentage
                    )
                    let message = NSLocalizedString(
                        "Bundle thinning complete.\nTotal space saved from all binaries in bundle.",
                        comment: "Lipo result message"
                    )
                    showCustomAlert(
                        title: title,
                        message: message,
                        style: .informational
                    )
                }
            }
        } else {
            let calculatedSize = totalSizeOnDisk(for: appBundlePath)
            DispatchQueue.main.async {
                if let index = AppState.shared.sortedApps.firstIndex(where: {
                    $0.path == appBundlePath
                }) {
                    var updatedAppInfo = AppState.shared.sortedApps[index]
                    updatedAppInfo.bundleSize = calculatedSize
                    if case .succeeded = outcome {
                        updatedAppInfo.arch = isOSArm() ? .arm : .intel
                    }
                    AppState.shared.sortedApps[index] = updatedAppInfo
                }
            }
        }
    }

    return outcome
}

func terminateAppForMutation(
    bundleIdentifier: String,
    timeoutNanoseconds: UInt64 = 3_000_000_000
) async -> Bool {
    let matchingApps = NSWorkspace.shared.runningApplications.filter {
        $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated
    }
    guard !matchingApps.isEmpty else { return true }

    for app in matchingApps where !app.terminate() {
        return false
    }

    let pollingInterval: UInt64 = 100_000_000
    var elapsed: UInt64 = 0
    while elapsed < timeoutNanoseconds {
        if matchingApps.allSatisfy(\.isTerminated) {
            return true
        }
        try? await Task.sleep(nanoseconds: pollingInterval)
        elapsed += pollingInterval
    }
    return matchingApps.allSatisfy(\.isTerminated)
}

// Compatibility wrapper for read-only estimators and existing callers.
func thinAppBundleArchitecture(
    at appBundlePath: URL,
    of arch: Arch,
    multi: Bool = false,
    dryRun: Bool = false,
    showAlert: Bool = true
) -> (Bool, [String: UInt64]?) {
    let outcome = thinAppBundleArchitectureOutcome(
        at: appBundlePath,
        of: arch,
        multi: multi,
        dryRun: dryRun,
        showAlert: showAlert
    )
    return (outcome.succeeded, outcome.sizes)
}



// Check if app is running before deleting app files
func killApp(appId: String) async {
    let runningApps = NSWorkspace.shared.runningApplications
    for app in runningApps {
        if app.bundleIdentifier == appId {
            app.terminate()
        }
    }
}


//MARK: Broken on 13.0
// Open app settings
//func openAppSettings() {
//    if #available(macOS 14.0, *) {
//        @Environment(\.openSettings) var openSettings
//        openSettings()
//    } else {
//        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
//    }
//}


func openAppSettingsWindow(tab: CurrentTabView? = nil, updater: Updater) {
    // Determine which tab to open:
    // 1. If caller explicitly passes a tab (not nil), use it and save as new preference
    // 2. Otherwise, check for saved tab preference
    // 3. If no saved preference, default to .general

    if let requestedTab = tab {
        // Explicit tab request - use it and save as new preference
        UserDefaults.standard.set(requestedTab.rawValue, forKey: "settings.general.selectedTab")
    } else if UserDefaults.standard.object(forKey: "settings.general.selectedTab") == nil {
        // No saved preference - default to general and save it
        UserDefaults.standard.set(CurrentTabView.general.rawValue, forKey: "settings.general.selectedTab")
    }
    // Otherwise, use the existing saved preference (no need to set it again)

    // Note: Tab changes during use are handled by @AppStorage in SettingsView

    // Create SettingsView with environment objects
    let settingsView = SettingsView()
        .environmentObject(AppState.shared)
        .environmentObject(Locations())
        .environmentObject(FolderSettingsManager.shared)
        .environmentObject(updater)
        .environmentObject(PermissionManager.shared)
        .frame(width: 800, height: 710)
        .navigationTitle("")

    // Open using WindowManager
    WindowManager.shared.open(
        id: "settings",
        with: settingsView,
        width: 800,
        height: 710,
        resizable: false,
        toolbarStyle: .unified
    )
}

// Get user profile picture
struct UserProfile {
    let firstName: String?
    let image: NSImage?
}

func getUserProfile() async -> UserProfile {
    // Use Task.detached to completely break QoS inheritance and escalation
    // This prevents the system from escalating to match the caller's QoS
    await Task.detached(priority: .medium) {
        do {
            let session = ODSession.default()
            let node = try ODNode(session: session, type: UInt32(kODNodeTypeLocalNodes))
            let record = try node.record(
                withRecordType: kODRecordTypeUsers,
                name: NSUserName(),
                attributes: ["dsAttrTypeStandard:RealName",
                             kODAttributeTypeJPEGPhoto]
            )

            // First name
            var firstName: String? = nil
            if let realName = (try? record.values(forAttribute: "dsAttrTypeStandard:RealName") as? [String])?.first {
                firstName = realName.components(separatedBy: " ").first
            }

            // JPEG photo
            var resizedImage: NSImage? = nil
            if let dataList = try? record.values(forAttribute: kODAttributeTypeJPEGPhoto) as? [Data],
               let data = dataList.first,
               let img = NSImage(data: data) {
                let targetSize = NSSize(width: 50, height: 50)

                // Pre-render resized image (must run on main thread)
                // Note: NSImage Sendable conformance requires macOS 14+, but we ensure thread safety via DispatchQueue.main
                resizedImage = await withCheckedContinuation { continuation in
                    DispatchQueue.main.async {
                        let resized = NSImage(size: targetSize, flipped: false) { rect in
                            img.draw(in: rect,
                                    from: NSRect(origin: .zero, size: img.size),
                                    operation: .copy,
                                    fraction: 1.0)
                            return true
                        }
                        continuation.resume(returning: resized)
                    }
                }
            }

            return UserProfile(firstName: firstName, image: resizedImage)
        } catch {
            printOS("Failed fetching user profile: \(error)")
            return UserProfile(firstName: nil, image: nil)
        }
    }.value
}

// Check if file/folder name has localized variant
func showLocalized(url: URL) -> String {
    guard FileManager.default.fileExists(atPath: url.path) else {
        return url.lastPathComponent
    }
    do {
        // Retrieve the localized name
        let resourceValues = try url.resourceValues(forKeys: [.localizedNameKey])
        if let localizedName = resourceValues.localizedName {
            return localizedName
        }
    } catch {
        printOS("Error retrieving localized name: \(error)")
    }
    // Return the last path component as a fallback
    return url.lastPathComponent
}

extension URL {
    func localizedName() -> String {
        do {
            let resourceValues = try self.resourceValues(forKeys: [.localizedNameKey])
            return resourceValues.localizedName?.replacingOccurrences(of: ".app", with: "") ?? self.lastPathComponent.replacingOccurrences(of: ".app", with: "")
        } catch {
            printOS("Error getting localized name: \(error)")
            return self.lastPathComponent.replacingOccurrences(of: ".app", with: "")
        }
    }
}

extension String {
    func localizedName() -> String {
        let url = URL(fileURLWithPath: self)
        do {
            let resourceValues = try url.resourceValues(forKeys: [.localizedNameKey])
            return resourceValues.localizedName?.replacingOccurrences(of: ".app", with: "") ?? self
        } catch {
            printOS("Error getting localized name: \(error)")
            return self
        }
    }
}

extension String {
    func pathWithArrows(separatorColor: Color = .secondary, separatorFont: Font = .caption) -> some View {
        let components = self.dropFirst().components(separatedBy: "/").filter { !$0.isEmpty }

        return HStack(spacing: 4) {
            ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                Group {
                    Text(component)

                    if index < components.count - 1 {
                        Image(systemName: "chevron.right")
                            .font(separatorFont)
                            .foregroundStyle(separatorColor)
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
            }
        }
    }
}

extension URL {
    /// Returns the bundle name of the container by its UUID if found.
    func containerNameByUUID() -> String {
        // Extract the last path component, which should be the UUID
        let uuid = self.lastPathComponent

        // Ensure the UUID matches the expected pattern.
        let uuidRegex = try! NSRegularExpression(
            pattern: "^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$",
            options: .caseInsensitive
        )
        let range = NSRange(location: 0, length: uuid.utf16.count)
        guard uuidRegex.firstMatch(in: uuid, options: [], range: range) != nil else {
            //            printOS("The URL does not point to a valid UUID container.")
            return ""
        }

        // Path to the Containers directory.
        let containersPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers")

        do {
            // List all directories in the Containers folder.
            let containerDirectories = try FileManager.default.contentsOfDirectory(
                at: containersPath,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            )

            // Iterate over each directory to find a match with the UUID.
            for directory in containerDirectories {
                let directoryName = directory.lastPathComponent

                if directoryName == uuid {
                    // Attempt to read the metadata plist file.
                    let metadataPlistURL = directory.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")

                    if let metadataDict = NSDictionary(contentsOf: metadataPlistURL),
                       let applicationBundleID = metadataDict["MCMMetadataIdentifier"] as? String {
                        return applicationBundleID
                    }
                }
            }
        } catch {
            printOS("Error accessing the Containers directory: \(error)")
        }

        // Return nil if no matching UUID is found.
        return ""
    }
}

// Removes the sidebar toggle button from the toolbar, if running on macOS 14.0 or newer.
extension View {
    @ViewBuilder
    func removeSidebarToggle() -> some View {
        if #available(macOS 14.0, *) {
            self.toolbar(removing: .sidebarToggle)
        } else {
            self
        }
    }
}

// Drag window by background
extension View {
    // Helper function to apply the movable background window
    func movableByWindowBackground() -> some View {
        self.background(MovableWindowAccessor())
    }
}

// Custom NSWindow accessor to modify window properties
struct MovableWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let nsView = NSView()

        DispatchQueue.main.async {
            if let window = nsView.window {
                // Enable dragging by the window's background
                window.isMovableByWindowBackground = true
            }
        }

        return nsView
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}


// Return image for different folders
func folderImages(for path: String) -> AnyView? {
    @Environment(\.colorScheme) var colorScheme

    if path.contains("/Library/Containers/") || path.contains("/Library/Group Containers/") {
        return AnyView(
            Image(systemName: "shippingbox.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 13)
                .foregroundStyle(ThemeColors.shared(for: colorScheme).primaryText.opacity(0.5))
                .help("Container")
        )
    } else if path.contains("/Library/Application Scripts/") {
        return AnyView(
            Image(systemName: "applescript.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 13)
                .foregroundStyle(ThemeColors.shared(for: colorScheme).primaryText.opacity(0.5))
                .help("Application Script")
        )
    } else if path.contains(".plist") {
        return AnyView(
            Image(systemName: "doc.badge.gearshape.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 13)
                .foregroundStyle(ThemeColors.shared(for: colorScheme).primaryText.opacity(0.5))
                .help("Plist File")
        )
    }

    // Return nil if no conditions are met
    return nil
}


// Check if app bundle is nested
func isNested(path: URL) -> Bool {
    let applicationsPath = "/Applications"
    let homeApplicationsPath = "\(home)/Applications"

    guard path.path.contains("Applications") else {
        return false
    }

    // Get the parent directory of the app
    let parentDirectory = path.deletingLastPathComponent().path

    // Check if the parent directory is not directly /Applications or ~/Applications
    return parentDirectory != applicationsPath && parentDirectory != homeApplicationsPath
}


// Date formatter for metadata
func formattedMDDate(from date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .long
    formatter.timeZone = .current // Use the current timezone
    return formatter.string(from: date)
}



// --- Extend String to remove periods, spaces and lowercase the string
extension String {
    func pearFormat() -> String {
        // Optimized version: directly build result string without intermediate array
        var result = ""
        result.reserveCapacity(self.count) // Pre-allocate to avoid reallocation

        // Iterate unicode scalars and append alphanumerics directly
        for scalar in self.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
            }
        }

        // Lowercase the result
        result = result.lowercased()

        // If the result is empty after processing, return the original string
        // to avoid false matches with empty string comparisons
        return result.isEmpty ? self : result
    }
}


// --- Returns comma separated string as array of strings
extension String {
    func toConditionFormat() -> [String] {
        if self.isEmpty {
            return []
        }
        return self.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

func sendStartNotificationFW() {
    UserDefaults.sentinelWatcherPaused = false
}

func sendStopNotificationFW() {
    UserDefaults.sentinelWatcherPaused = true
}

func formatRelativeTime(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}

/// Generate system and Pearcleaner environment information string for debugging
func getSystemDebugString() -> String {
    let processInfo = ProcessInfo.processInfo
    let osVersion = processInfo.operatingSystemVersionString
    let osVersionParts = processInfo.operatingSystemVersion
    let pcVersion = Bundle.main.version
    let pcBuild = Bundle.main.buildVersion
    let pcBundleID = Bundle.main.bundleIdentifier ?? "unknown"

    // Architecture info
    #if arch(arm64)
    let archRunning = "arm64 (Apple Silicon)"
    #elseif arch(x86_64)
    let archRunning = "x86_64 (Intel)"
    #else
    let archRunning = "unknown"
    #endif

    // Memory info
    let physicalMemory = processInfo.physicalMemory
    let memoryFormatted = formatBytes(Int64(physicalMemory))

    // Processor info
    let processorCount = processInfo.processorCount
    let activeProcessorCount = processInfo.activeProcessorCount

    // System uptime
    let uptime = processInfo.systemUptime
    let uptimeFormatted = formatTimeInterval(uptime)

    // Pearcleaner memory usage
    var taskInfo = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
    let result = withUnsafeMutablePointer(to: &taskInfo) {
        $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    let memoryUsage = result == KERN_SUCCESS ? formatBytes(Int64(taskInfo.resident_size)) : "unknown"

    // Full Disk Access status
    let hasFullDiskAccess = FileManager.default.isReadableFile(atPath: "/Library/Application Support/com.apple.TCC/TCC.db")

    return """

    ====================================
    System & Pearcleaner Debug Info
    ====================================
    Pearcleaner Version: \(pcVersion) (Build \(pcBuild))
    Bundle ID: \(pcBundleID)
    Running Architecture: \(archRunning)
    Memory Usage: \(memoryUsage)
    ====================================
    macOS Version: \(osVersion)
    macOS Build: \(osVersionParts.majorVersion).\(osVersionParts.minorVersion).\(osVersionParts.patchVersion)
    ====================================
    System Memory: \(memoryFormatted)
    Processor Cores: \(processorCount) total, \(activeProcessorCount) active
    System Uptime: \(uptimeFormatted)
    ====================================
    Full Disk Access: \(hasFullDiskAccess ? "✓ Granted" : "✗ Not Granted")
    ====================================
    Timestamp: \(Date().description)
    ====================================
    """
}

/// Format time interval into human-readable string
private func formatTimeInterval(_ interval: TimeInterval) -> String {
    let days = Int(interval) / 86400
    let hours = (Int(interval) % 86400) / 3600
    let minutes = (Int(interval) % 3600) / 60

    if days > 0 {
        return "\(days)d \(hours)h \(minutes)m"
    } else if hours > 0 {
        return "\(hours)h \(minutes)m"
    } else {
        return "\(minutes)m"
    }
}

/// Format bytes into human-readable string
func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useAll]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}

// MARK: - Unified Privileged Command Execution
/// Executes privileged commands through a preflighted helper when available.
/// Authorization Services is used only before the real command has been
/// dispatched, so an ambiguous XPC reply can never trigger a duplicate retry.
func runSUOperation(
    name: String,
    arguments: [String] = [],
    errorContext: String? = nil,
    skipHelperCheck: Bool = false,
    throwOnFailure: Bool = false
) async throws -> (success: Bool, output: String) {
    let invocation: PrivilegedProcessInvocation
    switch PrivilegedOperationPolicy.invocation(name: name, arguments: arguments) {
    case .success(let validated):
        invocation = validated
    case .failure(let error):
        let message = "Rejected privileged operation: \(error)"
        if let context = errorContext {
            printOS("\(context): \(message)")
        }
        if throwOnFailure {
            throw NSError(
                domain: "SU Command",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        return (false, message)
    }

    if skipHelperCheck {
        return await HelperToolManager.shared.runOperation(
            name,
            arguments: arguments,
            skipHelperCheck: true
        )
    }

    if HelperToolManager.shared.isHelperToolInstalled {
        let readiness = await HelperToolManager.shared.runOperation("probe")
        if readiness.0 {
            let result = await HelperToolManager.shared.runOperation(name, arguments: arguments)
            if result.0 {
                return result
            }

            if let context = errorContext {
                printOS("\(context): \(result.1)")
            }
            if throwOnFailure {
                throw NSError(
                    domain: "SU Command",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: result.1]
                )
            }
            return result
        }

        if let context = errorContext {
            printOS("\(context): Helper unavailable before dispatch: \(readiness.1)")
        }
    }

    let (success, output) = performPrivilegedCommands(commands: invocation.shellCommand)

    // Log custom error if provided and command failed
    if !success, let context = errorContext {
        printOS("\(context): \(output)")
    }

    // Throw error if requested
    if throwOnFailure && !success {
        throw NSError(domain: "SU Command", code: 1, userInfo: [NSLocalizedDescriptionKey: output])
    }

    return (success, output)
}
