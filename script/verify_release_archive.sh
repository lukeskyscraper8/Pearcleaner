#!/bin/zsh

# Verify the exact Pearcleaner ZIP intended for distribution.
# Modified for the independently maintained Pearcleaner fork.

set -euo pipefail

archive_path="${1:-}"
expected_version="${2:-}"
expected_digest="${3:-}"
expected_bundle_id="com.lukerow.Pearcleaner"
expected_team_id="68583N3MNF"
script_root="${0:A:h}"
payload_validator="$script_root/validate_release_archive_payload.sh"

if [[ -z "$archive_path" || -z "$expected_version" || -z "$expected_digest" ]]; then
    print -u2 "Usage: $0 ARCHIVE EXPECTED_VERSION sha256:EXPECTED_DIGEST"
    exit 64
fi

if [[ ! -f "$archive_path" ]]; then
    print -u2 "Release archive not found: $archive_path"
    exit 66
fi

if [[ ! -x "$payload_validator" ]]; then
    print -u2 "Release archive payload validator is missing or not executable."
    exit 69
fi

archive_path="${archive_path:A}"
"$payload_validator" "$archive_path"

normalized_version="${expected_version#v}"
normalized_version="${normalized_version#V}"
normalized_digest="${expected_digest#sha256:}"
normalized_digest="${normalized_digest:l}"

if [[ ! "$normalized_digest" =~ '^[0-9a-f]{64}$' ]]; then
    print -u2 "Expected digest must use GitHub's sha256:HEX format."
    exit 65
fi

actual_digest="$(/usr/bin/shasum -a 256 "$archive_path" | /usr/bin/awk '{print $1}')"
if [[ "$actual_digest" != "$normalized_digest" ]]; then
    print -u2 "Archive digest mismatch."
    exit 1
fi

temporary_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/Pearcleaner-Release-Verify.XXXXXX")"
trap '/bin/rm -rf "$temporary_root"' EXIT
extraction_root="$temporary_root/Extracted"
/bin/mkdir -p "$extraction_root"
/usr/bin/ditto -xk "$archive_path" "$extraction_root"
"$payload_validator" "$archive_path" "$extraction_root"

app_path="$extraction_root/Pearcleaner.app"
info_plist="$app_path/Contents/Info.plist"
if [[ ! -f "$info_plist" ]]; then
    print -u2 "Application Info.plist is missing."
    exit 1
fi

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"
bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist")"

if [[ "$bundle_id" != "$expected_bundle_id" ]]; then
    print -u2 "Unexpected bundle identifier: $bundle_id"
    exit 1
fi

if [[ "${bundle_version#v}" != "$normalized_version" && "${bundle_version#V}" != "$normalized_version" ]]; then
    print -u2 "Unexpected bundle version: $bundle_version (expected $normalized_version)"
    exit 1
fi

main_executable="$app_path/Contents/MacOS/$executable_name"
if [[ ! -f "$main_executable" ]]; then
    print -u2 "Main executable is missing: $main_executable"
    exit 1
fi

architectures="$(/usr/bin/lipo -archs "$main_executable")"
if [[ " $architectures " != *" arm64 "* || " $architectures " != *" x86_64 "* ]]; then
    print -u2 "Release must contain arm64 and x86_64; found: $architectures"
    exit 1
fi

/usr/bin/codesign \
    --verify \
    --deep \
    --strict \
    --all-architectures \
    --verbose=2 \
    "$app_path"

signature_details="$(/usr/bin/codesign -d --verbose=4 "$app_path" 2>&1)"
team_id="$(print -r -- "$signature_details" | /usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}')"
if [[ "$team_id" != "$expected_team_id" ]]; then
    print -u2 "Unexpected signing team: ${team_id:-missing}"
    exit 1
fi

/usr/sbin/spctl --assess --type execute --verbose=4 "$app_path"
/usr/bin/xcrun stapler validate "$app_path"

print "Verified release archive: $archive_path"
print "Bundle: $bundle_id $bundle_version"
print "Architectures: $architectures"
print "Team: $team_id"
