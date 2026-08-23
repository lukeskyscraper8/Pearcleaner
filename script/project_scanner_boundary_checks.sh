#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT/ProjectScannerCore"
PROJECT="$ROOT/Pearcleaner.xcodeproj/project.pbxproj"

fail() {
    echo "project scanner boundary check failed: $1" >&2
    exit 1
}

[[ -d "$CORE" ]] || fail "ProjectScannerCore source directory is missing"
grep -q 'name = ProjectScannerCore;' "$PROJECT" \
    || fail "ProjectScannerCore target is missing"
grep -q 'name = ProjectScannerCoreTests;' "$PROJECT" \
    || fail "ProjectScannerCoreTests target is missing"

if grep -REn '^import (AppKit|SwiftUI|Security|OSLog|ServiceManagement|AlinFoundation|Sparkle|ArgumentParser)$' "$CORE" >/dev/null; then
    fail "scanner core imports a forbidden module"
fi

if grep -REn '\b(Process|NSTask|NSXPCConnection|NSWorkspace|URLSession|HelperToolManager|SentinelServiceManager)\b|\b(posix_spawn|fork|exec[lvpe]*|system|popen)\s*\(' "$CORE" >/dev/null; then
    fail "scanner core reaches a forbidden execution, network, or app service"
fi

if grep -REn '\b(socket|socketpair|connect|bind|listen|accept|send|sendto|recv|recvfrom|getaddrinfo)\s*\(' "$CORE" >/dev/null; then
    fail "scanner core reaches a Darwin networking primitive"
fi

if grep -REn '\b(UserDefaults|CFPreferences|AppGroupDefaults|printOS|GlobalConsoleManager|UpdaterDebugLogger)\b' "$CORE" >/dev/null; then
    fail "scanner core reaches shared preferences or arbitrary-string logging"
fi

if grep -REn '\b(print|debugPrint|NSLog|os_log|Logger)\s*\(' "$CORE" >/dev/null; then
    fail "scanner core reaches a generic logging API"
fi

if [[ -d "$CORE/Containment" ]] \
    && grep -REn '\b(O_WRONLY|O_RDWR|O_CREAT|O_TRUNC)\b' "$CORE/Containment" >/dev/null; then
    fail "scanner containment code contains a write-capable open flag"
fi

echo "project scanner boundary checks passed"
