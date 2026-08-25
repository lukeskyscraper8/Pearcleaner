#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER="$ROOT/script/project_scanner_boundary_checks.sh"
ACTIVE_WORK=""

fail() {
    echo "git evidence boundary mutation test failed: $1" >&2
    exit 1
}

cleanup_active() {
    [[ -z "$ACTIVE_WORK" ]] && return 0
    if [[ "$ACTIVE_WORK" != /tmp/git-evidence-boundary.* \
        || ! -d "$ACTIVE_WORK" \
        || -L "$ACTIVE_WORK" ]]; then
        echo "refusing to clean unvalidated boundary fixture: $ACTIVE_WORK" >&2
        exit 1
    fi
    rm -rf "$ACTIVE_WORK"
    ACTIVE_WORK=""
}
trap cleanup_active EXIT

fresh_fixture() {
    cleanup_active
    ACTIVE_WORK="$(mktemp -d /tmp/git-evidence-boundary.XXXXXX)"
    [[ "$ACTIVE_WORK" == /tmp/git-evidence-boundary.* \
        && -d "$ACTIVE_WORK" \
        && ! -L "$ACTIVE_WORK" ]] \
        || fail "mktemp returned an invalid fixture"
    cp -R "$ROOT/ProjectScannerCore" "$ACTIVE_WORK/ProjectScannerCore"
    cp -R "$ROOT/ProjectScannerCoreTests" "$ACTIVE_WORK/ProjectScannerCoreTests"
    mkdir -p "$ACTIVE_WORK/Pearcleaner.xcodeproj"
    cp "$ROOT/Pearcleaner.xcodeproj/project.pbxproj" \
        "$ACTIVE_WORK/Pearcleaner.xcodeproj/project.pbxproj"
    mkdir -p "$ACTIVE_WORK/Pearcleaner/Logic"
    cp -R "$ROOT/Pearcleaner/Logic/ProjectScanner" \
        "$ACTIVE_WORK/Pearcleaner/Logic/ProjectScanner"
    cp "$ROOT/Pearcleaner/Logic/HelperToolManager.swift" \
        "$ACTIVE_WORK/Pearcleaner/Logic/HelperToolManager.swift"
}

run_checker() {
    PROJECT_SCANNER_BOUNDARY_ROOT="$ACTIVE_WORK" "$CHECKER" 2>&1
}

expect_rejection() {
    local case_name="$1"
    local expected_message="$2"
    local mutation="$3"
    local output

    fresh_fixture
    "$mutation"
    if output="$(run_checker)"; then
        echo "$output" >&2
        fail "expected rejection did not occur: $case_name"
    fi
    if [[ "$output" != *"project scanner boundary check failed: $expected_message"* ]]; then
        echo "$output" >&2
        fail "wrong rejection for $case_name; expected: $expected_message"
    fi
    cleanup_active
}

mutate_git_executor_outside_project_scanner() {
    printf '%s\n' \
        'import ProjectScannerCore' \
        'struct RogueGitAdapter: GitEvidenceExecuting {' \
        '    func execute(_ request: GitEvidenceExecutionRequest) async -> Result<GitEvidenceExecutionResponse, GitEvidenceExecutionFailure> {' \
        '        .success(GitEvidenceExecutionResponse())' \
        '    }' \
        '}' \
        > "$ACTIVE_WORK/Pearcleaner/Logic/RogueGitAdapter.swift"
}

mutate_git_evidence_shared_outside_project_scanner() {
    printf '%s\n' \
        'import GitEvidenceShared' \
        'enum RogueGitEvidenceSharedImport {}' \
        > "$ACTIVE_WORK/Pearcleaner/Logic/RogueGitEvidenceShared.swift"
}

mutate_git_xpc_client_outside_project_scanner() {
    printf '%s\n' \
        'import GitEvidenceShared' \
        'struct RogueGitXPCClient { let client = GitEvidenceXPCClient() }' \
        > "$ACTIVE_WORK/Pearcleaner/Logic/RogueGitXPCClient.swift"
}

mutate_git_executor_test_stub_outside_allowlist() {
    printf '%s\n' \
        'import XCTest' \
        '@testable import ProjectScannerCore' \
        'final class RogueGitExecutor: GitEvidenceExecuting, @unchecked Sendable {' \
        '    func execute(_ request: GitEvidenceExecutionRequest) async -> Result<GitEvidenceExecutionResponse, GitEvidenceExecutionFailure> {' \
        '        .success(GitEvidenceExecutionResponse())' \
        '    }' \
        '}' \
        > "$ACTIVE_WORK/ProjectScannerCoreTests/BoundaryMutationGitExecutorTests.swift"
}

mutate_core_nsxpc_connection() {
    append_core $'import Foundation\nfunc boundaryMutationNSXPC() { _ = NSXPCConnection() }'
}

append_core() {
    printf '%s\n' "$1" > "$ACTIVE_WORK/ProjectScannerCore/BoundaryMutation.swift"
}

fresh_fixture
baseline_output="$(run_checker)" || { echo "$baseline_output" >&2; fail "baseline fixture did not pass"; }
[[ "$baseline_output" == *"project scanner boundary checks passed"* ]] \
    || fail "baseline checker did not report success"
cleanup_active

expect_rejection \
    "GitEvidenceExecuting outside ProjectScanner" \
    "GitEvidenceExecuting adapter escaped Pearcleaner/Logic/ProjectScanner" \
    mutate_git_executor_outside_project_scanner

expect_rejection \
    "GitEvidenceShared outside ProjectScanner" \
    "GitEvidenceShared import escaped ProjectScanner adapter seam" \
    mutate_git_evidence_shared_outside_project_scanner

expect_rejection \
    "GitEvidenceXPCClient outside ProjectScanner" \
    "GitEvidenceShared import escaped ProjectScanner adapter seam" \
    mutate_git_xpc_client_outside_project_scanner

expect_rejection \
    "GitEvidenceExecuting test stub outside allowlist" \
    "GitEvidenceExecuting test stub escaped its exact allowlist" \
    mutate_git_executor_test_stub_outside_allowlist

expect_rejection \
    "NSXPCConnection in ProjectScannerCore" \
    "scanner core reaches a forbidden execution, network, or app service" \
    mutate_core_nsxpc_connection

echo "git evidence boundary mutation tests passed"
