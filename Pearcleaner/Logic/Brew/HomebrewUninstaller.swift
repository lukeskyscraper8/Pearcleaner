//
//  HomebrewUninstaller.swift
//  Pearcleaner
//
//  Created by Pearcleaner on 2025-10-03.
//

import Foundation
import AlinFoundation
import ServiceManagement

class HomebrewUninstaller {
    static let shared = HomebrewUninstaller()
    private var brewPrefix: String {
        HomebrewController.shared.brewPrefix
    }
    private let useBrewUninstallZap = true  // Set to true to use brew command, false for manual method

    private init() {}

    // MARK: - Main Entry Point

    /// Uninstalls a Homebrew package directly without calling brew uninstall
    /// This replicates Homebrew's uninstall behavior using privileged helper for root operations
    func uninstallPackage(name: String, cask: Bool, zap: Bool = true) async throws {
        UpdaterDebugLogger.shared.log(.homebrew, "🗑️ Starting uninstall for \(name) (type: \(cask ? "cask" : "formula"), zap: \(zap))")

        do {
            if useBrewUninstallZap {
                // Use native brew uninstall command
                try await uninstallViaBrewCommand(name: name, cask: cask)
            } else {
                // Use manual uninstall method
                if cask {
                    // Try loading from INSTALL_RECEIPT.json first (instant)
                    let caskInfo: [String: Any]
                    do {
                        caskInfo = try loadCaskInfoFromReceipt(name: name)
                        UpdaterDebugLogger.shared.log(.homebrew, "  Loaded cask info from INSTALL_RECEIPT.json")
                    } catch {
                        // Fallback to brew info command (slower but works if receipt missing)
                        UpdaterDebugLogger.shared.log(.homebrew, "  INSTALL_RECEIPT.json not found, falling back to brew info")
                        let arguments = ["info", "--json=v2", name]
                        let result = try await HomebrewController.shared.runBrewCommand(arguments)

                        guard let jsonData = result.output.data(using: String.Encoding.utf8) else {
                            throw HomebrewError.jsonParseError
                        }

                        guard let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                              let casks = json["casks"] as? [[String: Any]],
                              let info = casks.first else {
                            throw HomebrewError.commandFailed("Cask \(name) not found")
                        }
                        caskInfo = info
                    }
                    try await uninstallCask(name: name, info: caskInfo, zap: zap)
                } else {
                    // Formulae don't need info JSON - brew uninstall handles everything
                    try await uninstallFormula(name: name, info: [:])
                }
            }

            UpdaterDebugLogger.shared.log(.homebrew, "✓ Uninstalled \(name) successfully")

            // Run brew cleanup synchronously (FilesView manages the progress indicator)
            UpdaterDebugLogger.shared.log(.homebrew, "  Running cleanup...")
            _ = try? await HomebrewController.shared.runCleanup()
        } catch {
            UpdaterDebugLogger.shared.log(.homebrew, "❌ Uninstall failed for \(name): \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Brew Command Method

    /// Uninstalls a package using native brew uninstall command
    private func uninstallViaBrewCommand(name: String, cask: Bool) async throws {
        var arguments = ["uninstall"]

        // Add package type flag
        if cask {
            arguments.append("--cask")
            arguments.append("--zap")
        } else {
            arguments.append("--formula")
        }

        // Force uninstall
        arguments.append("--force")

        // Add package name
        arguments.append(name)

        UpdaterDebugLogger.shared.log(.homebrew, "  Running: brew \(arguments.joined(separator: " "))")

        // Run command
        let result = try await HomebrewController.shared.runBrewCommand(arguments)

        // Print full stdout and stderr
//        if !result.output.isEmpty {
//            printOS("📤 STDOUT:\n\(result.output)")
//        }
        if !result.error.isEmpty {
            printOS("📤 Homebrew Uninstall Error:\n\(result.error)")
        }

        // Check for errors
        if !result.error.isEmpty && result.error.contains("Error") {
            // Parse specific errors
            if let depError = parseDependencyConflict(from: result.error, package: name) {
                throw depError
            }

            // Fallback to generic error
            throw HomebrewError.commandFailed(result.error)
        }
    }

    // MARK: - INSTALL_RECEIPT Helper

    /// Load cask info from INSTALL_RECEIPT.json (instant, no brew command needed)
    /// Converts receipt format to brew info format for compatibility with uninstallCask()
    private func loadCaskInfoFromReceipt(name: String) throws -> [String: Any] {
        let receiptPath = "\(brewPrefix)/Caskroom/\(name)/.metadata/INSTALL_RECEIPT.json"

        guard FileManager.default.fileExists(atPath: receiptPath) else {
            throw HomebrewError.commandFailed("INSTALL_RECEIPT.json not found for \(name)")
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: receiptPath))
        guard let receipt = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HomebrewError.jsonParseError
        }

        // Convert INSTALL_RECEIPT format to brew info format
        var caskInfo: [String: Any] = [:]
        caskInfo["token"] = name
        caskInfo["artifacts"] = receipt["uninstall_artifacts"]

        return caskInfo
    }

    // MARK: - Cask Uninstall

    private func uninstallCask(name: String, info: [String: Any], zap: Bool) async throws {
        let token = info["token"] as? String ?? name
        var filesToDelete: [URL] = []

        // Collect all process names and services to kill
        var processNamesToKill: Set<String> = []
        var serviceNamesToKill: Set<String> = []
        var appName: String?

        // Process artifacts (includes uninstall directives and app info)
        if let artifacts = info["artifacts"] as? [[String: Any]] {
            // Collect app name for process killing
            for artifact in artifacts {
                if let appArray = artifact["app"] as? [String], let app = appArray.first {
                    appName = app.replacingOccurrences(of: ".app", with: "")
                    processNamesToKill.insert(appName!)
                }
            }

            // Collect quit and launchctl names from uninstall directives
            for artifact in artifacts {
                if let uninstallDirectives = artifact["uninstall"] as? [[String: Any]] {
                    for directive in uninstallDirectives {
                        if let quit = directive["quit"] as? String {
                            processNamesToKill.insert(quit)
                        }
                        if let launchctl = directive["launchctl"] as? String {
                            serviceNamesToKill.insert(launchctl)
                        }
                    }
                }
            }

            // First pass: Process service/script directives and collect file paths
            for artifact in artifacts {
                if let uninstallDirectives = artifact["uninstall"] as? [[String: Any]], !uninstallDirectives.isEmpty {
                    let files = try await processCaskUninstallDirectives(uninstallDirectives, caskName: token, allProcessNames: processNamesToKill, allServiceNames: serviceNamesToKill)
                    filesToDelete.append(contentsOf: files)
                }
            }

            // Process zap directives if requested
            if zap {
                for artifact in artifacts {
                    if let zapDirectives = artifact["zap"] as? [[String: Any]], !zapDirectives.isEmpty {
                        let files = try await processCaskUninstallDirectives(zapDirectives, caskName: token, allProcessNames: processNamesToKill, allServiceNames: serviceNamesToKill)
                        filesToDelete.append(contentsOf: files)
                    }
                }
            }

            // Kill any remaining processes (belt and suspenders approach)
            for processName in processNamesToKill {
                _ = try? await runPrivilegedOperation(name: "pkill", arguments: ["-9", "-f", processName])
                _ = try? await runPrivilegedOperation(name: "killall", arguments: ["-9", processName])
            }

            // Collect app paths
            for artifact in artifacts {
                if let appArray = artifact["app"] as? [String], let appFullName = appArray.first {
                    let systemAppPath = "/Applications/\(appFullName)"
                    let userAppPath = NSHomeDirectory() + "/Applications/\(appFullName)"

                    if FileManager.default.fileExists(atPath: systemAppPath) {
                        filesToDelete.append(URL(fileURLWithPath: systemAppPath))
                    } else if FileManager.default.fileExists(atPath: userAppPath) {
                        filesToDelete.append(URL(fileURLWithPath: userAppPath))
                    }
                }
            }
        }

        // Collect Caskroom directory
        let caskroomPath = "\(brewPrefix)/Caskroom/\(token)"
        if FileManager.default.fileExists(atPath: caskroomPath) {
            filesToDelete.append(URL(fileURLWithPath: caskroomPath))
        }

        // Delete all collected files in one batch with cask name
        if !filesToDelete.isEmpty {
            let bundleName = "\(token) (Homebrew Cask)"
            try trashFilesOrThrow(
                filesToDelete,
                bundleName: bundleName,
                operation: "Uninstalling \(token)"
            )
        }
    }

    private func processCaskUninstallDirectives(_ directives: [[String: Any]], caskName: String, allProcessNames: Set<String>, allServiceNames: Set<String>) async throws -> [URL] {
        // Process directives in the order Homebrew processes them
        // Based on abstract_uninstall.rb from Homebrew source

        var filesToDelete: [URL] = []

        for directive in directives {
            if let earlyScript = directive["early_script"] as? [String: Any] {
                try await handleEarlyScript(earlyScript)
            }
        }

        for directive in directives {
            if let launchctl = directive["launchctl"] as? String {
                try await handleLaunchctl(launchctl)
            }
        }

        for directive in directives {
            if let quit = directive["quit"] as? String {
                try await handleQuit(quit)
            }
        }

        for directive in directives {
            if let signal = directive["signal"] as? [Any] {
                try await handleSignal(signal)
            }
        }

        for directive in directives {
            if let loginItem = directive["login_item"] as? String {
                try await handleLoginItem(loginItem)
            }
        }

        for directive in directives {
            if let kext = directive["kext"] as? String {
                try await handleKext(kext)
            }
        }

        for directive in directives {
            if let script = directive["script"] as? [String: Any] {
                try await handleScript(script)
            }
        }

        for directive in directives {
            if let pkgutil = directive["pkgutil"] as? String {
                try await handlePkgutil(pkgutil)
            }
        }

        for directive in directives {
            if let deleteArray = directive["delete"] as? [String] {
                for path in deleteArray {
                    let expandedPath = expandPath(path)
                    if FileManager.default.fileExists(atPath: expandedPath) {
                        filesToDelete.append(URL(fileURLWithPath: expandedPath))
                    }
                }
            } else if let deleteString = directive["delete"] as? String {
                let expandedPath = expandPath(deleteString)
                if FileManager.default.fileExists(atPath: expandedPath) {
                    filesToDelete.append(URL(fileURLWithPath: expandedPath))
                }
            }
        }

        for directive in directives {
            if let trashArray = directive["trash"] as? [String] {
                for path in trashArray {
                    let expandedPath = expandPath(path)
                    if FileManager.default.fileExists(atPath: expandedPath) {
                        filesToDelete.append(URL(fileURLWithPath: expandedPath))
                    }
                }
            } else if let trashString = directive["trash"] as? String {
                let expandedPath = expandPath(trashString)
                if FileManager.default.fileExists(atPath: expandedPath) {
                    filesToDelete.append(URL(fileURLWithPath: expandedPath))
                }
            }
        }

        for directive in directives {
            if let rmdirArray = directive["rmdir"] as? [String] {
                for path in rmdirArray {
                    let expandedPath = expandPath(path)
                    if FileManager.default.fileExists(atPath: expandedPath) {
                        filesToDelete.append(URL(fileURLWithPath: expandedPath))
                    }
                }
            } else if let rmdirString = directive["rmdir"] as? String {
                let expandedPath = expandPath(rmdirString)
                if FileManager.default.fileExists(atPath: expandedPath) {
                    filesToDelete.append(URL(fileURLWithPath: expandedPath))
                }
            }
        }

        return filesToDelete
    }

    // MARK: - Formula Uninstall

    private func uninstallFormula(name: String, info: [String: Any]) async throws {
        // Try using brew uninstall command first (proper uninstall with symlink cleanup)
        let arguments = ["uninstall", name, "--force"]

        do {
            let result = try await HomebrewController.shared.runBrewCommand(arguments)

            // Check if brew command failed due to permission error
            if result.error.contains("Could not remove") && result.error.contains("keg") {
                // Permission error - fallback to collecting paths for batch deletion
                var pathsToDelete: [URL] = []
                let cellarPath = "\(brewPrefix)/Cellar/\(name)"
                if FileManager.default.fileExists(atPath: cellarPath) {
                    pathsToDelete.append(URL(fileURLWithPath: cellarPath))

                    // Also collect symlink paths
                    let optPath = "\(brewPrefix)/opt/\(name)"
                    if FileManager.default.fileExists(atPath: optPath) {
                        pathsToDelete.append(URL(fileURLWithPath: optPath))
                    }
                    let linkedPath = "\(brewPrefix)/var/homebrew/linked/\(name)"
                    if FileManager.default.fileExists(atPath: linkedPath) {
                        pathsToDelete.append(URL(fileURLWithPath: linkedPath))
                    }

                    // Batch delete collected paths
                    if !pathsToDelete.isEmpty {
                        try trashFilesOrThrow(
                            pathsToDelete,
                            bundleName: "Homebrew-\(name)",
                            operation: "Removing formula \(name)"
                        )
                    }
                }
            } else if !result.error.isEmpty && !result.error.contains("Warning") {
                // Other error - throw it
                throw HomebrewError.commandFailed(result.error)
            }
            // Success - brew uninstall handled everything
        } catch {
            // Fallback: If brew command itself fails, collect paths for batch deletion
            var pathsToDelete: [URL] = []
            let cellarPath = "\(brewPrefix)/Cellar/\(name)"
            if FileManager.default.fileExists(atPath: cellarPath) {
                pathsToDelete.append(URL(fileURLWithPath: cellarPath))

                // Collect symlinks
                let optPath = "\(brewPrefix)/opt/\(name)"
                if FileManager.default.fileExists(atPath: optPath) {
                    pathsToDelete.append(URL(fileURLWithPath: optPath))
                }
                let linkedPath = "\(brewPrefix)/var/homebrew/linked/\(name)"
                if FileManager.default.fileExists(atPath: linkedPath) {
                    pathsToDelete.append(URL(fileURLWithPath: linkedPath))
                }

                // Batch delete collected paths
                if !pathsToDelete.isEmpty {
                    try trashFilesOrThrow(
                        pathsToDelete,
                        bundleName: "Homebrew-\(name)",
                        operation: "Removing formula \(name)"
                    )
                } else {
                    throw HomebrewError.commandFailed("Formula \(name) is not installed")
                }
            } else {
                throw HomebrewError.commandFailed("Formula \(name) is not installed")
            }
        }
    }

    // MARK: - Uninstall Directive Handlers

    private func handleEarlyScript(_ value: [String: Any]) async throws {
        throw HomebrewError.commandFailed(
            "Cask early_script directives are not executed through Pearcleaner's privileged helper."
        )
    }

    private func handleLaunchctl(_ value: String) async throws {
        // Try both system and user domains
        let systemPlistPath = "/Library/LaunchDaemons/\(value).plist"
        let userPlistPath = NSHomeDirectory() + "/Library/LaunchAgents/\(value).plist"
        let uid = getuid()

        // Unload the service and kill the process
        do {
            // Try bootout first (modern launchctl)
            _ = try? await runPrivilegedOperation(name: "launchctl", arguments: ["bootout", "system/\(value)"])
            if FileManager.default.fileExists(atPath: systemPlistPath) {
                _ = try? await runPrivilegedOperation(name: "launchctl", arguments: ["unload", systemPlistPath])
            }
            _ = try? await runPrivilegedOperation(name: "pkill", arguments: ["-9", "-f", value])
        } catch {
            printOS("Failed to unload system service: \(error.localizedDescription)")
        }

        do {
            _ = try? await runPrivilegedOperation(name: "launchctl", arguments: ["bootout", "gui/\(uid)/\(value)"])
            if FileManager.default.fileExists(atPath: userPlistPath) {
                _ = try? await runPrivilegedOperation(name: "launchctl", arguments: ["unload", userPlistPath])
            }
            _ = try? await runPrivilegedOperation(name: "pkill", arguments: ["-9", "-f", value])
        } catch {
            printOS("Failed to unload user service: \(error.localizedDescription)")
        }

        // Delete the plist files using trash
        var plistPaths: [URL] = []
        if FileManager.default.fileExists(atPath: systemPlistPath) {
            plistPaths.append(URL(fileURLWithPath: systemPlistPath))
        }
        if FileManager.default.fileExists(atPath: userPlistPath) {
            plistPaths.append(URL(fileURLWithPath: userPlistPath))
        }
        if !plistPaths.isEmpty {
            try trashFilesOrThrow(
                plistPaths,
                bundleName: "Homebrew-LaunchAgent",
                operation: "Removing launch service \(value)"
            )
        }
    }

    private func handleQuit(_ value: String) async throws {
        // First try using the bundle ID with killall (works with bundle IDs)
        do {
            _ = try await runPrivilegedOperation(name: "killall", arguments: ["-15", value])
        } catch {
            printOS("killall failed for \(value): \(error.localizedDescription)")
        }

        do {
            _ = try await runPrivilegedOperation(name: "pkill", arguments: ["-15", "-f", value])
        } catch {
            printOS("pkill failed for \(value): \(error.localizedDescription)")
        }
    }

    private func handleSignal(_ value: [Any]) async throws {
        guard value.count >= 2,
              let signal = value[0] as? String,
              let process = value[1] as? String else { return }

        guard signal.range(of: #"^[A-Za-z0-9]+$"#, options: .regularExpression) != nil else {
            throw NSError(domain: "HomebrewUninstaller", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid signal name"])
        }

        try await runPrivilegedOperation(name: "pkill", arguments: ["-\(signal)", process])
    }

    private func handleLoginItem(_ value: String) async throws {
        // Unregister using SMAppService
        let service = SMAppService.loginItem(identifier: value)

        do {
            try await service.unregister()
        } catch {
            printOS("SMAppService unregister failed for \(value): \(error.localizedDescription)")
        }
    }

    private func handleKext(_ value: String) async throws {
        try await runPrivilegedOperation(name: "kextunload", arguments: [value])
    }

    private func handleScript(_ value: [String: Any]) async throws {
        throw HomebrewError.commandFailed(
            "Cask script directives are not executed through Pearcleaner's privileged helper."
        )
    }

    private func handlePkgutil(_ value: String) async throws {
        // Get list of files from pkgutil
        let filesResult = (try? await runPrivilegedOperation(name: "pkgutil-files", arguments: [value])) ?? ""
        let files = filesResult.components(separatedBy: "\n").filter { !$0.isEmpty }

        // Collect files for batch deletion (they're relative to /)
        var pathsToDelete: [URL] = []
        for file in files {
            let fullPath = "/\(file)"
            if FileManager.default.fileExists(atPath: fullPath) {
                pathsToDelete.append(URL(fileURLWithPath: fullPath))
            }
        }

        // Batch delete collected paths
        if !pathsToDelete.isEmpty {
            try trashFilesOrThrow(
                pathsToDelete,
                bundleName: "Homebrew-PKG-\(value)",
                operation: "Removing package receipt files for \(value)"
            )
        }

        // Forget the package
        try await runPrivilegedOperation(name: "pkgutil-forget", arguments: [value])
    }

    private func handleDelete(_ path: String) async throws {
        let expandedPath = expandPath(path)

        if FileManager.default.fileExists(atPath: expandedPath) {
            // Use trash for all deletions
            try trashFilesOrThrow(
                [URL(fileURLWithPath: expandedPath)],
                bundleName: "Homebrew-Delete",
                operation: "Removing \(expandedPath)"
            )
        }
    }

    private func handleTrash(_ path: String) async throws {
        let expandedPath = expandPath(path)

        if FileManager.default.fileExists(atPath: expandedPath) {
            // Use FileManagerUndo to properly move to trash
            try trashFilesOrThrow(
                [URL(fileURLWithPath: expandedPath)],
                bundleName: "Homebrew-Trash",
                operation: "Trashing \(expandedPath)"
            )
        }
    }

    private func handleRmdir(_ path: String) async throws {
        let expandedPath = expandPath(path)

        if FileManager.default.fileExists(atPath: expandedPath) {
            // Only remove if empty
            let contents = try FileManager.default.contentsOfDirectory(atPath: expandedPath)
            if contents.isEmpty {
                // Use trash even for empty directories
                try trashFilesOrThrow(
                    [URL(fileURLWithPath: expandedPath)],
                    bundleName: "Homebrew-Rmdir",
                    operation: "Removing empty directory \(expandedPath)"
                )
            }
        }
    }

    // MARK: - Helper Methods

    private func trashFilesOrThrow(
        _ urls: [URL],
        bundleName: String,
        operation: String
    ) throws {
        let result = FileManagerUndo.shared.deleteFilesWithResult(
            at: urls,
            bundleName: bundleName
        )
        guard result.allSucceeded else {
            if !result.protectedURLs.isEmpty {
                throw HomebrewError.commandFailed(
                    "\(operation) was not completed. Protected paths cannot be moved to Trash through Pearcleaner's privileged helper; remove them manually or use Homebrew directly."
                )
            }

            throw HomebrewError.commandFailed(
                "\(operation) was only partially completed: \(result.movedURLs.count) of \(result.requestedURLs.count) item(s) were moved to Trash."
            )
        }
    }

    private func expandPath(_ path: String) -> String {
        if path.hasPrefix("~") {
            return NSString(string: path).expandingTildeInPath
        }
        return path
    }

    @discardableResult
    private func runPrivilegedOperation(name: String, arguments: [String]) async throws -> String {
        let result = try await runSUOperation(
            name: name,
            arguments: arguments,
            errorContext: "Homebrew uninstall operation failed",
            throwOnFailure: true
        )

        return result.1
    }
}
