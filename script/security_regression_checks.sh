#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() {
    echo "security regression check failed: $1" >&2
    exit 1
}

if grep -REn 'password(Request|Response)|DistributedNotificationCenter.*password' Pearcleaner >/dev/null; then
    fail "password data is still routed through distributed notifications"
fi

if [[ -e Pearcleaner/Logic/KeychainPasswordManager.swift || -e Pearcleaner/Logic/PasswordRequestHandler.swift ]]; then
    fail "legacy reusable-password components still exist"
fi

if [[ -e Pearcleaner/Resources/askpass.sh ]] \
    || grep -REn 'ask-password|SUDO_ASKPASS' Pearcleaner >/dev/null; then
    fail "an app-mediated sudo password path is still present"
fi

grep -Eq 'identifier "com\.lukerow\.Pearcleaner".*subject\.OU.*68583N3MNF' \
    Pearcleaner/Logic/PrivilegedOperation.swift \
    || fail "the helper is not pinned to Pearcleaner's identifier and team"

grep -q 'HelperIdentity.clientRequirement' \
    PearcleanerHelper/CodesignCheck.swift \
    || fail "the helper does not use the shared client identity requirement"

if grep -n 'resetSettings' Pearcleaner/Logic/DeepLink.swift >/dev/null; then
    fail "the destructive resetSettings deep link is still public"
fi

grep -q '"version" : "2\.9\.4"' \
    Pearcleaner.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved \
    || fail "Sparkle is not resolved to the patched version"

if grep -REn 'func runCommand\(command: String' Pearcleaner PearcleanerHelper >/dev/null; then
    fail "the helper still accepts an unconstrained command string"
fi

if grep -n '/bin/bash' PearcleanerHelper/main.swift >/dev/null; then
    fail "the helper still invokes bash"
fi

grep -q 'setCodeSigningRequirement(HelperIdentity.helperRequirement)' \
    Pearcleaner/Logic/HelperToolManager.swift \
    || fail "the app does not pin the helper's code-signing identity"

if grep -n -- '--no-quarantine' Pearcleaner/Logic/Brew/HomebrewController.swift >/dev/null; then
    fail "Homebrew cask install still disables quarantine"
fi

if grep -REn '/tmp/homebrew-autoupdate\.log' Pearcleaner >/dev/null; then
    fail "Homebrew auto-update still logs to /tmp"
fi

if grep -nE 'runSUCommand|executable.*joined\(separator: " "\)|args\.joined\(separator: " "\)' \
    Pearcleaner/Logic/Brew/HomebrewUninstaller.swift >/dev/null; then
    fail "Homebrew uninstall still concatenates privileged script argv"
fi

grep -A3 'func handleEarlyScript' Pearcleaner/Logic/Brew/HomebrewUninstaller.swift \
    | grep -q 'throw HomebrewError.commandFailed' \
    || fail "cask early_script directives are still executed"

grep -A3 'func handleScript' Pearcleaner/Logic/Brew/HomebrewUninstaller.swift \
    | grep -q 'throw HomebrewError.commandFailed' \
    || fail "cask script directives are still executed"

"$ROOT/script/test_release_archive_payload.sh"

echo "security regression checks passed"
