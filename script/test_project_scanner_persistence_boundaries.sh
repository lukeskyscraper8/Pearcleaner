#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE_PACKAGES="${PROJECT_SCANNER_SOURCE_PACKAGES:-$ROOT/.build/SourcePackages}"
[[ -d "$SOURCE_PACKAGES" ]] || {
    echo "project scanner source-package cache is missing: $SOURCE_PACKAGES" >&2
    exit 1
}
SOURCE_PACKAGES="$(cd "$SOURCE_PACKAGES" && pwd -P)"

WORK="$(mktemp -d /tmp/project-scanner-process.XXXXXX)"
chmod 700 "$WORK"
DERIVED_DATA="$WORK/DerivedData"
LOCK_HELPER="$WORK/project-scanner-lock-holder"
EXPECTED_XCTEST=""
TEST_BUNDLE=""
TEST_EXECUTABLE=""
TEST_EXECUTABLE_REAL=""
BASE_XCTESTRUN=""
ROLE_XCTESTRUN_INDEX=0
RESULT_BUNDLE_INDEX=0
TRACKED_BUILD_PIDS=()
TRACKED_TEST_PIDS=()

is_live() {
    kill -0 "$1" 2>/dev/null
}

matching_test_pids() {
    local pid=""
    [[ -n "$EXPECTED_XCTEST" && -n "$TEST_EXECUTABLE" ]] || return 0
    while IFS= read -r pid; do
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
        if is_project_scanner_test_process "$pid"; then
            echo "$pid"
        fi
    done < <(/bin/ps -axo pid=,command= | /usr/bin/awk -v runner="$EXPECTED_XCTEST" '$2 == runner { print $1 }')
}

is_project_scanner_test_process() {
    local pid="$1"
    local owner=""
    local command_line=""
    local command_parts=()

    owner="$(/bin/ps -o uid= -p "$pid" 2>/dev/null | /usr/bin/tr -d '[:space:]')"
    [[ "$owner" == "$(/usr/bin/id -u)" ]] || return 1
    command_line="$(/bin/ps -ww -o command= -p "$pid" 2>/dev/null)"
    read -r -a command_parts <<< "$command_line"
    [[ "${command_parts[0]:-}" == "$EXPECTED_XCTEST" ]] || return 1
    /usr/sbin/lsof -Fn -p "$pid" 2>/dev/null | /usr/bin/grep -Fx "n$TEST_EXECUTABLE_REAL" >/dev/null
}

