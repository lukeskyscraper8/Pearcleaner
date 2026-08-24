#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
REQUESTED_SOURCE_PACKAGES="${PROJECT_SCANNER_SOURCE_PACKAGES:-$ROOT/.build/SourcePackages}"
HARNESS_TOKEN="PROJECT_SCANNER_MOUNT_HARNESS_V1_6D5A8C31"
CANARY="PROJECT_SCANNER_EXTERNAL_MOUNT_CANARY_7F6B9A2D"
BENIGN_CONTENT="PROJECT_SCANNER_LOCAL_ADMISSION_CONTROL_V1"
MARKER_CONTENT="PROJECT_SCANNER_MOUNT_BOUNDARY_OK_V1"

WORK=""
WORK_REAL=""
FIXTURE=""
MOUNT=""
MOUNT_REAL=""
IMAGE=""
IMAGE_REAL=""
ATTACH_LOG=""
ATTACHED_DEVICE=""
RESULT_MARKER=""
MOUNT_XCTESTRUN=""

mount_table_state() {
    local scope="$1"
    local output
    if ! output="$(/sbin/mount)"; then
        return 2
    fi
    /usr/bin/awk -v scope="$scope" '
        $2 == "on" && ($3 == scope || index($3, scope "/") == 1) { found = 1 }
        END { exit found ? 0 : 1 }
    ' <<<"$output"
}

exact_mount_state() {
    local device="$1"
    local output
    if ! output="$(/sbin/mount)"; then
        return 2
    fi
    /usr/bin/awk -v device="$device" -v mount_one="$MOUNT" -v mount_two="$MOUNT_REAL" '
        $1 == device && $2 == "on" && ($3 == mount_one || $3 == mount_two) { count += 1 }
        END { exit count == 1 ? 0 : 1 }
    ' <<<"$output"
}

write_hdiutil_info() {
    [[ -n "$WORK" && -d "$WORK" ]] || return 2
    /usr/bin/hdiutil info > "$WORK/hdiutil-info.log"
}

image_attached_state() {
    if ! write_hdiutil_info; then
        return 2
    fi
    /usr/bin/awk -v image_one="$IMAGE" -v image_two="$IMAGE_REAL" '
        $1 == "image-path" && $2 == ":" && ($3 == image_one || $3 == image_two) { found = 1 }
        END { exit found ? 0 : 1 }
    ' "$WORK/hdiutil-info.log"
}

devices_for_image() {
    /usr/bin/awk -v image_one="$IMAGE" -v image_two="$IMAGE_REAL" '
        /^={4,}$/ { active = 0; next }
        $1 == "image-path" && $2 == ":" {
            active = ($3 == image_one || $3 == image_two)
            next
        }
        active && $1 ~ /^\/dev\/disk[0-9]+(s[0-9]+)?$/ { print $1 }
    ' "$WORK/hdiutil-info.log"
}

validated_work_path() {
    [[ "$WORK" =~ ^/tmp/project-scanner-mount\.[[:alnum:]]{6}$ ]] || return 1
    [[ "$WORK_REAL" =~ ^/private/tmp/project-scanner-mount\.[[:alnum:]]{6}$ ]] || return 1
    [[ -d "$WORK" && ! -L "$WORK" ]] || return 1
    [[ "$(/usr/bin/stat -f '%u' "$WORK")" == "$(/usr/bin/id -u)" ]] || return 1
    [[ "$(cd "$WORK" && pwd -P)" == "$WORK_REAL" ]] || return 1
}

