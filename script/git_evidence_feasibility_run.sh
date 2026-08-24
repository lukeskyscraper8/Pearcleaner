#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT/.build/GitFeasibilityDerivedData"
SOURCE_PACKAGES="$ROOT/.build/SourcePackages"
SCHEME="GitFeasibilityHarness Release"
APP_PATH="$DERIVED_DATA/Build/Products/Release/GitFeasibilityHarness.app"
EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/GitFeasibilityHarness"
EVIDENCE_ROOT="$ROOT/docs/superpowers/evidence/git-feasibility"
STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/git-feasibility.XXXXXX")"

fail() {
    echo "git evidence feasibility run failed: $1" >&2
    exit "${2:-1}"
}

cleanup() {
    rm -rf "$STAGING_ROOT"
}
trap cleanup EXIT

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        fail "required command not found: $1" 69
    fi
}

verify_codesign_not_adhoc() {
    local app_path="$1"

    if [[ ! -d "$app_path" ]]; then
        fail "harness app bundle not found: $app_path" 66
    fi

    local signature_details
    signature_details="$(/usr/bin/codesign -dv --verbose=4 "$app_path" 2>&1)"

    if echo "$signature_details" | /usr/bin/grep -Fq "Signature=adhoc"; then
        fail "Release harness is ad-hoc signed; production signing is required" 1
    fi

    if echo "$signature_details" | /usr/bin/grep -Fq "code object is not signed at all"; then
        fail "Release harness is unsigned" 1
    fi

    /usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
}

read_manifest_field() {
    local manifest_path="$1"
    local field_name="$2"
    /usr/bin/python3 - "$manifest_path" "$field_name" <<'PY'
import json
import sys

manifest_path, field_name = sys.argv[1:3]
with open(manifest_path, "r", encoding="utf-8") as handle:
    manifest = json.load(handle)
value = manifest.get(field_name)
if value is None:
    raise SystemExit(f"missing manifest field: {field_name}")
print(value)
PY
}

require_command xcodebuild
require_command codesign
require_command python3

echo "Building signed Git feasibility harness (Release)..."
xcodebuild -quiet \
    -project "$ROOT/Pearcleaner.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
    -disableAutomaticPackageResolution \
    build

verify_codesign_not_adhoc "$APP_PATH"

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
    fail "harness executable not found: $EXECUTABLE_PATH" 66
fi

echo "Running Git feasibility harness scenarios..."
set +e
GIT_FEASIBILITY_OUTPUT="$STAGING_ROOT" "$EXECUTABLE_PATH"
HARNESS_EXIT=$?
set -e

MANIFEST_PATH="$STAGING_ROOT/manifest.json"
if [[ ! -f "$MANIFEST_PATH" ]]; then
    fail "harness did not write manifest.json" 1
fi

OS_BUILD_FAMILY="$(read_manifest_field "$MANIFEST_PATH" osBuildFamily)"
ARCHITECTURE="$(read_manifest_field "$MANIFEST_PATH" architecture)"
TUPLE_DIR="$EVIDENCE_ROOT/${OS_BUILD_FAMILY}-${ARCHITECTURE}"

mkdir -p "$EVIDENCE_ROOT"
rm -rf "$TUPLE_DIR"
mkdir -p "$TUPLE_DIR"
cp -R "$STAGING_ROOT/." "$TUPLE_DIR/"

echo "Archived feasibility evidence to $TUPLE_DIR"
echo "Harness exit code: $HARNESS_EXIT (non-zero expected for Task 1 placeholders)"

if [[ "$HARNESS_EXIT" -ne 0 ]]; then
    exit "$HARNESS_EXIT"
fi

echo "Git feasibility harness completed successfully."
