#!/bin/bash
#
# Builds Pearcleaner (Debug) and installs it as the one copy on this Mac, at
# /Applications/Pearcleaner.app. The build output is then unregistered so
# macOS only ever sees the installed copy.
#
# Usage: script/dev_build.sh [--no-open]
# See docs/DEVELOPMENT.md.

set -euo pipefail

OPEN_AFTER_INSTALL=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-open) OPEN_AFTER_INSTALL=0 ;;
        -h|--help) sed -n '3,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 64 ;;
    esac
    shift
done

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "dev_build.sh only runs on macOS." >&2
    exit 69
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT/.build/DevDerivedData"
SOURCE_PACKAGES="$ROOT/.build/SourcePackages"
BUILT_APP="$DERIVED_DATA/Build/Products/Debug/Pearcleaner.app"
INSTALLED_APP="/Applications/Pearcleaner.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

echo "Building Pearcleaner (Debug)..."
xcodebuild -quiet \
    -project "$ROOT/Pearcleaner.xcodeproj" \
    -scheme "Pearcleaner Debug" \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
    -allowProvisioningUpdates \
    build

if [[ ! -d "$BUILT_APP" ]]; then
    echo "Build finished but $BUILT_APP is missing." >&2
    exit 66
fi

if pgrep -x Pearcleaner >/dev/null 2>&1; then
    echo "Quitting the running Pearcleaner..."
    osascript -e 'tell application id "com.lukerow.Pearcleaner" to quit' >/dev/null 2>&1 \
        || pkill -x Pearcleaner || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x Pearcleaner >/dev/null 2>&1 || break
        sleep 0.5
    done
fi

echo "Installing to $INSTALLED_APP..."
STAGED_APP="/Applications/.Pearcleaner.app.installing"
rm -rf "$STAGED_APP"
ditto "$BUILT_APP" "$STAGED_APP"
rm -rf "$INSTALLED_APP"
mv "$STAGED_APP" "$INSTALLED_APP"

# Only the installed copy should be known to macOS, so the helper, Sentinel
# and Finder extension always resolve to one place.
"$LSREGISTER" -u "$BUILT_APP" >/dev/null 2>&1 || true
"$LSREGISTER" -f "$INSTALLED_APP" >/dev/null 2>&1 || true

echo "Installed $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALLED_APP/Contents/Info.plist") (Debug) at $INSTALLED_APP."

if [[ "$OPEN_AFTER_INSTALL" -eq 1 ]]; then
    open "$INSTALLED_APP"
fi