cleanup() {
    local command_status=$?
    local cleanup_failed=0
    local state=0
    local device=""
    local detached=0
    trap - EXIT INT TERM HUP
    set +e

    if [[ -z "$WORK" ]]; then
        exit "$command_status"
    fi

    image_attached_state
    state=$?
    if [[ $state -eq 2 ]]; then
        cleanup_failed=1
    elif [[ $state -eq 0 ]]; then
        if [[ -n "$ATTACHED_DEVICE" ]]; then
            if /usr/bin/hdiutil detach "$ATTACHED_DEVICE" >/dev/null; then
                detached=1
            else
                cleanup_failed=1
            fi
        fi

        image_attached_state
        state=$?
        if [[ $state -eq 2 ]]; then
            cleanup_failed=1
        elif [[ $state -eq 0 ]]; then
            while IFS= read -r device; do
                [[ -n "$device" ]] || continue
                if /usr/bin/hdiutil detach "$device" >/dev/null; then
                    detached=1
                else
                    cleanup_failed=1
                fi
                if image_attached_state; then
                    continue
                fi
                state=$?
                [[ $state -eq 1 ]] && break
                cleanup_failed=1
                break
            done < <(devices_for_image)
        fi
    fi

    if [[ $detached -eq 0 ]]; then
        mount_table_state "$WORK_REAL"
        state=$?
        if [[ $state -eq 0 ]]; then
            if /usr/bin/hdiutil detach "$MOUNT_REAL" >/dev/null; then
                detached=1
            else
                cleanup_failed=1
            fi
        elif [[ $state -eq 2 ]]; then
            cleanup_failed=1
        fi
    fi

    mount_table_state "$WORK_REAL"
    state=$?
    [[ $state -eq 1 ]] || cleanup_failed=1
    image_attached_state
    state=$?
    [[ $state -eq 1 ]] || cleanup_failed=1

    if [[ -n "$MOUNT_XCTESTRUN" && ( -e "$MOUNT_XCTESTRUN" || -L "$MOUNT_XCTESTRUN" ) ]]; then
        case "$MOUNT_XCTESTRUN" in
            "$ROOT/.build/ProjectScannerMountDerivedData/Build/Products/"ProjectScannerCore-mount-*.xctestrun)
                if [[ -f "$MOUNT_XCTESTRUN" && ! -L "$MOUNT_XCTESTRUN" &&
                      "$(/usr/bin/stat -f '%u' "$MOUNT_XCTESTRUN")" == "$(/usr/bin/id -u)" ]]; then
                    /bin/rm -f -- "$MOUNT_XCTESTRUN" || cleanup_failed=1
                else
                    cleanup_failed=1
                fi
                ;;
            *)
                cleanup_failed=1
                ;;
        esac
    fi

    if ! validated_work_path; then
        cleanup_failed=1
    fi

    if [[ $cleanup_failed -eq 0 ]]; then
        /bin/rm -rf -- "$WORK"
        if [[ -e "$WORK" || -L "$WORK" ]]; then
            cleanup_failed=1
        fi
    fi

    if [[ $cleanup_failed -ne 0 ]]; then
        echo "scanner mount cleanup was uncertain; retained fixture at $WORK" >&2
        exit 1
    fi
    if [[ $command_status -eq 0 ]]; then
        echo "project scanner mount boundary test passed"
    fi
    exit "$command_status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[[ -d "$ROOT/Pearcleaner.xcodeproj" ]] || {
    echo "Pearcleaner.xcodeproj is missing" >&2
    exit 1
}
[[ -d "$REQUESTED_SOURCE_PACKAGES" ]] || {
    echo "scanner source-package cache does not exist: $REQUESTED_SOURCE_PACKAGES" >&2
    exit 1
}
SOURCE_PACKAGES="$(cd "$REQUESTED_SOURCE_PACKAGES" && pwd -P)"
[[ -d "$SOURCE_PACKAGES" && ! -L "$SOURCE_PACKAGES" ]] || {
    echo "scanner source-package cache did not resolve to a directory" >&2
    exit 1
}

umask 077
WORK="$(/usr/bin/mktemp -d /tmp/project-scanner-mount.XXXXXX)"
WORK_REAL="$(cd "$WORK" && pwd -P)"
validated_work_path || {
    echo "scanner mount fixture path failed validation: $WORK" >&2
    exit 1
}

FIXTURE="$WORK/root"
MOUNT="$FIXTURE/mounted"
IMAGE="$WORK/mount.dmg"
ATTACH_LOG="$WORK/attach.log"
RESULT_MARKER="$WORK/mount-boundary.result"
/bin/mkdir -p "$MOUNT"
MOUNT_REAL="$(cd "$MOUNT" && pwd -P)"

[[ "$FIXTURE" == "$WORK/root" && "$MOUNT" == "$WORK/root/mounted" ]] || exit 1
[[ "$RESULT_MARKER" == "$WORK/mount-boundary.result" && ! -e "$RESULT_MARKER" && ! -L "$RESULT_MARKER" ]] || exit 1
[[ "$(/usr/bin/stat -f '%d' "$FIXTURE")" == "$(/usr/bin/stat -f '%d' "$MOUNT")" ]] || {
    echo "scanner mountpoint was not initially on the fixture device" >&2
    exit 1
}

