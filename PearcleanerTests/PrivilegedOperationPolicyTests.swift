//
//  PrivilegedOperationPolicyTests.swift
//  PearcleanerTests
//
//  Added for the independently maintained Pearcleaner fork.
//

import XCTest
@testable import Pearcleaner

final class PrivilegedOperationPolicyTests: XCTestCase {
    func testProbeAndWhoamiAcceptNoArguments() throws {
        let probe = try PrivilegedOperationPolicy.invocation(name: "probe", arguments: []).get()
        XCTAssertEqual(probe.executable, "/usr/bin/true")
        XCTAssertTrue(probe.arguments.isEmpty)

        let whoami = try PrivilegedOperationPolicy.invocation(name: "whoami", arguments: []).get()
        XCTAssertEqual(whoami.executable, "/usr/bin/whoami")
        XCTAssertTrue(whoami.arguments.isEmpty)
    }

    func testUnknownOperationAndUnexpectedArgumentsAreRejected() {
        XCTAssertEqual(
            PrivilegedOperationPolicy.invocation(name: "bash", arguments: ["-c", "whoami"]).error,
            .unknownOperation
        )
        XCTAssertEqual(
            PrivilegedOperationPolicy.invocation(name: "whoami", arguments: ["root"]).error,
            .invalidArguments
        )
        XCTAssertEqual(
            PrivilegedOperationPolicy.invocation(name: "probe", arguments: ["/bin/sh"]).error,
            .invalidArguments
        )
    }

    func testCLISymlinkOnlyAllowsManagedNamesAndAbsoluteTargets() throws {
        let create = try PrivilegedOperationPolicy.invocation(
            name: "create-cli-symlink",
            arguments: ["/Applications/Pearcleaner.app/Contents/MacOS/Pearcleaner", "pear"]
        ).get()
        XCTAssertEqual(create.executable, "/bin/ln")
        XCTAssertEqual(
            create.arguments,
            ["-s", "/Applications/Pearcleaner.app/Contents/MacOS/Pearcleaner", "/usr/local/bin/pear"]
        )

        let createWithDirectory = try PrivilegedOperationPolicy.invocation(
            name: "create-cli-symlink",
            arguments: ["/Applications/Pearcleaner.app/Contents/MacOS/Pearcleaner", "pear", "mkdir"]
        ).get()
        XCTAssertEqual(createWithDirectory.executable, "/bin/sh")
        XCTAssertEqual(createWithDirectory.arguments.first, "-c")

        let remove = try PrivilegedOperationPolicy.invocation(
            name: "remove-cli-symlink",
            arguments: ["pearcleaner"]
        ).get()
        XCTAssertEqual(remove.executable, "/bin/rm")
        XCTAssertEqual(remove.arguments, ["-f", "--", "/usr/local/bin/pearcleaner"])

        XCTAssertEqual(
            PrivilegedOperationPolicy.invocation(
                name: "create-cli-symlink",
                arguments: ["/tmp/evil", "pear"]
            ).error,
            .rejectedPath
        )
        XCTAssertEqual(
            PrivilegedOperationPolicy.invocation(
                name: "create-cli-symlink",
                arguments: ["/Applications/Pearcleaner.app/Contents/MacOS/Pearcleaner", "other"]
            ).error,
            .invalidArguments
        )
    }

    func testLaunchctlAllowsOnlyKnownSubcommandsAndSafeTargets() throws {
        let bootout = try PrivilegedOperationPolicy.invocation(
            name: "launchctl",
            arguments: ["bootout", "system/com.example.agent"]
        ).get()
        XCTAssertEqual(bootout.executable, "/bin/launchctl")
        XCTAssertEqual(bootout.arguments, ["bootout", "system/com.example.agent"])

        let unload = try PrivilegedOperationPolicy.invocation(
            name: "launchctl",
            arguments: ["unload", "/Library/LaunchDaemons/com.example.plist"]
        ).get()
        XCTAssertEqual(unload.arguments, ["unload", "/Library/LaunchDaemons/com.example.plist"])

        XCTAssertEqual(
            PrivilegedOperationPolicy.invocation(
                name: "launchctl",
                arguments: ["bootout", "system/com.example; reboot"]
            ).error,
            .invalidArguments
        )
        XCTAssertEqual(
            PrivilegedOperationPolicy.invocation(
                name: "launchctl",
                arguments: ["unload", "/tmp/evil.plist"]
            ).error,
            .rejectedPath
        )
        XCTAssertEqual(
            PrivilegedOperationPolicy.invocation(
                name: "launchctl",
                arguments: ["submit", "com.example"]
            ).error,
            .invalidArguments
        )
    }

