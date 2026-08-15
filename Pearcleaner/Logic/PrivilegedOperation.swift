//
//  PrivilegedOperation.swift
//  Pearcleaner
//
//  Added for the independently maintained Pearcleaner fork.
//

import Foundation

enum HelperIdentity {
    static let clientRequirement = #"identifier "com.lukerow.Pearcleaner" and anchor apple generic and certificate leaf[subject.OU] = "68583N3MNF""#
    static let helperRequirement = #"identifier "com.lukerow.Pearcleaner.PearcleanerHelper" and anchor apple generic and certificate leaf[subject.OU] = "68583N3MNF""#
}

enum PrivilegedOperationError: Error, Equatable {
    case unknownOperation
    case invalidArguments
    case rejectedPath
}

struct PrivilegedProcessInvocation: Equatable {
    let executable: String
    let arguments: [String]

    var shellCommand: String {
        ([executable] + arguments).map(\.privilegedShellQuoted).joined(separator: " ")
    }
}

enum PrivilegedOperationPolicy {
    static func invocation(
        name: String,
        arguments: [String]
    ) -> Result<PrivilegedProcessInvocation, PrivilegedOperationError> {
        switch name {
        case "probe":
            return requireNoArguments(arguments, executable: "/usr/bin/true")
        case "whoami":
            return requireNoArguments(arguments, executable: "/usr/bin/whoami")
        case "create-cli-symlink":
            return createCLISymlink(arguments)
        case "remove-cli-symlink":
            return removeCLISymlink(arguments)
        case "launchctl":
            return launchctl(arguments)
        case "pkill":
            return pkill(arguments)
        case "killall":
            return killall(arguments)
        case "kextunload":
            return kextunload(arguments)
        case "pkgutil-files":
            return pkgutil(arguments, flag: "--files")
        case "pkgutil-forget":
            return pkgutil(arguments, flag: "--forget")
        default:
            return .failure(.unknownOperation)
        }
    }

    private static func requireNoArguments(
        _ arguments: [String],
        executable: String
    ) -> Result<PrivilegedProcessInvocation, PrivilegedOperationError> {
        guard arguments.isEmpty else { return .failure(.invalidArguments) }
        return .success(PrivilegedProcessInvocation(executable: executable, arguments: []))
    }

    private static func createCLISymlink(
        _ arguments: [String]
    ) -> Result<PrivilegedProcessInvocation, PrivilegedOperationError> {
        guard arguments.count == 2 || arguments.count == 3 else {
            return .failure(.invalidArguments)
        }
        let source = arguments[0]
        let name = arguments[1]
        let shouldCreateDirectory = arguments.count == 3
        guard ["pear", "pearcleaner"].contains(name) else {
            return .failure(.invalidArguments)
        }
        guard isAcceptableCLIExecutable(source) else {
            return .failure(.rejectedPath)
        }
        if shouldCreateDirectory {
            guard arguments[2] == "mkdir" else { return .failure(.invalidArguments) }
            let script = "/bin/mkdir /usr/local/bin && /bin/ln -s \(source.privilegedShellQuoted) \("/usr/local/bin/\(name)".privilegedShellQuoted)"
            return .success(
                PrivilegedProcessInvocation(executable: "/bin/sh", arguments: ["-c", script])
            )
        }
        return .success(
            PrivilegedProcessInvocation(
                executable: "/bin/ln",
                arguments: ["-s", source, "/usr/local/bin/\(name)"]
            )
        )
    }

    private static func removeCLISymlink(
        _ arguments: [String]
    ) -> Result<PrivilegedProcessInvocation, PrivilegedOperationError> {
        guard arguments.count == 1, ["pear", "pearcleaner"].contains(arguments[0]) else {
            return .failure(.invalidArguments)
        }
        return .success(
            PrivilegedProcessInvocation(
                executable: "/bin/rm",
                arguments: ["-f", "--", "/usr/local/bin/\(arguments[0])"]
            )
        )
    }