/usr/bin/printf '%s' "$BENIGN_CONTENT" > "$FIXTURE/benign-local.txt"
[[ -f "$FIXTURE/benign-local.txt" && ! -L "$FIXTURE/benign-local.txt" ]] || exit 1
[[ "$(/usr/bin/stat -f '%u' "$FIXTURE/benign-local.txt")" == "$(/usr/bin/id -u)" ]] || exit 1
[[ "$(/usr/bin/stat -f '%d' "$FIXTURE/benign-local.txt")" == "$(/usr/bin/stat -f '%d' "$FIXTURE")" ]] || exit 1

/usr/bin/hdiutil create -quiet -size 64m -fs APFS -volname ProjectScannerBoundary "$IMAGE"
[[ -f "$IMAGE" && ! -L "$IMAGE" ]] || {
    echo "scanner test image was not created as one regular file" >&2
    exit 1
}
[[ "$(/usr/bin/stat -f '%u' "$IMAGE")" == "$(/usr/bin/id -u)" ]] || exit 1
IMAGE_REAL="$(cd "$(dirname "$IMAGE")" && pwd -P)/$(basename "$IMAGE")"

/usr/bin/hdiutil attach -nobrowse -mountpoint "$MOUNT" "$IMAGE" > "$ATTACH_LOG"
MOUNTED_DEVICES="$WORK/mounted-devices"
/usr/bin/awk -v mount_one="$MOUNT" -v mount_two="$MOUNT_REAL" '
    ($NF == mount_one || $NF == mount_two) { print $1 }
' "$ATTACH_LOG" > "$MOUNTED_DEVICES"
[[ "$(/usr/bin/wc -l < "$MOUNTED_DEVICES" | /usr/bin/tr -d ' ')" == "1" ]] || {
    echo "scanner test image did not report exactly one mounted device" >&2
    exit 1
}
ATTACHED_DEVICE="$(/bin/cat "$MOUNTED_DEVICES")"
[[ "$ATTACHED_DEVICE" =~ ^/dev/disk[0-9]+s[0-9]+$ ]] || {
    echo "scanner test image reported an invalid mounted device" >&2
    exit 1
}
exact_mount_state "$ATTACHED_DEVICE" || {
    echo "scanner test image was absent from the exact live mountpoint" >&2
    exit 1
}
image_attached_state || {
    echo "scanner test image was absent from hdiutil state" >&2
    exit 1
}

ROOT_DEVICE="$(/usr/bin/stat -f '%d' "$FIXTURE")"
MOUNT_DEVICE="$(/usr/bin/stat -f '%d' "$MOUNT")"
[[ "$ROOT_DEVICE" =~ ^[0-9]+$ && "$MOUNT_DEVICE" =~ ^[0-9]+$ && "$ROOT_DEVICE" != "$MOUNT_DEVICE" ]] || {
    echo "scanner test mount did not cross st_dev" >&2
    exit 1
}

/usr/bin/printf '%s' "$CANARY" > "$MOUNT/canary.txt"
[[ -f "$MOUNT/canary.txt" && ! -L "$MOUNT/canary.txt" ]] || exit 1
[[ "$(/usr/bin/stat -f '%u' "$MOUNT/canary.txt")" == "$(/usr/bin/id -u)" ]] || exit 1
[[ "$(/usr/bin/stat -f '%d' "$MOUNT/canary.txt")" == "$MOUNT_DEVICE" ]] || exit 1

xcodebuild -quiet \
  -project "$ROOT/Pearcleaner.xcodeproj" \
  -scheme ProjectScannerCore \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$ROOT/.build/ProjectScannerMountDerivedData" \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ProjectScannerCoreTests/MountBoundaryIntegrationTests \
  build-for-testing

PRODUCTS_DIR="$ROOT/.build/ProjectScannerMountDerivedData/Build/Products"
XCTESTRUN_PATHS="$WORK/xctestrun-paths"
/usr/bin/find "$PRODUCTS_DIR" -maxdepth 1 -type f \
  -name 'ProjectScannerCore_*.xctestrun' ! -name '*-mount-*.xctestrun' \
  -print > "$XCTESTRUN_PATHS"
