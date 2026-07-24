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
    PearcleanerHelper/CodesignCheck.swift \
    || fail "the helper is not pinned to Pearcleaner's identifier and team"

if grep -n 'resetSettings' Pearcleaner/Logic/DeepLink.swift >/dev/null; then
    fail "the destructive resetSettings deep link is still public"
fi

grep -q '"version" : "2\.9\.4"' \
    Pearcleaner.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved \
    || fail "Sparkle is not resolved to the patched version"

"$ROOT/script/test_release_archive_payload.sh"

echo "security regression checks passed"
