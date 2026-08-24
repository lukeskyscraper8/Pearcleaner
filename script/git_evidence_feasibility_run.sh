#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVIDENCE_ROOT="$ROOT/docs/superpowers/evidence/git-feasibility"
DERIVED_DATA="$ROOT/.build/GitFeasibilityDerivedData"
SOURCE_PACKAGES="$ROOT/.build/SourcePackages"
SCHEME="GitFeasibilityHarness Release"
APP_PATH="$DERIVED_DATA/Build/Products/Release/GitFeasibilityHarness.app"
EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/GitFeasibilityHarness"
APPLE_GIT_VERSION="$(/usr/bin/git --version 2>/dev/null || echo "unavailable")"

fail() {
    echo "git evidence feasibility run failed: $1" >&2
    exit "${2:-1}"
}

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

run_harness_for_architecture() {
    local architecture="$1"
    local staging_root="$2"
    local launch_prefix=()

    rm -rf "$staging_root"
    mkdir -p "$staging_root"

    if [[ "$architecture" == "x86_64" ]]; then
        if [[ "$(uname -m)" != "x86_64" ]]; then
            if ! /usr/bin/arch -arch x86_64 /usr/bin/true >/dev/null 2>&1; then
                echo "Skipping x86_64 tuple: Rosetta/arch translation unavailable on this host." >&2
                return 2
            fi
            launch_prefix=(/usr/bin/arch -arch x86_64)
        fi
    fi

    echo "Running Git feasibility harness for ${architecture}..."
    set +e
    if ((${#launch_prefix[@]})); then
        GIT_FEASIBILITY_APPLE_GIT_VERSION="$APPLE_GIT_VERSION" \
            GIT_FEASIBILITY_OUTPUT="$staging_root" \
            "${launch_prefix[@]}" "$EXECUTABLE_PATH"
    else
        GIT_FEASIBILITY_APPLE_GIT_VERSION="$APPLE_GIT_VERSION" \
            GIT_FEASIBILITY_OUTPUT="$staging_root" \
            "$EXECUTABLE_PATH"
    fi
    local harness_exit=$?

    local manifest_path="$staging_root/manifest.json"
    if [[ ! -f "$manifest_path" ]]; then
        fail "harness did not write manifest.json for ${architecture}" 1
    fi

    local manifest_arch
    manifest_arch="$(read_manifest_field "$manifest_path" architecture)"
    if [[ "$manifest_arch" != "$architecture" ]]; then
        fail "manifest architecture ${manifest_arch} did not match requested ${architecture}" 1
    fi

    local os_build_family
    os_build_family="$(read_manifest_field "$manifest_path" osBuildFamily)"
    local tuple_dir="$EVIDENCE_ROOT/${os_build_family}-${architecture}"
    mkdir -p "$EVIDENCE_ROOT"
    rm -rf "$tuple_dir"
    mkdir -p "$tuple_dir"
    cp -R "$staging_root/." "$tuple_dir/"

    echo "Archived feasibility evidence to $tuple_dir"
    echo "Harness exit code (${architecture}): $harness_exit"

    return "$harness_exit"
}

require_command xcodebuild
require_command codesign
require_command python3
require_command git

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

HOST_ARCH="$(uname -m)"
ARCHITECTURES=()
if [[ "$HOST_ARCH" == "arm64" ]]; then
    ARCHITECTURES=(arm64 x86_64)
elif [[ "$HOST_ARCH" == "x86_64" ]]; then
    ARCHITECTURES=(x86_64 arm64)
else
    ARCHITECTURES=("$HOST_ARCH")
fi

OVERALL_EXIT=0
DEFERRED_ARCHITECTURES=()
STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/git-feasibility.XXXXXX")"
trap 'rm -rf "$STAGING_ROOT"' EXIT

for architecture in "${ARCHITECTURES[@]}"; do
    arch_staging="$STAGING_ROOT/$architecture"
    set +e
    run_harness_for_architecture "$architecture" "$arch_staging"
    harness_exit=$?
    set -e

    if [[ "$harness_exit" -eq 2 ]]; then
        DEFERRED_ARCHITECTURES+=("$architecture")
        continue
    fi

    if [[ "$harness_exit" -ne 0 ]]; then
        OVERALL_EXIT="$harness_exit"
    fi
done

if [[ "${#DEFERRED_ARCHITECTURES[@]}" -gt 0 ]]; then
    echo "Deferred architectures: ${DEFERRED_ARCHITECTURES[*]}" >&2
fi

if [[ "$OVERALL_EXIT" -ne 0 ]]; then
    exit "$OVERALL_EXIT"
fi

echo "Git feasibility harness matrix completed successfully."