[[ "$(/usr/bin/wc -l < "$XCTESTRUN_PATHS" | /usr/bin/tr -d ' ')" == "1" ]] || {
    echo "scanner mount build did not produce exactly one base xctestrun" >&2
    exit 1
}
BASE_XCTESTRUN="$(/bin/cat "$XCTESTRUN_PATHS")"
[[ -f "$BASE_XCTESTRUN" && ! -L "$BASE_XCTESTRUN" ]] || exit 1
[[ "$(/usr/bin/stat -f '%u' "$BASE_XCTESTRUN")" == "$(/usr/bin/id -u)" ]] || exit 1

WORK_SUFFIX="${WORK##*.}"
MOUNT_XCTESTRUN="$PRODUCTS_DIR/ProjectScannerCore-mount-$WORK_SUFFIX.xctestrun"
[[ ! -e "$MOUNT_XCTESTRUN" && ! -L "$MOUNT_XCTESTRUN" ]] || {
    echo "scanner mount xctestrun destination already exists" >&2
    exit 1
}

/usr/bin/python3 -c '
import copy
import plistlib
import sys

source, destination, token, root, canary, marker = sys.argv[1:]
with open(source, "rb") as stream:
    original = plistlib.load(stream)

entries = [
    key
    for key, value in original.items()
    if isinstance(value, dict) and value.get("BlueprintName") == "ProjectScannerCoreTests"
]
if entries != ["ProjectScannerCoreTests"]:
    raise SystemExit("xctestrun did not contain exactly one ProjectScannerCoreTests entry")

injected = {
    "PROJECT_SCANNER_MOUNT_HARNESS_TOKEN": token,
    "PROJECT_SCANNER_MOUNT_FIXTURE_ROOT": root,
    "PROJECT_SCANNER_MOUNT_CANARY": canary,
    "PROJECT_SCANNER_MOUNT_RESULT_MARKER": marker,
}
environment = original["ProjectScannerCoreTests"].get("EnvironmentVariables")
if not isinstance(environment, dict) or any(key in environment for key in injected):
    raise SystemExit("xctestrun mount environment was not closed")

expected = copy.deepcopy(original)
expected["ProjectScannerCoreTests"]["EnvironmentVariables"].update(injected)
with open(destination, "xb") as stream:
    plistlib.dump(expected, stream, fmt=plistlib.FMT_BINARY, sort_keys=False)
with open(destination, "rb") as stream:
    written = plistlib.load(stream)
if written != expected:
    raise SystemExit("xctestrun mount environment verification failed")
' "$BASE_XCTESTRUN" "$MOUNT_XCTESTRUN" \
  "$HARNESS_TOKEN" "$FIXTURE" "$CANARY" "$RESULT_MARKER"

[[ -f "$MOUNT_XCTESTRUN" && ! -L "$MOUNT_XCTESTRUN" ]] || exit 1
[[ "$(/usr/bin/stat -f '%u' "$MOUNT_XCTESTRUN")" == "$(/usr/bin/id -u)" ]] || exit 1
/usr/bin/plutil -lint "$MOUNT_XCTESTRUN" >/dev/null

xcodebuild -quiet \
  -xctestrun "$MOUNT_XCTESTRUN" \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:ProjectScannerCoreTests/MountBoundaryIntegrationTests \
  test-without-building

[[ -f "$RESULT_MARKER" && ! -L "$RESULT_MARKER" ]] || {
    echo "scanner mount test did not create its required result marker" >&2
    exit 1
}
[[ "$(/usr/bin/stat -f '%u' "$RESULT_MARKER")" == "$(/usr/bin/id -u)" ]] || exit 1
[[ "$(/usr/bin/stat -f '%Lp' "$RESULT_MARKER")" == "600" ]] || exit 1
[[ "$(/usr/bin/stat -f '%z' "$RESULT_MARKER")" == "${#MARKER_CONTENT}" ]] || exit 1
[[ "$(/bin/cat "$RESULT_MARKER")" == "$MARKER_CONTENT" ]] || {
    echo "scanner mount test result marker was malformed" >&2
    exit 1
}