    func testProcessAndPackageOperationsValidateIdentifiers() throws {
        let pkill = try PrivilegedOperationPolicy.invocation(
            name: "pkill",
            arguments: ["-9", "-f", "Example.app"]
        ).get()
        XCTAssertEqual(pkill.executable, "/usr/bin/pkill")
        XCTAssertEqual(pkill.arguments, ["-9", "-f", "Example.app"])

        let killall = try PrivilegedOperationPolicy.invocation(
            name: "killall",
            arguments: ["-15", "com.example.App"]
        ).get()
        XCTAssertEqual(killall.executable, "/usr/bin/killall")

        let kext = try PrivilegedOperationPolicy.invocation(
            name: "kextunload",
            arguments: ["com.example.kext"]
        ).get()
        XCTAssertEqual(kext.executable, "/sbin/kextunload")
        XCTAssertEqual(kext.arguments, ["-b", "com.example.kext"])

        let files = try PrivilegedOperationPolicy.invocation(
            name: "pkgutil-files",
            arguments: ["com.example.pkg"]
        ).get()
        XCTAssertEqual(files.arguments, ["--files", "com.example.pkg"])

        let forget = try PrivilegedOperationPolicy.invocation(
            name: "pkgutil-forget",
            arguments: ["com.example.pkg"]
        ).get()
        XCTAssertEqual(forget.arguments, ["--forget", "com.example.pkg"])

        XCTAssertEqual(
            PrivilegedOperationPolicy.invocation(name: "pkill", arguments: ["-9", "a;reboot"]).error,
            .invalidArguments
        )
        XCTAssertEqual(
            PrivilegedOperationPolicy.invocation(name: "kextunload", arguments: ["../evil"]).error,
            .invalidArguments
        )
    }

    func testThinningPathsMustBeAbsoluteApplicationTargets() {
        XCTAssertTrue(
            ThinningPathPolicy.isAcceptable("/Applications/Demo.app/Contents/MacOS/Demo")
        )
        XCTAssertTrue(ThinningPathPolicy.isAcceptable("/Applications/Demo.app"))
        XCTAssertFalse(ThinningPathPolicy.isAcceptable("Applications/Demo.app"))
        XCTAssertFalse(ThinningPathPolicy.isAcceptable("/tmp/Demo.app"))
        XCTAssertFalse(ThinningPathPolicy.isAcceptable("/Applications/../tmp/Demo.app"))
    }

    func testHelperIdentityPinsBothSides() {
        XCTAssertTrue(HelperIdentity.clientRequirement.contains(#"identifier "com.lukerow.Pearcleaner""#))
        XCTAssertTrue(HelperIdentity.helperRequirement.contains(#"identifier "com.lukerow.Pearcleaner.PearcleanerHelper""#))
        XCTAssertTrue(HelperIdentity.clientRequirement.contains("68583N3MNF"))
        XCTAssertTrue(HelperIdentity.helperRequirement.contains("68583N3MNF"))
    }

    func testFolderAndDeepLinkPoliciesRejectSystemRoots() {
        XCTAssertFalse(FolderPathPolicy.isAcceptableScanRoot("/"))
        XCTAssertFalse(FolderPathPolicy.isAcceptableScanRoot("/System"))
        XCTAssertFalse(FolderPathPolicy.isAcceptableOrphanExclusion("/"))
        XCTAssertTrue(FolderPathPolicy.isAcceptableScanRoot("/Applications"))
        XCTAssertTrue(DeepLinkSafety.requiresConfirmation(host: "appsPaths"))
        XCTAssertTrue(DeepLinkSafety.requiresConfirmation(host: "orphanedPaths"))
        XCTAssertTrue(DeepLinkSafety.requiresConfirmation(host: "uninstallApp"))
        XCTAssertFalse(DeepLinkSafety.requiresConfirmation(host: "openSettings"))
    }

    func testSettingsImportAllowlistDropsUnknownAndDangerousFolderRoots() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "settings.general.oneshot": true,
            "settings.invented.key": "no",
            "settings.folders.apps": ["/", "/Applications"]
        ])

        let imported = try SettingsExportCodec.importSettings(from: data)

        XCTAssertEqual(imported["settings.general.oneshot"] as? Bool, true)
        XCTAssertNil(imported["settings.invented.key"])
        XCTAssertEqual(imported["settings.folders.apps"] as? [String], ["/Applications"])
    }
}

private extension Result {
    var error: Failure? {
        if case .failure(let error) = self {
            return error
        }
        return nil
    }
}
