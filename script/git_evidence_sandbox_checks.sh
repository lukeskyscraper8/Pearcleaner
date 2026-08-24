#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVIDENCE_ROOT="$ROOT/docs/superpowers/evidence/git-feasibility"

fail() {
    echo "git evidence sandbox checks failed: $1" >&2
    exit "${2:-1}"
}

require_tuple_manifest() {
    local tuple_dir="$1"
    local manifest_path="$tuple_dir/manifest.json"

    if [[ ! -f "$manifest_path" ]]; then
        fail "missing manifest for tuple directory: $tuple_dir" 1
    fi

    local overall_status
    overall_status="$(/usr/bin/python3 - "$manifest_path" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    manifest = json.load(handle)
print(manifest.get("overallStatus", "failed"))
PY
)"
    if [[ "$overall_status" != "passed" ]]; then
        fail "tuple manifest overallStatus is not passed: $tuple_dir" 1
    fi
}

assert_sandbox_log_denials() {
    local log_path="$1"

    if [[ ! -f "$log_path" ]]; then
        fail "missing sandbox log: $log_path" 1
    fi

    if /usr/bin/grep -Eq 'probe_open_errno=0|probe_write_errno=0|probe_exec_errno=0|probe_connect_errno=0' "$log_path"; then
        fail "sandbox log reports an unexpected successful access: $log_path" 1
    fi

    if /usr/bin/grep -Fq 'metadata_read_succeeded=true' "$log_path" \
        && /usr/bin/grep -Fq 'working_tree_read_denied=false' "$log_path" \
        && /usr/bin/grep -Fq 'runner_sandbox_enforcement_expected=true' "$log_path"; then
        fail "git transition log shows working-tree read success under enforced sandbox: $log_path" 1
    fi

    if /usr/bin/grep -Fq 'runner_sandbox_enforcement_expected=true' "$log_path" \
        && /usr/bin/grep -Fq 'allowed_kinds=' "$log_path"; then
        local allowed_kinds
        allowed_kinds="$(/usr/bin/grep -E '^allowed_kinds=' "$log_path" | tail -1 | cut -d= -f2-)"
        if [[ -n "$allowed_kinds" ]]; then
            fail "sandbox denial log reports allowed kinds under enforced sandbox: $log_path ($allowed_kinds)" 1
        fi
    fi
}

if [[ ! -d "$EVIDENCE_ROOT" ]]; then
    fail "evidence root not found: $EVIDENCE_ROOT" 1
fi

shopt -s nullglob
tuple_dirs=("$EVIDENCE_ROOT"/*/)
shopt -u nullglob

if [[ "${#tuple_dirs[@]}" -eq 0 ]]; then
    fail "no archived tuple evidence directories found under $EVIDENCE_ROOT" 1
fi

for tuple_dir in "${tuple_dirs[@]}"; do
    case "$(basename "$tuple_dir")" in
        _scratch_run|README.md)
            continue
            ;;
    esac

    if [[ ! -d "$tuple_dir" ]]; then
        continue
    fi

    echo "Checking tuple evidence: $tuple_dir"
    require_tuple_manifest "$tuple_dir"

    for scenario_log in \
        "$tuple_dir/logs/sandbox_denial.log" \
        "$tuple_dir/logs/git_transition.log"; do
        if [[ -f "$scenario_log" ]]; then
            assert_sandbox_log_denials "$scenario_log"
        fi
    done
done

echo "Git evidence sandbox checks passed."
