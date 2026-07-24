#!/bin/zsh

set -euo pipefail

script_root="${0:A:h}"
validator="$script_root/validate_release_archive_payload.sh"
summary_validator="$script_root/validate_release_archive_summary.sh"
fixture_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/Pearcleaner-Archive-Fixtures.XXXXXX")"
trap '/bin/rm -rf "$fixture_root"' EXIT

fail() {
    print -u2 "release archive payload fixture failed: $1"
    exit 1
}

expect_rejection() {
    local archive_path="$1"
    if "$validator" "$archive_path" >/dev/null 2>&1; then
        fail "unsafe archive was accepted: ${archive_path:t}"
    fi
}

expect_summary_rejection() {
    local summary="$1"
    if "$summary_validator" "$summary" >/dev/null 2>&1; then
        fail "unsafe or malformed ZIP summary was accepted: $summary"
    fi
}

/usr/bin/python3 - "$fixture_root" <<'PYTHON'
import os
import stat
import struct
import sys
import zipfile

root = sys.argv[1]


def write_archive(name, entries):
    path = os.path.join(root, name)
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for entry_name, contents in entries:
            archive.writestr(entry_name, contents)


valid_entries = [
    ("Pearcleaner.app/", b""),
    ("Pearcleaner.app/Contents/", b""),
    ("Pearcleaner.app/Contents/Info.plist", b"fixture"),
]
write_archive("valid.zip", valid_entries)
write_archive("sibling.zip", valid_entries + [("README.txt", b"unrelated")])
write_archive(
    "traversal.zip",
    [("Pearcleaner.app/", b""), ("Pearcleaner.app/../escape", b"unsafe")],
)
write_archive(
    "absolute.zip",
    [("/Pearcleaner.app/Contents/Info.plist", b"unsafe")],
)
write_archive(
    "nested-root.zip",
    [("Payload/Pearcleaner.app/Contents/Info.plist", b"unsafe")],
)
write_archive(
    "backslash.zip",
    [(r"Pearcleaner.app\Contents\Info.plist", b"unsafe")],
)
write_archive(
    "ambiguous-component.zip",
    [("Pearcleaner.app//Contents/Info.plist", b"unsafe")],
)
oversized_path = os.path.join(root, "oversized-summary.zip")
write_archive(
    "oversized-summary.zip",
    [("Pearcleaner.app/Contents/Info.plist", b"fixture")],
)
with open(oversized_path, "rb") as archive_file:
    oversized_data = bytearray(archive_file.read())
central_directory = oversized_data.index(b"PK\x01\x02")
struct.pack_into("<I", oversized_data, central_directory + 24, 2_147_483_649)
with open(oversized_path, "wb") as archive_file:
    archive_file.write(oversized_data)

symlink_path = os.path.join(root, "symlink-root.zip")
with zipfile.ZipFile(symlink_path, "w") as archive:
    link = zipfile.ZipInfo("Pearcleaner.app")
    link.create_system = 3
    link.external_attr = (stat.S_IFLNK | 0o777) << 16
    archive.writestr(link, "Elsewhere.app")
PYTHON

"$validator" "$fixture_root/valid.zip"

[[ "$("$summary_validator" "1 file, 0 bytes uncompressed, 0 bytes compressed:  0.0%")" == "1 0" ]] \
    || fail "valid singular ZIP summary was rejected"
[[ "$("$summary_validator" "100000 files, 2147483648 bytes uncompressed, 1 bytes compressed:  99.9%")" == "100000 2147483648" ]] \
    || fail "exact archive expansion limits were rejected"

expect_summary_rejection \
    "100001 files, 1 bytes uncompressed, 1 bytes compressed:  0.0%"
expect_summary_rejection \
    "1 file, 2147483649 bytes uncompressed, 1 bytes compressed:  0.0%"
expect_summary_rejection \
    "999999999999999999999999 files, 1 bytes uncompressed, 1 bytes compressed:  0.0%"
expect_summary_rejection \
    "1 file, 999999999999999999999999 bytes uncompressed, 1 bytes compressed:  0.0%"
expect_summary_rejection \
    "0 files, 0 bytes uncompressed, 0 bytes compressed:  0.0%"
expect_summary_rejection \
    "1 Datei, 1 Byte unkomprimiert"
expect_summary_rejection \
    $'1 file, 1 bytes uncompressed, 1 bytes compressed:  0.0%\nuntrusted'

for archive_path in \
    "$fixture_root/sibling.zip" \
    "$fixture_root/traversal.zip" \
    "$fixture_root/absolute.zip" \
    "$fixture_root/nested-root.zip" \
    "$fixture_root/backslash.zip" \
    "$fixture_root/ambiguous-component.zip" \
    "$fixture_root/oversized-summary.zip"; do
    expect_rejection "$archive_path"
done

valid_extraction="$fixture_root/Valid-Extracted"
/bin/mkdir -p "$valid_extraction"
/usr/bin/ditto -xk "$fixture_root/valid.zip" "$valid_extraction"
"$validator" "$fixture_root/valid.zip" "$valid_extraction"

symlink_extraction="$fixture_root/Symlink-Extracted"
/bin/mkdir -p "$symlink_extraction"
/usr/bin/ditto -xk "$fixture_root/symlink-root.zip" "$symlink_extraction"
if "$validator" "$fixture_root/symlink-root.zip" "$symlink_extraction" >/dev/null 2>&1; then
    fail "symbolic-link app root was accepted"
fi

print "release archive payload fixtures passed"