    private static func launchctl(
        _ arguments: [String]
    ) -> Result<PrivilegedProcessInvocation, PrivilegedOperationError> {
        guard let subcommand = arguments.first else { return .failure(.invalidArguments) }
        switch subcommand {
        case "load", "unload":
            guard arguments.count == 2, isAcceptableLaunchPlist(arguments[1]) else {
                return arguments.count == 2 ? .failure(.rejectedPath) : .failure(.invalidArguments)
            }
            return .success(
                PrivilegedProcessInvocation(executable: "/bin/launchctl", arguments: arguments)
            )
        case "enable", "disable", "bootout":
            guard arguments.count == 2, isAcceptableLaunchTarget(arguments[1]) else {
                return .failure(.invalidArguments)
            }
            return .success(
                PrivilegedProcessInvocation(executable: "/bin/launchctl", arguments: arguments)
            )
        case "kickstart":
            let target: String
            if arguments.count == 2 {
                target = arguments[1]
            } else if arguments.count == 3, arguments[1] == "-k" {
                target = arguments[2]
            } else {
                return .failure(.invalidArguments)
            }
            guard isAcceptableLaunchTarget(target) else { return .failure(.invalidArguments) }
            return .success(
                PrivilegedProcessInvocation(executable: "/bin/launchctl", arguments: arguments)
            )
        case "remove":
            guard arguments.count == 2, isIdentifier(arguments[1]) else {
                return .failure(.invalidArguments)
            }
            return .success(
                PrivilegedProcessInvocation(executable: "/bin/launchctl", arguments: arguments)
            )
        default:
            return .failure(.invalidArguments)
        }
    }

    private static func pkill(
        _ arguments: [String]
    ) -> Result<PrivilegedProcessInvocation, PrivilegedOperationError> {
        guard let signal = arguments.first, isSignal(signal) else {
            return .failure(.invalidArguments)
        }
        if arguments.count == 2 {
            guard isProcessPattern(arguments[1]) else { return .failure(.invalidArguments) }
            return .success(
                PrivilegedProcessInvocation(executable: "/usr/bin/pkill", arguments: arguments)
            )
        }
        if arguments.count == 3, arguments[1] == "-f" {
            guard isProcessPattern(arguments[2]) else { return .failure(.invalidArguments) }
            return .success(
                PrivilegedProcessInvocation(executable: "/usr/bin/pkill", arguments: arguments)
            )
        }
        return .failure(.invalidArguments)
    }

    private static func killall(
        _ arguments: [String]
    ) -> Result<PrivilegedProcessInvocation, PrivilegedOperationError> {
        guard arguments.count == 2, isSignal(arguments[0]), isProcessPattern(arguments[1]) else {
            return .failure(.invalidArguments)
        }
        return .success(
            PrivilegedProcessInvocation(executable: "/usr/bin/killall", arguments: arguments)
        )
    }

    private static func kextunload(
        _ arguments: [String]
    ) -> Result<PrivilegedProcessInvocation, PrivilegedOperationError> {
        guard arguments.count == 1, isIdentifier(arguments[0]) else {
            return .failure(.invalidArguments)
        }
        return .success(
            PrivilegedProcessInvocation(
                executable: "/sbin/kextunload",
                arguments: ["-b", arguments[0]]
            )
        )
    }

    private static func pkgutil(
        _ arguments: [String],
        flag: String
    ) -> Result<PrivilegedProcessInvocation, PrivilegedOperationError> {
        guard arguments.count == 1, isIdentifier(arguments[0]) else {
            return .failure(.invalidArguments)
        }
        return .success(
            PrivilegedProcessInvocation(
                executable: "/usr/sbin/pkgutil",
                arguments: [flag, arguments[0]]
            )
        )
    }

    private static func isAcceptableCLIExecutable(_ path: String) -> Bool {
        guard isAbsoluteNormalized(path), path.contains(".app/Contents/MacOS/") else {
            return false
        }
        return !hasTemporaryPrefix(path)
    }

