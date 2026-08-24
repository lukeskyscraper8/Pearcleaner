#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER="$ROOT/script/project_scanner_boundary_checks.sh"
ACTIVE_WORK=""

fail() {
    echo "project scanner boundary mutation test failed: $1" >&2
    exit 1
}

cleanup_active() {
    [[ -z "$ACTIVE_WORK" ]] && return 0
    if [[ "$ACTIVE_WORK" != /tmp/project-scanner-boundary.* \
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
    ACTIVE_WORK="$(mktemp -d /tmp/project-scanner-boundary.XXXXXX)"
    [[ "$ACTIVE_WORK" == /tmp/project-scanner-boundary.* \
        && -d "$ACTIVE_WORK" \
        && ! -L "$ACTIVE_WORK" ]] \
        || fail "mktemp returned an invalid fixture"
    cp -R "$ROOT/ProjectScannerCore" "$ACTIVE_WORK/ProjectScannerCore"
    cp -R "$ROOT/ProjectScannerCoreTests" "$ACTIVE_WORK/ProjectScannerCoreTests"
    mkdir -p "$ACTIVE_WORK/Pearcleaner.xcodeproj"
    cp "$ROOT/Pearcleaner.xcodeproj/project.pbxproj" \
        "$ACTIVE_WORK/Pearcleaner.xcodeproj/project.pbxproj"
}

replace_once() {
    local relative_path="$1"
    local old="$2"
    local new="$3"
    python3 - "$ACTIVE_WORK/$relative_path" "$old" "$new" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
old = sys.argv[2]
new = sys.argv[3]
text = path.read_text()
count = text.count(old)
if count != 1:
    raise SystemExit(f"mutation setup expected one occurrence in {path}, found {count}")
path.write_text(text.replace(old, new, 1))
PY
}

replace_in_pbx_object_once() {
    local object_id="$1"
    local old="$2"
    local new="$3"
    python3 - "$ACTIVE_WORK/Pearcleaner.xcodeproj/project.pbxproj" \
        "$object_id" "$old" "$new" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
identifier, old, new = sys.argv[2:]
text = path.read_text()
header = re.compile(
    rf"^\t\t{re.escape(identifier)}(?:[ \t]+/\*[^\n]*?\*/)?[ \t]*=[ \t]*\{{",
    re.MULTILINE,
)
matches = list(header.finditer(text))
if len(matches) != 1:
    raise SystemExit(f"mutation setup expected one PBX object {identifier}, found {len(matches)}")
start = matches[0].start()
index = matches[0].end()
depth = 1
while index < len(text) and depth:
    if text[index] == "{":
        depth += 1
    elif text[index] == "}":
        depth -= 1
    index += 1
if depth or index >= len(text) or text[index] != ";":
    raise SystemExit(f"mutation setup could not bound PBX object {identifier}")
end = index + 1
block = text[start:end]
count = block.count(old)
if count != 1:
    raise SystemExit(
        f"mutation setup expected one occurrence in PBX object {identifier}, found {count}"
    )
mutated = block.replace(old, new, 1)
path.write_text(text[:start] + mutated + text[end:])
PY
}

append_core() {
    printf '%s\n' "$1" > "$ACTIVE_WORK/ProjectScannerCore/BoundaryMutation.swift"
}

append_test() {
    printf '%s\n' "$1" > "$ACTIVE_WORK/ProjectScannerCoreTests/BoundaryMutationTests.swift"
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

mutate_core_package_dependency() {
    replace_once "Pearcleaner.xcodeproj/project.pbxproj" \
        $'\t\t\tname = ProjectScannerCore;\n\t\t\tpackageProductDependencies = (\n\t\t\t);' \
        $'\t\t\tname = ProjectScannerCore;\n\t\t\tpackageProductDependencies = (\n\t\t\t\tC707E2932EAF217200AAD817,\n\t\t\t);'
}

mutate_duplicate_pbx_object() {
    replace_once "Pearcleaner.xcodeproj/project.pbxproj" \
        $'\t\tA2000000000000000000000D /* PBXTargetDependency */ = {\n\t\t\tisa = PBXTargetDependency;' \
        $'\t\tA2000000000000000000000D /* PBXTargetDependency */ = {\n\t\t\tisa = PBXTargetDependency;\n\t\t};\n\t\tA2000000000000000000000D /* duplicate */ = {\n\t\t\tisa = PBXTargetDependency;'
}

mutate_core_test_dependency_dangling() {
    replace_once "Pearcleaner.xcodeproj/project.pbxproj" \
        "A2000000000000000000000D /* PBXTargetDependency */ = {" \
        "DEAD0000000000000000000D /* PBXTargetDependency */ = {"
}

mutate_core_test_dependency_wrong_kind() {
    replace_once "Pearcleaner.xcodeproj/project.pbxproj" \
        $'A2000000000000000000000D /* PBXTargetDependency */ = {\n\t\t\tisa = PBXTargetDependency;' \
        $'A2000000000000000000000D /* PBXTargetDependency */ = {\n\t\t\tisa = PBXBuildFile;'
}

mutate_core_test_dependency_proxy_dangling() {
    replace_once "Pearcleaner.xcodeproj/project.pbxproj" \
        "targetProxy = A2000000000000000000000B /* PBXContainerItemProxy */;" \
        "targetProxy = DEAD0000000000000000000B /* PBXContainerItemProxy */;"
}

mutate_core_test_direct_target_dangling() {
    replace_in_pbx_object_once A2000000000000000000000D \
        "target = A20000000000000000000015 /* ProjectScannerCore */;" \
        "target = DEAD00000000000000000015 /* missing */;"
}

mutate_core_test_direct_target_wrong_kind() {
    replace_in_pbx_object_once A2000000000000000000000D \
        "target = A20000000000000000000015 /* ProjectScannerCore */;" \
        "target = A20000000000000000000001 /* libProjectScannerCore.a */;"
}

mutate_core_test_proxy_wrong_kind() {
    replace_in_pbx_object_once A2000000000000000000000B \
        "isa = PBXContainerItemProxy;" "isa = PBXGroup;"
}

mutate_core_test_proxy_wrong_portal() {
    replace_in_pbx_object_once A2000000000000000000000B \
        "containerPortal = C77B8FF82AF18E2E009CC655 /* Project object */;" \
        "containerPortal = A20000000000000000000015 /* wrong portal */;"
}

mutate_core_test_proxy_wrong_type() {
    replace_in_pbx_object_once A2000000000000000000000B \
        "proxyType = 1;" "proxyType = 2;"
}

mutate_core_test_dependency_disagrees_with_proxy() {
    replace_in_pbx_object_once A2000000000000000000000B \
        "remoteGlobalIDString = A20000000000000000000015;" \
        "remoteGlobalIDString = C78121622BC892A000BE06BD;"
}

mutate_core_test_duplicate_dependency_reference() {
    replace_in_pbx_object_once A20000000000000000000016 \
        $'\t\t\tdependencies = (\n\t\t\t\tA2000000000000000000000D /* PBXTargetDependency */,\n\t\t\t);' \
        $'\t\t\tdependencies = (\n\t\t\t\tA2000000000000000000000D /* PBXTargetDependency */,\n\t\t\t\tA2000000000000000000000D /* duplicate */,\n\t\t\t);'
}

mutate_app_dependency_disagrees_with_proxy() {
    replace_once "Pearcleaner.xcodeproj/project.pbxproj" \
        $'A2000000000000000000000C /* PBXContainerItemProxy */ = {\n\t\t\tisa = PBXContainerItemProxy;\n\t\t\tcontainerPortal = C77B8FF82AF18E2E009CC655 /* Project object */;\n\t\t\tproxyType = 1;\n\t\t\tremoteGlobalIDString = A20000000000000000000015;' \
        $'A2000000000000000000000C /* PBXContainerItemProxy */ = {\n\t\t\tisa = PBXContainerItemProxy;\n\t\t\tcontainerPortal = C77B8FF82AF18E2E009CC655 /* Project object */;\n\t\t\tproxyType = 1;\n\t\t\tremoteGlobalIDString = C78121622BC892A000BE06BD;'
}

mutate_app_core_dependency_dangling() {
    replace_once "Pearcleaner.xcodeproj/project.pbxproj" \
        "A2000000000000000000000E /* PBXTargetDependency */ = {" \
        "DEAD0000000000000000000E /* PBXTargetDependency */ = {"
}

mutate_app_test_host_proxy_disagrees() {
    replace_once "Pearcleaner.xcodeproj/project.pbxproj" \
        "remoteGlobalIDString = C77B8FFF2AF18E2E009CC655;" \
        "remoteGlobalIDString = A20000000000000000000015;"
}

mutate_phase_dangling() {
    replace_once "Pearcleaner.xcodeproj/project.pbxproj" \
        "A20000000000000000000006 /* Frameworks */ = {" \
        "DEAD00000000000000000006 /* Frameworks */ = {"
}

mutate_phase_wrong_kind() {
    replace_once "Pearcleaner.xcodeproj/project.pbxproj" \
        $'A20000000000000000000006 /* Frameworks */ = {\n\t\t\tisa = PBXFrameworksBuildPhase;' \
        $'A20000000000000000000006 /* Frameworks */ = {\n\t\t\tisa = PBXResourcesBuildPhase;'
}

mutate_missing_framework_phase() {
    replace_in_pbx_object_once A20000000000000000000016 \
        $'\t\t\t\tA20000000000000000000006 /* Frameworks */,\n' ""
}

mutate_multiple_framework_phases() {
    replace_in_pbx_object_once A20000000000000000000016 \
        $'\t\t\t\tA20000000000000000000006 /* Frameworks */,\n' \
        $'\t\t\t\tA20000000000000000000006 /* Frameworks */,\n\t\t\t\tA20000000000000000000005 /* second Frameworks */,\n'
}

mutate_build_file_dangling() {
    replace_once "Pearcleaner.xcodeproj/project.pbxproj" \
        "A20000000000000000000009 /* libProjectScannerCore.a in Frameworks */ = {" \
        "DEAD00000000000000000009 /* libProjectScannerCore.a in Frameworks */ = {"
}

mutate_build_file_wrong_kind() {
    replace_once "Pearcleaner.xcodeproj/project.pbxproj" \
        $'A20000000000000000000009 /* libProjectScannerCore.a in Frameworks */ = {isa = PBXBuildFile;' \
        $'A20000000000000000000009 /* libProjectScannerCore.a in Frameworks */ = {isa = PBXFileReference;'
}

mutate_build_file_has_two_references() {
    replace_in_pbx_object_once A20000000000000000000009 \
        "fileRef = A20000000000000000000001 /* libProjectScannerCore.a */;" \
        "fileRef = A20000000000000000000001 /* libProjectScannerCore.a */; productRef = C707E2932EAF217200AAD817 /* Sparkle */;"
}

mutate_core_product_reference_dangling() {
    replace_once "Pearcleaner.xcodeproj/project.pbxproj" \
        $'A20000000000000000000009 /* libProjectScannerCore.a in Frameworks */ = {isa = PBXBuildFile; fileRef = A20000000000000000000001 /* libProjectScannerCore.a */; };' \
        $'A20000000000000000000009 /* libProjectScannerCore.a in Frameworks */ = {isa = PBXBuildFile; fileRef = DEAD00000000000000000001 /* missing */; };'
}

mutate_core_product_reference_wrong_kind() {
    replace_once "Pearcleaner.xcodeproj/project.pbxproj" \
        $'A20000000000000000000001 /* libProjectScannerCore.a */ = {isa = PBXFileReference;' \
        $'A20000000000000000000001 /* libProjectScannerCore.a */ = {isa = PBXGroup;'
}

mutate_core_target_product_reference_wrong_product() {
    replace_in_pbx_object_once A20000000000000000000015 \
        "productReference = A20000000000000000000001 /* libProjectScannerCore.a */;" \
        "productReference = A20000000000000000000002 /* ProjectScannerCoreTests.xctest */;"
}

mutate_core_product_identity() {
    replace_in_pbx_object_once A20000000000000000000001 \
        "path = libProjectScannerCore.a;" "path = ProjectScannerCore.framework;"
}

mutate_core_target_missing() {
    replace_in_pbx_object_once A20000000000000000000015 \
        "name = ProjectScannerCore;" "name = MissingScannerCore;"
}

mutate_core_test_link_missing() {
    replace_once "Pearcleaner.xcodeproj/project.pbxproj" \
        $'\t\t\t\tA20000000000000000000009 /* libProjectScannerCore.a in Frameworks */,\n' \
        ""
}

mutate_app_link_missing() {
    replace_once "Pearcleaner.xcodeproj/project.pbxproj" \
        $'\t\t\t\tA2000000000000000000000A /* libProjectScannerCore.a in Frameworks */,\n' \
        ""
}

mutate_app_test_link_missing() {
    replace_once "Pearcleaner.xcodeproj/project.pbxproj" \
        $'\t\t\t\tA20000000000000000000047 /* libProjectScannerCore.a in Frameworks */,\n' \
        ""
}

mutate_core_test_duplicate_link() {
    replace_once "Pearcleaner.xcodeproj/project.pbxproj" \
        "/* Begin PBXBuildFile section */" \
        $'/* Begin PBXBuildFile section */\n\t\tB21000000000000000000001 /* duplicate core link */ = {isa = PBXBuildFile; fileRef = A20000000000000000000001 /* libProjectScannerCore.a */; };'
    replace_in_pbx_object_once A20000000000000000000006 \
        $'\t\t\t\tA20000000000000000000009 /* libProjectScannerCore.a in Frameworks */,\n' \
        $'\t\t\t\tA20000000000000000000009 /* libProjectScannerCore.a in Frameworks */,\n\t\t\t\tB21000000000000000000001 /* duplicate core link */,\n'
}

mutate_helper_links_core() {
    replace_once "Pearcleaner.xcodeproj/project.pbxproj" \
        "/* Begin PBXBuildFile section */" \
        $'/* Begin PBXBuildFile section */\n\t\tB20000000000000000000001 /* libProjectScannerCore.a in Helper Frameworks */ = {isa = PBXBuildFile; fileRef = A20000000000000000000001 /* libProjectScannerCore.a */; };'
    replace_once "Pearcleaner.xcodeproj/project.pbxproj" \
        $'\t\t\t\tC7FBD9DF2DAD66D500151934 /* AlinFoundation in Frameworks */,\n' \
        $'\t\t\t\tC7FBD9DF2DAD66D500151934 /* AlinFoundation in Frameworks */,\n\t\t\t\tB20000000000000000000001 /* libProjectScannerCore.a in Helper Frameworks */,\n'
}

mutate_sentinel_links_core() {
    replace_once "Pearcleaner.xcodeproj/project.pbxproj" \
        "/* Begin PBXBuildFile section */" \
        $'/* Begin PBXBuildFile section */\n\t\tB22000000000000000000001 /* libProjectScannerCore.a in Sentinel Frameworks */ = {isa = PBXBuildFile; fileRef = A20000000000000000000001 /* libProjectScannerCore.a */; };'
    replace_in_pbx_object_once C728930C2AFD51EA00C8C1CD \
        $'\t\t\tfiles = (\n\t\t\t);' \
        $'\t\t\tfiles = (\n\t\t\t\tB22000000000000000000001 /* libProjectScannerCore.a in Sentinel Frameworks */,\n\t\t\t);'
}

mutate_finder_links_core() {
    replace_once "Pearcleaner.xcodeproj/project.pbxproj" \
        "/* Begin PBXBuildFile section */" \
        $'/* Begin PBXBuildFile section */\n\t\tB23000000000000000000001 /* libProjectScannerCore.a in Finder Frameworks */ = {isa = PBXBuildFile; fileRef = A20000000000000000000001 /* libProjectScannerCore.a */; };'
    replace_in_pbx_object_once C78121602BC892A000BE06BD \
        $'\t\t\tfiles = (\n\t\t\t);' \
        $'\t\t\tfiles = (\n\t\t\t\tB23000000000000000000001 /* libProjectScannerCore.a in Finder Frameworks */,\n\t\t\t);'
}

mutate_non_scanner_dependency() {
    replace_in_pbx_object_once C728930E2AFD51EA00C8C1CD \
        $'\t\t\tdependencies = (\n\t\t\t);' \
        $'\t\t\tdependencies = (\n\t\t\t\tA2000000000000000000000D /* PBXTargetDependency */,\n\t\t\t);'
}

mutate_forbidden_core_import() { append_core $'import AppKit\nfunc boundaryMutation() {}'; }
mutate_unlisted_core_import() { append_core $'@_implementationOnly import Dispatch\nfunc boundaryMutationDispatch() {}'; }
mutate_forbidden_test_import() { append_test $'import SwiftUI\nimport XCTest\n@testable import ProjectScannerCore'; }
mutate_test_imports_app() { append_test $'import XCTest\n@testable import Pearcleaner'; }
mutate_raw_project_access() { append_core $'import Darwin\nfunc boundaryMutation(_ fd: Int32) { _ = openat(fd, "x", O_RDONLY) }'; }
mutate_qualified_raw_project_access() { append_core $'import Darwin\nfunc boundaryMutationQualified(_ fd: Int32) { _ = Darwin.openat(fd, "x", O_RDONLY) }'; }
mutate_raw_test_access() { append_test $'import Darwin\nimport XCTest\n@testable import ProjectScannerCore\nfunc boundaryMutationRawTest(_ fd: Int32) { _ = Darwin.openat(fd, "x", O_RDONLY) }'; }
mutate_remove_all_test_core_imports() {
    python3 - "$ACTIVE_WORK/ProjectScannerCoreTests" <<'PY'
import pathlib
import re
import sys
root = pathlib.Path(sys.argv[1])
count = 0
for path in root.rglob("*.swift"):
    text = path.read_text()
    mutated, replacements = re.subn(
        r"(?m)^\s*(?:@testable\s+)?import\s+ProjectScannerCore\s*\n",
        "",
        text,
    )
    if replacements:
        path.write_text(mutated)
        count += replacements
if count == 0:
    raise SystemExit("mutation setup found no ProjectScannerCore test imports")
PY
}
mutate_root_broker_call() { append_core $'func boundaryMutation(_ root: RootCapability) throws { _ = try root.makeFileBroker(limits: .defaults) }'; }
mutate_traversal_call() { append_core $'func boundaryMutation(_ broker: FileBroker) async throws { _ = try await broker.makeTraversal() }'; }
mutate_private_state_authority() {
    printf '%s\n' $'\nfunc boundaryMutationPrivateState(_ fd: Int32) { _ = Darwin.fsync(fd) }' \
        >> "$ACTIVE_WORK/ProjectScannerCore/Persistence/ProjectStateStore.swift"
}
mutate_containment_write_flag() { printf '%s\n' $'import Darwin\nlet boundaryMutation = O_CREAT' > "$ACTIVE_WORK/ProjectScannerCore/Containment/BoundaryMutation.swift"; }
mutate_containment_raw_write() {
    printf '%s\n' $'\nfunc boundaryMutationWrite(_ fd: Int32, _ byte: UInt8) {\n    var byte = byte\n    _ = Darwin.write(fd, &byte, 1)\n}' \
        >> "$ACTIVE_WORK/ProjectScannerCore/Containment/ProjectFileBroker.swift"
}
mutate_missing_nonblock() {
    replace_once "ProjectScannerCore/Persistence/AtomicStateFile.swift" \
        $'flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,\n                mode: 0, site: .openStateFileForRead' \
        $'flags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC,\n                mode: 0, site: .openStateFileForRead'
}
mutate_containment_missing_nonblock() {
    replace_once "ProjectScannerCore/Containment/ProjectFileBroker.swift" \
        $'flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,\n                accounting: descriptorAccounting,\n                descriptorLifetime: descriptorLifetime' \
        $'flags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC,\n                accounting: descriptorAccounting,\n                descriptorLifetime: descriptorLifetime'
}
mutate_forbidden_execution() { append_core $'import Foundation\nfunc boundaryMutation() { _ = Process() }'; }
mutate_forbidden_network() { append_core $'import Darwin\nfunc boundaryMutation() { _ = socket(AF_INET, SOCK_STREAM.rawValue, 0) }'; }
mutate_forbidden_preferences() { append_core $'import Foundation\nfunc boundaryMutation() { _ = UserDefaults.standard }'; }
mutate_app_group_access() { append_core $'import Foundation\nfunc boundaryMutationAppGroup() { _ = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.invalid") }'; }
mutate_forbidden_logging() { append_core $'import Foundation\nfunc boundaryMutation() { print("raw") }'; }
mutate_default_limit() {
    replace_once "ProjectScannerCore/Model/ScanLimits.swift" "generalFiles: 100_000," "generalFiles: 99_999,"
}
mutate_hard_ceiling() {
    replace_once "ProjectScannerCore/Model/ScanLimits.swift" "generalFiles: 500_000," "generalFiles: 499_999,"
}
mutate_scan_limits_constructor() {
    replace_once "ProjectScannerCore/Model/ScanLimits.swift" \
        "    fileprivate init(" "    init("
    append_core $'func boundaryMutationScanLimits(_ value: ScanLimits) -> ScanLimits {\n    ScanLimits(\n        generalFiles: value.generalFiles, secretFileBytes: value.secretFileBytes,\n        lockfileBytes: value.lockfileBytes, manifestBytes: value.manifestBytes,\n        installedManifests: value.installedManifests, directories: value.directories,\n        directoryEntries: value.directoryEntries, traversalDepth: value.traversalDepth,\n        relativePathBytes: value.relativePathBytes, structuredDataDepth: value.structuredDataDepth,\n        parsedScalarBytes: value.parsedScalarBytes, dependencyNodesPerLockfile: value.dependencyNodesPerLockfile,\n        dependencyNodesPerSession: value.dependencyNodesPerSession, findingsPerFile: value.findingsPerFile,\n        findingsPerSession: value.findingsPerSession, inputBytes: value.inputBytes,\n        wallTimeMilliseconds: value.wallTimeMilliseconds, activeWorkers: value.activeWorkers,\n        activeProjectScans: value.activeProjectScans, gitMetadataDescriptors: value.gitMetadataDescriptors,\n        gitDescriptorReserve: value.gitDescriptorReserve, gitOperationMilliseconds: value.gitOperationMilliseconds,\n        gitOutputBytes: value.gitOutputBytes, retainedInputBytes: value.retainedInputBytes,\n        parserArenaBytes: value.parserArenaBytes, findingModelBytes: value.findingModelBytes,\n        rssSoftBytes: value.rssSoftBytes, rssHardBytes: value.rssHardBytes,\n        maximumLinkHops: value.maximumLinkHops, progressIntervalMilliseconds: value.progressIntervalMilliseconds,\n        cancellationLatencyMilliseconds: value.cancellationLatencyMilliseconds\n    )\n}'
}
mutate_hard_ceilings_use() { append_core $'func boundaryMutation() { _ = ScanLimits.hardCeilings }'; }
mutate_input_budget_constructor() { append_core $'func boundaryMutation() { _ = InputBudget(limits: .defaults) }'; }
mutate_input_budget_test_constructor() { append_test $'import XCTest\n@testable import ProjectScannerCore\nfunc boundaryMutationBudgetTest() { _ = InputBudget(limits: .defaults) }'; }
mutate_replacement_budget_constructor() {
    replace_once "ProjectScannerCore/Containment/ProjectFileBroker.swift" \
        "    init(limits: ScanLimits) {" \
        $'    convenience init(maximumInputBytes: UInt64, maximumRetainedBytes: UInt64) {\n        self.init(limits: .defaults)\n    }\n\n    init(limits: ScanLimits) {'
}
mutate_key_coordinator_injection() { append_core $'func boundaryMutation(_ s: any ProjectKeyMaterialStoring, _ r: any SecureRandomGenerating, _ u: any UUIDGenerating) { _ = ProjectKeyCoordinator(store: s, random: r, uuid: u) }'; }
mutate_key_coordinator_test_injection() { append_test $'import XCTest\n@testable import ProjectScannerCore\nfunc boundaryMutationCoordinatorTest(_ s: any ProjectKeyMaterialStoring, _ r: any SecureRandomGenerating, _ u: any UUIDGenerating) { _ = ProjectKeyCoordinator(store: s, random: r, uuid: u) }'; }
mutate_coverage_terminal_setter() {
    replace_once "ProjectScannerCore/Coverage/CoverageLedger.swift" \
        "    public func begin(_ detector: DetectorID) throws -> CoverageTransactionID {" \
        $'    public func close(_ transaction: CoverageTransactionID, as state: DetectorTerminalState) throws {\n        fatalError("boundary mutation")\n    }\n\n    public func begin(_ detector: DetectorID) throws -> CoverageTransactionID {'
}
mutate_detector_disable() {
    replace_once "ProjectScannerCore/Coverage/CoverageLedger.swift" \
        "    private init(detectors: [DetectorID]) {" \
        "    public init(detectors: [DetectorID]) {"
}
mutate_redacted_constructor() {
    replace_once "ProjectScannerCore/Privacy/PrivacyRedactor.swift" \
        "    fileprivate init(validatedText: String) {" \
        "    public init(validatedText: String) {"
}
mutate_session_raw_data() {
    replace_once "ProjectScannerCore/Session/SessionStore.swift" \
        "    public func append(_ finding: SessionFinding) -> SessionAppendResult {" \
        $'    public func append(rawData: Data) -> SessionAppendResult {\n        fatalError("boundary mutation")\n    }\n\n    public func append(_ finding: SessionFinding) -> SessionAppendResult {'
}
mutate_session_raw_string() {
    replace_once "ProjectScannerCore/Session/SessionStore.swift" \
        "    public func append(_ finding: SessionFinding) -> SessionAppendResult {" \
        $'    public func append(rawString: String) -> SessionAppendResult {\n        fatalError("boundary mutation")\n    }\n\n    public func append(_ finding: SessionFinding) -> SessionAppendResult {'
}
mutate_session_raw_property() {
    replace_once "ProjectScannerCore/Session/SessionStore.swift" \
        "    public func append(_ finding: SessionFinding) -> SessionAppendResult {" \
        $'    public var rawSource: Data { Data() }\n\n    public func append(_ finding: SessionFinding) -> SessionAppendResult {'
}
mutate_suppression_record_codable() { append_core $'extension SuppressionRecord: Codable {\n    public init(from decoder: any Decoder) throws { fatalError("boundary mutation") }\n    public func encode(to encoder: any Encoder) throws {}\n}'; }
mutate_bookmark_codable() { append_core $'extension ProjectBookmark: Codable {\n    public init(from decoder: any Decoder) throws { fatalError("boundary mutation") }\n    public func encode(to encoder: any Encoder) throws {}\n}'; }
mutate_fingerprint_codable() { append_core $'extension SuppressionFingerprint: Codable {\n    public init(from decoder: any Decoder) throws { fatalError("boundary mutation") }\n    public func encode(to encoder: any Encoder) throws {}\n}'; }
mutate_key_material_encodable() { append_core $'extension ProjectKeyMaterial: Encodable {\n    public func encode(to encoder: any Encoder) throws {}\n}'; }
mutate_key_material_string_convertible() { append_core $'extension ProjectKeyMaterial: CustomStringConvertible {\n    public var description: String { "boundary mutation" }\n}'; }
mutate_bookmark_string_convertible() { append_core $'extension ProjectBookmark: CustomStringConvertible {\n    public var description: String { "boundary mutation" }\n}'; }
mutate_redacted_string_convertible() { append_core $'extension RedactedSourceField: CustomStringConvertible {\n    public var description: String { text }\n}'; }
mutate_key_material_raw_storage() {
    replace_once "ProjectScannerCore/Privacy/Fingerprint.swift" \
        "fileprivate let key: SymmetricKey" "public let key: SymmetricKey"
}
mutate_key_material_raw_initializer() {
    replace_once "ProjectScannerCore/Privacy/Fingerprint.swift" \
        "    init(generation: UUID, keyBytes: Data) throws {" \
        "    public init(generation: UUID, keyBytes: Data) throws {"
}
mutate_key_material_raw_accessor() {
    replace_once "ProjectScannerCore/Privacy/Fingerprint.swift" \
        "    public func secureStorageRecord() -> Data {" \
        $'    public func exportKeyBytes() -> Data { secureStorageRecord() }\n\n    public func secureStorageRecord() -> Data {'
}
mutate_bookmark_raw_storage() {
    replace_once "ProjectScannerCore/Persistence/ProjectBookmark.swift" \
        "fileprivate let storage: Data" "public let storage: Data"
}
mutate_fingerprint_raw_storage() {
    replace_once "ProjectScannerCore/Privacy/Fingerprint.swift" \
        "fileprivate let bytes: Data" "public let bytes: Data"
}
mutate_bookmark_raw_initializer() {
    replace_once "ProjectScannerCore/Persistence/ProjectBookmark.swift" \
        "    fileprivate init(validatedStorage: Data) throws {" \
        "    public init(validatedStorage: Data) throws {"
}
mutate_fingerprint_raw_initializer() {
    replace_once "ProjectScannerCore/Privacy/Fingerprint.swift" \
        "    fileprivate init(validatedBytes: Data) throws {" \
        "    public init(validatedBytes: Data) throws {"
}
mutate_key_lease_material() {
    replace_once "ProjectScannerCore/Persistence/ProjectKeyCoordinator.swift" \
        "    let material: ProjectKeyMaterial" "    public let material: ProjectKeyMaterial"
}
mutate_key_lease_accessor() {
    replace_once "ProjectScannerCore/Persistence/ProjectKeyCoordinator.swift" \
        "    public let persistence: Persistence" \
        $'    public let persistence: Persistence\n\n    public func duplicateMaterial() -> ProjectKeyMaterial { material }'
}
mutate_root_raw_descriptor() {
    replace_once "ProjectScannerCore/Containment/ProjectFileBroker.swift" \
        "    public func close() {" \
        $'    public func duplicateDescriptor() -> Int32 { 0 }\n\n    public func close() {'
}
mutate_bookmark_bridge_call() { append_core $'func boundaryMutationBookmarkBridge(_ b: ProjectBookmark) { _ = ProjectBookmarkPersistence.encode(b) }'; }
mutate_fingerprint_bridge_call() { append_core $'func boundaryMutationFingerprintBridge(_ f: SuppressionFingerprint) { _ = SuppressionFingerprintPersistence.encode(f) }'; }
mutate_generic_fingerprint_identity() { append_core $'import Foundation\nfunc suppressionIdentity(_ bytes: Data) -> Data { bytes }'; }
mutate_generic_fingerprint_encoder() { append_core $'struct FingerprintEncoder {}'; }
mutate_framed_mac_call() { append_core $'func boundaryMutationFramedMAC(_ key: ProjectKeyMaterial) throws {\n    try FramedMACTestSupport.finalizeWithTooFewFields(keyMaterial: key)\n}'; }
mutate_rfc_helper_call() { append_core $'import Foundation\nfunc boundaryMutationRFC(_ key: Data) throws {\n    _ = try hmacSHA256(message: Data(), key: key)\n}'; }
mutate_fingerprint_accumulator() {
    replace_once "ProjectScannerCore/Privacy/Fingerprint.swift" \
        "private var hasTooManyFields: Bool" \
        $'private var hasTooManyFields: Bool\n    private var fullFrameAccumulator = Data()'
}
mutate_borrowed_field_copy() {
    replace_once "ProjectScannerCore/Privacy/Fingerprint.swift" \
        "        let view = BorrowedHMACDataView(bytes)" \
        "        let view = Data(bytes)"
}
mutate_redactor_data_copy() {
    printf '%s\n' $'\nfunc boundaryMutationRedactorCopy(_ source: Data) {\n    _ = source.subdata(in: 0..<source.count)\n}' \
        >> "$ACTIVE_WORK/ProjectScannerCore/Privacy/PrivacyRedactor.swift"
}
mutate_redactor_string_copy() {
    printf '%s\n' $'\nfunc boundaryMutationRedactorString(_ source: Data) {\n    _ = String(data: source, encoding: .utf8)\n}' \
        >> "$ACTIVE_WORK/ProjectScannerCore/Privacy/PrivacyRedactor.swift"
}
mutate_redactor_slice_copy() {
    printf '%s\n' $'\nfunc boundaryMutationRedactorSlice(_ utf8: [UInt8]) {\n    _ = Data(utf8[...])\n}' \
        >> "$ACTIVE_WORK/ProjectScannerCore/Privacy/PrivacyRedactor.swift"
}
mutate_file_broker_test_control_use() { append_core $'func boundaryMutation(_ c: FileBrokerTestControl) {}'; }
mutate_content_broker_test_control_use() { append_core $'func boundaryMutation(_ c: ContentBrokerTestControl) {}'; }
mutate_state_operations_use() { append_core $'func boundaryMutation(_ o: any StateFileSystemOperations) {}'; }
mutate_backup_operations_use() { append_core $'func boundaryMutation(_ o: any BackupExclusionOperations) {}'; }
mutate_file_broker_test_control_wrong_test() { append_test $'import XCTest\n@testable import ProjectScannerCore\nfunc boundaryMutationControlTest(_ c: FileBrokerTestControl) {}'; }
mutate_state_operations_wrong_test() { append_test $'import XCTest\n@testable import ProjectScannerCore\nfunc boundaryMutationStateTest(_ o: any StateFileSystemOperations) {}'; }

fresh_fixture
baseline_output="$(run_checker)" || { echo "$baseline_output" >&2; fail "baseline fixture did not pass"; }
[[ "$baseline_output" == *"project scanner boundary checks passed"* ]] \
    || fail "baseline checker did not report success"
cleanup_active

fresh_fixture
if mutation_products_output="$(PROJECT_SCANNER_BOUNDARY_ROOT="$ACTIVE_WORK" \
    "$CHECKER" "$ACTIVE_WORK" 2>&1)"; then
    echo "$mutation_products_output" >&2
    fail "mutation-root plus products unexpectedly passed"
fi
[[ "$mutation_products_output" == *"project scanner boundary check failed: mutation-root mode does not accept built products"* ]] \
    || { echo "$mutation_products_output" >&2; fail "mutation-root plus products failed for the wrong reason"; }
cleanup_active

# Closed control: before accepting any new-invariant RED, prove the checker is
# actually scanning the copied mutation root by exercising a pre-existing rule.
expect_rejection "mutation-root routing control" "scanner core imports a forbidden module" mutate_forbidden_core_import

expect_rejection "core package dependency" "ProjectScannerCore packageProductDependencies must be empty" mutate_core_package_dependency
expect_rejection "duplicate PBX object" "PBX object IDs must resolve exactly once" mutate_duplicate_pbx_object
expect_rejection "core-test dangling dependency" "ProjectScannerCoreTests dependency graph is invalid" mutate_core_test_dependency_dangling
expect_rejection "core-test wrong dependency kind" "ProjectScannerCoreTests dependency graph is invalid" mutate_core_test_dependency_wrong_kind
expect_rejection "core-test dangling proxy" "ProjectScannerCoreTests dependency graph is invalid" mutate_core_test_dependency_proxy_dangling
expect_rejection "core-test dangling direct target" "ProjectScannerCoreTests dependency graph is invalid" mutate_core_test_direct_target_dangling
expect_rejection "core-test wrong direct-target kind" "ProjectScannerCoreTests dependency graph is invalid" mutate_core_test_direct_target_wrong_kind
expect_rejection "core-test wrong proxy kind" "ProjectScannerCoreTests dependency graph is invalid" mutate_core_test_proxy_wrong_kind
expect_rejection "core-test wrong proxy portal" "ProjectScannerCoreTests dependency graph is invalid" mutate_core_test_proxy_wrong_portal
expect_rejection "core-test wrong proxy type" "ProjectScannerCoreTests dependency graph is invalid" mutate_core_test_proxy_wrong_type
expect_rejection "core-test direct/proxy disagreement" "ProjectScannerCoreTests dependency graph is invalid" mutate_core_test_dependency_disagrees_with_proxy
expect_rejection "core-test duplicate dependency reference" "ProjectScannerCoreTests dependency graph is invalid" mutate_core_test_duplicate_dependency_reference
expect_rejection "app direct/proxy disagreement" "Pearcleaner dependency graph is invalid" mutate_app_dependency_disagrees_with_proxy
expect_rejection "app dangling core dependency" "Pearcleaner dependency graph is invalid" mutate_app_core_dependency_dangling
expect_rejection "app-test host proxy disagreement" "PearcleanerTests host dependency graph is invalid" mutate_app_test_host_proxy_disagrees
expect_rejection "dangling framework phase" "target build phase graph is invalid" mutate_phase_dangling
expect_rejection "wrong framework phase kind" "target build phase graph is invalid" mutate_phase_wrong_kind
expect_rejection "missing frameworks phase" "target build phase graph is invalid" mutate_missing_framework_phase
expect_rejection "multiple frameworks phases" "target build phase graph is invalid" mutate_multiple_framework_phases
expect_rejection "dangling core build file" "target framework graph is invalid" mutate_build_file_dangling
expect_rejection "wrong core build-file kind" "target framework graph is invalid" mutate_build_file_wrong_kind
expect_rejection "build file with two references" "target framework graph is invalid" mutate_build_file_has_two_references
expect_rejection "dangling core product reference" "target framework graph is invalid" mutate_core_product_reference_dangling
expect_rejection "wrong core product-reference kind" "target framework graph is invalid" mutate_core_product_reference_wrong_kind
expect_rejection "core target wrong product reference" "target framework graph is invalid" mutate_core_target_product_reference_wrong_product
expect_rejection "core product identity" "target framework graph is invalid" mutate_core_product_identity
expect_rejection "missing named core target" "ProjectScannerCore target must resolve exactly once" mutate_core_target_missing
expect_rejection "missing core-test core link" "ProjectScannerCoreTests must link ProjectScannerCore exactly once" mutate_core_test_link_missing
expect_rejection "missing app core link" "Pearcleaner must link ProjectScannerCore exactly once" mutate_app_link_missing
expect_rejection "missing app-test core link" "PearcleanerTests must link ProjectScannerCore exactly once" mutate_app_test_link_missing
expect_rejection "duplicate core-test core link" "ProjectScannerCoreTests must link ProjectScannerCore exactly once" mutate_core_test_duplicate_link
expect_rejection "helper core link" "non-scanner target links or depends on ProjectScannerCore" mutate_helper_links_core
expect_rejection "sentinel core link" "non-scanner target links or depends on ProjectScannerCore" mutate_sentinel_links_core
expect_rejection "Finder core link" "non-scanner target links or depends on ProjectScannerCore" mutate_finder_links_core
expect_rejection "non-scanner core dependency" "non-scanner target links or depends on ProjectScannerCore" mutate_non_scanner_dependency
expect_rejection "unlisted annotated core import" "scanner core imports a forbidden module" mutate_unlisted_core_import
expect_rejection "forbidden test import" "scanner tests import a forbidden module" mutate_forbidden_test_import
expect_rejection "app import from core tests" "scanner tests import Pearcleaner" mutate_test_imports_app
expect_rejection "all test core imports removed" "scanner tests do not import ProjectScannerCore" mutate_remove_all_test_core_imports
expect_rejection "raw project access outside broker" "raw project filesystem authority escaped ProjectFileBroker.swift" mutate_raw_project_access
expect_rejection "qualified raw project access outside broker" "raw project filesystem authority escaped ProjectFileBroker.swift" mutate_qualified_raw_project_access
expect_rejection "raw filesystem access from wrong test" "raw filesystem test authority escaped its exact allowlist" mutate_raw_test_access
expect_rejection "unauthorized root broker call" "RootCapability.makeFileBroker has an unauthorized production call site" mutate_root_broker_call
expect_rejection "unauthorized traversal call" "FileBroker.makeTraversal has an unauthorized production call site" mutate_traversal_call
expect_rejection "private-state authority outside allowlist" "private-state authority escaped its exact allowlist" mutate_private_state_authority
expect_rejection "containment write flag" "scanner containment code contains a write-capable open flag" mutate_containment_write_flag
expect_rejection "containment raw write" "scanner containment code contains a write-capable open flag" mutate_containment_raw_write
expect_rejection "speculative open without O_NONBLOCK" "speculative file open is missing O_NONBLOCK" mutate_missing_nonblock
expect_rejection "containment speculative open without O_NONBLOCK" "speculative file open is missing O_NONBLOCK" mutate_containment_missing_nonblock
expect_rejection "forbidden execution" "scanner core reaches a forbidden execution, network, or app service" mutate_forbidden_execution
expect_rejection "forbidden networking" "scanner core reaches a Darwin networking primitive" mutate_forbidden_network
expect_rejection "forbidden preferences" "scanner core reaches shared preferences or arbitrary-string logging" mutate_forbidden_preferences
expect_rejection "forbidden app-group access" "scanner core reaches shared preferences or arbitrary-string logging" mutate_app_group_access
expect_rejection "forbidden logging" "scanner core reaches a generic logging API" mutate_forbidden_logging
expect_rejection "changed default limits" "ScanLimits defaults changed from the approved values" mutate_default_limit
expect_rejection "changed hard ceilings" "ScanLimits hard ceilings changed from the approved values" mutate_hard_ceiling
expect_rejection "ScanLimits construction" "ScanLimits construction escaped ScanLimits.swift" mutate_scan_limits_constructor
expect_rejection "hard-ceiling use" "ScanLimits.hardCeilings escaped its exact allowlist" mutate_hard_ceilings_use
expect_rejection "InputBudget construction" "InputBudget construction escaped its exact allowlist" mutate_input_budget_constructor
expect_rejection "InputBudget construction from wrong test" "InputBudget construction escaped its exact allowlist" mutate_input_budget_test_constructor
expect_rejection "replacement budget constructor" "replacement InputBudget constructor is forbidden" mutate_replacement_budget_constructor
expect_rejection "coordinator injection" "ProjectKeyCoordinator injection escaped its exact allowlist" mutate_key_coordinator_injection
expect_rejection "coordinator injection from wrong test" "ProjectKeyCoordinator injection escaped its exact allowlist" mutate_key_coordinator_test_injection
expect_rejection "coverage terminal setter" "coverage terminal state became caller-settable" mutate_coverage_terminal_setter
expect_rejection "detector disable" "coverage detector disabling escaped its exact allowlist" mutate_detector_disable
expect_rejection "redacted field construction" "RedactedSourceField construction escaped PrivacyRedactor.swift" mutate_redacted_constructor
expect_rejection "session raw Data input" "session API accepts raw source data" mutate_session_raw_data
expect_rejection "session raw String input" "session API accepts raw source data" mutate_session_raw_string
expect_rejection "session raw property" "session API accepts raw source data" mutate_session_raw_property
expect_rejection "SuppressionRecord Codable" "opaque persisted type became Codable" mutate_suppression_record_codable
expect_rejection "ProjectBookmark Codable" "opaque persisted type became Codable" mutate_bookmark_codable
expect_rejection "SuppressionFingerprint Codable" "opaque persisted type became Codable" mutate_fingerprint_codable
expect_rejection "ProjectKeyMaterial Encodable" "opaque persisted type became Codable" mutate_key_material_encodable
expect_rejection "ProjectKeyMaterial string conversion" "opaque persisted type became string-convertible" mutate_key_material_string_convertible
expect_rejection "ProjectBookmark string conversion" "opaque persisted type became string-convertible" mutate_bookmark_string_convertible
expect_rejection "RedactedSourceField string conversion" "opaque persisted type became string-convertible" mutate_redacted_string_convertible
expect_rejection "key material raw storage" "ProjectKeyMaterial exposes raw key material" mutate_key_material_raw_storage
expect_rejection "key material raw initializer" "ProjectKeyMaterial exposes raw key material" mutate_key_material_raw_initializer
expect_rejection "key material raw accessor" "ProjectKeyMaterial exposes raw key material" mutate_key_material_raw_accessor
expect_rejection "bookmark raw storage" "opaque persisted type exposes raw storage" mutate_bookmark_raw_storage
expect_rejection "fingerprint raw storage" "opaque persisted type exposes raw storage" mutate_fingerprint_raw_storage
expect_rejection "bookmark raw initializer" "opaque persisted type exposes raw storage" mutate_bookmark_raw_initializer
expect_rejection "fingerprint raw initializer" "opaque persisted type exposes raw storage" mutate_fingerprint_raw_initializer
expect_rejection "lease key material" "ProjectKeyLease exposes key material" mutate_key_lease_material
expect_rejection "lease key material accessor" "ProjectKeyLease exposes key material" mutate_key_lease_accessor
expect_rejection "root raw descriptor accessor" "RootCapability exposes a raw descriptor" mutate_root_raw_descriptor
expect_rejection "bookmark persistence bridge call" "persistence bridge call escaped ProjectState.swift" mutate_bookmark_bridge_call
expect_rejection "fingerprint persistence bridge call" "persistence bridge call escaped ProjectState.swift" mutate_fingerprint_bridge_call
expect_rejection "generic fingerprint identity" "generic suppression identity API is forbidden" mutate_generic_fingerprint_identity
expect_rejection "generic fingerprint encoder" "generic suppression identity API is forbidden" mutate_generic_fingerprint_encoder
expect_rejection "test framing support in production" "fingerprint test support has a production call site" mutate_framed_mac_call
expect_rejection "RFC helper in production" "fingerprint test support has a production call site" mutate_rfc_helper_call
expect_rejection "full-frame accumulator" "fingerprint framing accumulates or copies borrowed fields" mutate_fingerprint_accumulator
expect_rejection "borrowed-field Data copy" "fingerprint framing accumulates or copies borrowed fields" mutate_borrowed_field_copy
expect_rejection "redactor Data subdata copy" "privacy redactor copies whole source input" mutate_redactor_data_copy
expect_rejection "redactor whole-input String" "privacy redactor copies whole source input" mutate_redactor_string_copy
expect_rejection "redactor Data slice materialization" "privacy redactor copies whole source input" mutate_redactor_slice_copy
expect_rejection "file-broker test control" "test control escaped its exact allowlist" mutate_file_broker_test_control_use
expect_rejection "content-broker test control" "test control escaped its exact allowlist" mutate_content_broker_test_control_use
expect_rejection "state operations" "test control escaped its exact allowlist" mutate_state_operations_use
expect_rejection "backup operations" "test control escaped its exact allowlist" mutate_backup_operations_use
expect_rejection "file-broker control from wrong test" "test control escaped its exact allowlist" mutate_file_broker_test_control_wrong_test
expect_rejection "state operations from wrong test" "test control escaped its exact allowlist" mutate_state_operations_wrong_test

echo "project scanner boundary mutation tests passed"