cleanup() {
    local command_status=$?
    local cleanup_failed=0
    local pid=""
    set +u
    trap - EXIT INT TERM HUP

    for pid in "${TRACKED_TEST_PIDS[@]}"; do
        if is_live "$pid"; then kill -KILL "$pid" 2>/dev/null || true; fi
    done
    for pid in "${TRACKED_BUILD_PIDS[@]}"; do
        if is_live "$pid"; then kill -KILL "$pid" 2>/dev/null || true; fi
    done
    for pid in "${TRACKED_BUILD_PIDS[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    for _ in {1..100}; do
        local found_live=0
        for pid in "${TRACKED_TEST_PIDS[@]}"; do
            if is_live "$pid"; then found_live=1; fi
        done
        while IFS= read -r pid; do
            [[ -n "$pid" ]] || continue
            if is_live "$pid"; then
                found_live=1
                kill -KILL "$pid" 2>/dev/null || true
            fi
        done < <(matching_test_pids)
        [[ "$found_live" -eq 0 ]] && break
        sleep 0.05
    done

    for pid in "${TRACKED_TEST_PIDS[@]}"; do
        if is_live "$pid"; then cleanup_failed=1; fi
    done
    while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        if is_live "$pid"; then cleanup_failed=1; fi
    done < <(matching_test_pids)

    if [[ "$WORK" != /tmp/project-scanner-process.?????? \
          || ! -d "$WORK" \
          || -L "$WORK" \
          || "$(/usr/bin/stat -f '%u' "$WORK")" != "$(/usr/bin/id -u)" \
          || "$(/usr/bin/stat -f '%Lp' "$WORK")" != "700" ]]; then
        cleanup_failed=1
    fi

    if [[ "$cleanup_failed" -ne 0 ]]; then
        echo "scanner process cleanup is uncertain; retained fixture at $WORK" >&2
        exit 1
    fi

    rm -rf -- "$WORK"
    exit "$command_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

require_owned_0600_file() {
    local file="$1"
    [[ -f "$file" && ! -L "$file" \
       && "$(/usr/bin/stat -f '%u' "$file")" == "$(/usr/bin/id -u)" \
       && "$(/usr/bin/stat -f '%Lp' "$file")" == "600" ]]
}

make_scenario() {
    local name="$1"
    SCENARIO_ROOT="$WORK/$name"
    STATE_ROOT="$SCENARIO_ROOT/state-root"
    mkdir -m 700 "$SCENARIO_ROOT"
    mkdir -m 700 "$STATE_ROOT"
}

create_role_xctestrun() {
    local label="$1"
    local role="$2"
    local state_root="$3"
    local result_file="${4:-}"
    local crash_site="${5:-}"
    local pid_file="${6:-}"
    ROLE_XCTESTRUN_INDEX=$((ROLE_XCTESTRUN_INDEX + 1))
    local destination="$(dirname "$BASE_XCTESTRUN")/ProjectScannerCore-process-${ROLE_XCTESTRUN_INDEX}-${label}.xctestrun"

    [[ -n "$BASE_XCTESTRUN" && -f "$BASE_XCTESTRUN" && ! -L "$BASE_XCTESTRUN" ]] || {
        echo "base process xctestrun is missing or unsafe" >&2
        return 1
    }
    [[ "$destination" == "$DERIVED_DATA/Build/Products/"ProjectScannerCore-process-[0-9]*-*.xctestrun \
       && ! -e "$destination" && ! -L "$destination" ]] || {
        echo "process xctestrun destination is unsafe" >&2
        return 1
    }

    /usr/bin/python3 -c '
import copy
import plistlib
import sys

source, destination, role, state_root, lock_helper, result_file, crash_site, pid_file = sys.argv[1:]
with open(source, "rb") as stream:
    original = plistlib.load(stream)

entries = [
    key for key, value in original.items()
    if isinstance(value, dict) and value.get("BlueprintName") == "ProjectScannerCoreTests"
]
if entries != ["ProjectScannerCoreTests"]:
    raise SystemExit("xctestrun did not contain exactly one ProjectScannerCoreTests entry")

injected = {
    "PROJECT_SCANNER_PROCESS_HARNESS_TOKEN": "PROJECT_SCANNER_PROCESS_HARNESS_V1_4B7E91C2",
    "PROJECT_SCANNER_PROCESS_ROLE": role,
    "PROJECT_SCANNER_PROCESS_STATE_ROOT": state_root,
    "PROJECT_SCANNER_LOCK_HELPER": lock_helper,
}
if result_file:
    injected["PROJECT_SCANNER_PROCESS_RESULT_FILE"] = result_file
if crash_site:
    injected["PROJECT_SCANNER_PROCESS_CRASH_SITE"] = crash_site
if pid_file:
    injected["PROJECT_SCANNER_PROCESS_PID_FILE"] = pid_file

environment = original["ProjectScannerCoreTests"].get("EnvironmentVariables")
if not isinstance(environment, dict) or any(
    key.startswith("PROJECT_SCANNER_PROCESS_") for key in environment
):
    raise SystemExit("xctestrun process environment was not closed")

expected = copy.deepcopy(original)
expected["ProjectScannerCoreTests"]["EnvironmentVariables"].update(injected)
with open(destination, "xb") as stream:
    plistlib.dump(expected, stream, fmt=plistlib.FMT_BINARY, sort_keys=False)
with open(destination, "rb") as stream:
    written = plistlib.load(stream)
if written != expected:
    raise SystemExit("xctestrun process environment verification failed")
' "$BASE_XCTESTRUN" "$destination" "$role" "$state_root" "$LOCK_HELPER" \
      "$result_file" "$crash_site" "$pid_file"
    /usr/bin/plutil -lint "$destination" >/dev/null
    [[ -f "$destination" && ! -L "$destination" \
       && "$(/usr/bin/stat -f '%u' "$destination")" == "$(/usr/bin/id -u)" ]] || {
        echo "process xctestrun was not safely created" >&2
        return 1
    }
    ROLE_XCTESTRUN="$destination"
}

run_test() {
    local selector="$1"
    local role="$2"
    local state_root="$3"
    local result_file="$4"
    local expected_marker="$5"
    RESULT_BUNDLE_INDEX=$((RESULT_BUNDLE_INDEX + 1))
    local result_bundle="$WORK/${RESULT_BUNDLE_INDEX}-${role}-$(basename "$result_file").xcresult"

    create_role_xctestrun "$role-$(basename "$result_file")" "$role" "$state_root" \
      "$result_file"
    [[ ! -e "$result_bundle" && ! -L "$result_bundle" ]] || {
        echo "process result bundle destination is unsafe" >&2
        exit 1
    }

    "$XCODEBUILD" -quiet \
      -xctestrun "$ROLE_XCTESTRUN" \
      -destination 'platform=macOS' \
      -parallel-testing-enabled NO \
      -maximum-parallel-testing-workers 1 \
      -resultBundlePath "$result_bundle" \
      -only-testing:"$selector" \
      test-without-building

    require_owned_0600_file "$result_file" || {
        echo "process-boundary result marker is missing or unsafe: $result_file" >&2
        exit 1
    }
    [[ "$(/bin/cat "$result_file")" == "$expected_marker" ]] || {
        echo "process-boundary result marker is malformed: $result_file" >&2
        exit 1
    }
}

pid_has_ancestor() {
    local child="$1"
    local expected="$2"
    local current="$child"
    local parent=""
    for _ in {1..32}; do
        parent="$(/bin/ps -o ppid= -p "$current" 2>/dev/null | /usr/bin/tr -d '[:space:]')"
        [[ "$parent" =~ ^[1-9][0-9]*$ ]] || return 1
        [[ "$parent" == "$expected" ]] && return 0
        [[ "$parent" == "1" || "$parent" == "$current" ]] && return 1
        current="$parent"
    done
    return 1
}

validate_stopped_victim() {
    local victim_pid="$1"
    local build_pid="$2"
    local owner=""
    local state=""
    local build_command=""
    local build_owner=""
    local build_parts=()

    is_live "$build_pid" || return 1
    is_live "$victim_pid" || return 1
    owner="$(/bin/ps -o uid= -p "$victim_pid" | /usr/bin/tr -d '[:space:]')"
    [[ "$owner" == "$(/usr/bin/id -u)" ]] || return 1
    state="$(/bin/ps -o state= -p "$victim_pid" | /usr/bin/tr -d '[:space:]')"
    [[ "$state" == T* ]] || return 1

    is_project_scanner_test_process "$victim_pid" || return 1

    build_command="$(/bin/ps -ww -o command= -p "$build_pid")"
    build_owner="$(/bin/ps -o uid= -p "$build_pid" | /usr/bin/tr -d '[:space:]')"
    [[ "$build_owner" == "$(/usr/bin/id -u)" ]] || return 1
    read -r -a build_parts <<< "$build_command"
    [[ "${build_parts[0]:-}" == "$XCODEBUILD" ]] || return 1
    [[ "$build_command" == *"$DERIVED_DATA"* ]] || return 1
    pid_has_ancestor "$victim_pid" "$build_pid"
}

wait_for_stopped_victim() {
    local pid_file="$1"
    local build_pid="$2"
    local victim_pid=""
    for _ in {1..300}; do
        if [[ -e "$pid_file" ]]; then
            require_owned_0600_file "$pid_file" || {
                echo "crash-victim PID file is unsafe: $pid_file" >&2
                return 1
            }
            victim_pid="$(/bin/cat "$pid_file")"
            [[ "$victim_pid" =~ ^[1-9][0-9]*$ ]] || {
                echo "crash-victim PID is malformed" >&2
                return 1
            }
            if validate_stopped_victim "$victim_pid" "$build_pid"; then
                VICTIM_PID="$victim_pid"
                TRACKED_TEST_PIDS+=("$victim_pid")
                return 0
            fi
        fi
        is_live "$build_pid" || {
            echo "crash-victim xcodebuild exited before a trusted stopped test appeared" >&2
            return 1
        }
        sleep 0.05
    done
    echo "timed out waiting for a trusted stopped crash victim" >&2
    return 1
}

wait_for_build_exit() {
    local build_pid="$1"
    local state=""
    for _ in {1..300}; do
        if ! is_live "$build_pid"; then return 0; fi
        state="$(/bin/ps -o state= -p "$build_pid" 2>/dev/null | /usr/bin/tr -d '[:space:]')"
        [[ "$state" == Z* ]] && return 0
        sleep 0.05
    done
    return 1
}

run_crash_victim() {
    local state_root="$1"
    local crash_site="$2"
    local pid_file="$3"
    local log_file="$4"
    local build_pid=""
    local build_exit=""

    create_role_xctestrun "crash-$crash_site" crash-victim "$state_root" \
      "" "$crash_site" "$pid_file"

    "$XCODEBUILD" -quiet \
      -xctestrun "$ROLE_XCTESTRUN" \
      -destination 'platform=macOS' \
      -parallel-testing-enabled NO \
      -maximum-parallel-testing-workers 1 \
      -only-testing:ProjectScannerCoreTests/StateProcessBoundaryTests/testCrashVictimStopsAtClosedPersistenceBoundary \
      test-without-building >"$log_file" 2>&1 &
    build_pid=$!
    TRACKED_BUILD_PIDS+=("$build_pid")

    if ! wait_for_stopped_victim "$pid_file" "$build_pid"; then
        echo "crash-victim process did not satisfy the closed identity checks" >&2
        return 1
    fi
    if ! kill -KILL "$VICTIM_PID"; then
        echo "failed to SIGKILL the trusted crash victim" >&2
        return 1
    fi
    wait_for_build_exit "$build_pid" || {
        echo "crash-victim xcodebuild did not exit after SIGKILL" >&2
        return 1
    }
    if wait "$build_pid"; then
        echo "crash-victim xcodebuild unexpectedly succeeded" >&2
        return 1
    else
        build_exit=$?
    fi
    [[ "$build_exit" -ne 0 ]] || return 1
    is_live "$VICTIM_PID" && {
        echo "crash-victim test process was not reaped" >&2
        return 1
    }
    return 0
}

XCRUN=/usr/bin/xcrun
XCODEBUILD="$($XCRUN --find xcodebuild)"
DEVELOPER_ROOT="$(cd "$(dirname "$XCODEBUILD")/../.." && pwd -P)"
EXPECTED_XCTEST="$DEVELOPER_ROOT/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/xctest"
[[ -x "$XCODEBUILD" && -x "$EXPECTED_XCTEST" ]] || {
    echo "required Xcode tools are unavailable" >&2
    exit 1
}

"$XCRUN" swiftc "$ROOT/script/fixtures/project_scanner_lock_holder.swift" \
  -o "$LOCK_HELPER"
chmod 700 "$LOCK_HELPER"
[[ -f "$LOCK_HELPER" && ! -L "$LOCK_HELPER" \
   && "$(/usr/bin/stat -f '%u' "$LOCK_HELPER")" == "$(/usr/bin/id -u)" \
   && "$(/usr/bin/stat -f '%Lp' "$LOCK_HELPER")" == "700" ]] || {
    echo "compiled lock helper failed ownership or mode validation" >&2
    exit 1
}

"$XCODEBUILD" -quiet \
  -project "$ROOT/Pearcleaner.xcodeproj" \
  -scheme ProjectScannerCore \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
  -disableAutomaticPackageResolution \
  -parallel-testing-enabled NO \
  -maximum-parallel-testing-workers 1 \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing

TEST_BUNDLE="$DERIVED_DATA/Build/Products/Debug/ProjectScannerCoreTests.xctest"
[[ -d "$TEST_BUNDLE" && ! -L "$TEST_BUNDLE" ]] || {
    echo "hostless ProjectScannerCoreTests bundle is missing" >&2
    exit 1
}
TEST_EXECUTABLE="$TEST_BUNDLE/Contents/MacOS/ProjectScannerCoreTests"
[[ -f "$TEST_EXECUTABLE" && ! -L "$TEST_EXECUTABLE" \
   && -x "$TEST_EXECUTABLE" \
   && "$(/usr/bin/stat -f '%u' "$TEST_EXECUTABLE")" == "$(/usr/bin/id -u)" ]] || {
    echo "hostless ProjectScannerCoreTests executable is missing or unsafe" >&2
    exit 1
}
TEST_EXECUTABLE_REAL="$(cd "$(dirname "$TEST_EXECUTABLE")" && pwd -P)/$(basename "$TEST_EXECUTABLE")"
[[ -f "$TEST_EXECUTABLE_REAL" && ! -L "$TEST_EXECUTABLE_REAL" ]] || {
    echo "hostless ProjectScannerCoreTests executable did not resolve safely" >&2
    exit 1
}

XCTESTRUN_PATHS="$WORK/xctestrun-paths"
/usr/bin/find "$DERIVED_DATA/Build/Products" -maxdepth 1 -type f \
  -name 'ProjectScannerCore_*.xctestrun' ! -name '*-process-*.xctestrun' \
  -print > "$XCTESTRUN_PATHS"
[[ "$(/usr/bin/wc -l < "$XCTESTRUN_PATHS" | /usr/bin/tr -d ' ')" == "1" ]] || {
    echo "process build did not produce exactly one base xctestrun" >&2
    exit 1
}
BASE_XCTESTRUN="$(/bin/cat "$XCTESTRUN_PATHS")"
[[ -f "$BASE_XCTESTRUN" && ! -L "$BASE_XCTESTRUN" \
   && "$(/usr/bin/stat -f '%u' "$BASE_XCTESTRUN")" == "$(/usr/bin/id -u)" ]] || {
    echo "process base xctestrun is missing or unsafe" >&2
    exit 1
}

make_scenario lock
run_test \
  ProjectScannerCoreTests/StateProcessBoundaryTests/testSeparateProcessLockContentionTimesOutCancelsAndRecoversAfterSIGKILL \
  lock "$STATE_ROOT" "$SCENARIO_ROOT/lock.result" LOCK_BOUNDARY_OK

for boundary in pre-rename post-rename; do
    make_scenario "$boundary"
    run_test \
      ProjectScannerCoreTests/StateProcessBoundaryTests/testPrepareCrashRecoveryFixture \
      prepare "$STATE_ROOT" "$SCENARIO_ROOT/prepare.result" PREPARE_BOUNDARY_OK

    if [[ "$boundary" == pre-rename ]]; then
        crash_site=syncStagingFile
        recovery_selector=ProjectScannerCoreTests/StateProcessBoundaryTests/testRecoverPreRenameCrash
        recovery_role=recover-pre-rename
        recovery_marker=RECOVER_PRE_RENAME_OK
    else
        crash_site=syncScannerAfterRename
        recovery_selector=ProjectScannerCoreTests/StateProcessBoundaryTests/testRecoverPostRenameCrash
        recovery_role=recover-post-rename
        recovery_marker=RECOVER_POST_RENAME_OK
    fi

    run_crash_victim \
      "$STATE_ROOT" "$crash_site" "$SCENARIO_ROOT/victim.pid" \
      "$SCENARIO_ROOT/victim-xcodebuild.log"
    run_test \
      "$recovery_selector" "$recovery_role" "$STATE_ROOT" \
      "$SCENARIO_ROOT/recovery.result" "$recovery_marker"
done

echo "project scanner persistence process boundaries passed"