    private static func isAcceptableLaunchPlist(_ path: String) -> Bool {
        guard isAbsoluteNormalized(path), path.hasSuffix(".plist") else { return false }
        let allowedPrefixes = [
            "/Library/LaunchDaemons/",
            "/Library/LaunchAgents/",
            "/System/Library/LaunchDaemons/",
            "/System/Library/LaunchAgents/",
        ]
        if allowedPrefixes.contains(where: { path.hasPrefix($0) }) {
            return true
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/Library/LaunchAgents/")
    }

    private static func isAcceptableLaunchTarget(_ target: String) -> Bool {
        let parts = target.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 2, parts[0] == "system", isIdentifier(parts[1]) {
            return true
        }
        if parts.count == 3, parts[0] == "gui", parts[1].allSatisfy(\.isNumber), isIdentifier(parts[2]) {
            return true
        }
        return false
    }

    private static func isSignal(_ value: String) -> Bool {
        if value.hasPrefix("-"), value.dropFirst().allSatisfy(\.isNumber) {
            return true
        }
        return value.range(of: #"^[A-Za-z0-9]+$"#, options: .regularExpression) != nil
    }

    private static func isProcessPattern(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }

    private static func isIdentifier(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
    }

    private static func isAbsoluteNormalized(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0") else { return false }
        let url = URL(fileURLWithPath: path)
        return url.standardizedFileURL.path == path && !path.contains("/../") && !path.hasSuffix("/..")
    }

    private static func hasTemporaryPrefix(_ path: String) -> Bool {
        ["/tmp/", "/var/tmp/", "/private/tmp/", "/private/var/tmp/"].contains { path.hasPrefix($0) }
    }
}

enum ThinningPathPolicy {
    static func isAcceptable(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard path.hasPrefix("/"), url.standardizedFileURL.path == path else { return false }
        guard path.hasPrefix("/Applications/") || path == "/Applications" else { return false }
        return path.hasSuffix(".app") || path.contains(".app/Contents/")
    }
}

enum FolderPathPolicy {
    static func isAcceptableScanRoot(_ path: String) -> Bool {
        isAcceptableUserFolder(path, allowKeywords: false)
    }

    static func isAcceptableOrphanExclusion(_ path: String) -> Bool {
        isAcceptableUserFolder(path, allowKeywords: true)
    }

    static func sanitizedFolderList(_ paths: [String], allowKeywords: Bool) -> [String] {
        paths.filter { isAcceptableUserFolder($0, allowKeywords: allowKeywords) }
    }

    private static func isAcceptableUserFolder(_ path: String, allowKeywords: Bool) -> Bool {
        if path.isEmpty || path.contains("\0") || path.contains("..") {
            return false
        }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let rejected = ["/", "/System", "/System/Volumes/Data", "/usr", "/bin", "/sbin", "/private", "/var", "/opt"]
        if rejected.contains(standardized) || rejected.contains(path) {
            return false
        }
        if path.hasPrefix("/") {
            return !standardized.hasPrefix("/System/")
        }
        return allowKeywords && !path.contains("/")
    }
}

enum DeepLinkSafety {
    static func requiresConfirmation(host: String) -> Bool {
        ["appsPaths", "orphanedPaths", "uninstallApp"].contains(host)
    }
}

enum SettingsKeyAllowlist {
    static let all: Set<String> = [
        "settings.general.brew",
        "settings.general.oneshot",
        "settings.general.confirmAlert",
        "settings.general.cli",
        "settings.general.namesearchstrict",
        "settings.general.spotlight",
        "settings.general.searchSensitivity",
        "settings.general.deepLevelAlertShown",
        "settings.general.searchTextContent",
        "settings.general.selectedTab",
        "settings.general.selectedSort",
        "settings.general.selectedSortAppsList",
        "settings.general.glass",
        "settings.general.glassEffect",
        "settings.general.filesWarning",
        "settings.general.leftoverWarning",
        "settings.general.sidebarWidth",
        "settings.general.sidebarWidthGeneric",
        "settings.general.zombie.associations",
        "settings.interface.scrollIndicators",
        "settings.interface.animationEnabled",
        "settings.interface.fileListViewMode",
        "settings.interface.details",
        "settings.interface.multiSelect",
        "settings.interface.minimalist",
        "settings.interface.greetingEnabled",
        "settings.interface.badgeOverlaysEnabled",
        "settings.interface.startupView",
        "settings.interface.hiddenPages",
        "settings.interface.customDarkColors",
        "settings.interface.customLightColors",
        "settings.interface.zombieListViewMode",
        "settings.files.showSidebarOnLoad",
        "settings.sentinel.enable",
        "settings.updater.loadOnStartup",
        "settings.updater.debugLogging",
        "settings.updater.sources",
        "settings.updater.display",
        "settings.updater.hiddenAppsData",
        "settings.updater.ignoredAppsData",
        "settings.updater.collapsedCategories",
        "settings.brew.showOnlyInstalledOnRequest",
        "settings.brew.autoUpdateEnabled",
        "settings.brew.autoUpdatePreservedSchedules",
        "settings.lipo.pruneTranslations",
        "settings.lipo.filterMinSavings",
        "settings.lipo.showZeroPercentSavings",
        "settings.lipo.excludedApps",
        "settings.lipo.warning",
        "settings.tutorial.dragToExpandShown",
        "settings.folders.apps",
        "settings.folders.zombie",
        "settings.folders.appsExclusion",
    ]

    static let folderKeys: Set<String> = [
        "settings.folders.apps",
        "settings.folders.zombie",
        "settings.folders.appsExclusion",
    ]
}

private extension String {
    var privilegedShellQuoted: String {
        "'\(replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
