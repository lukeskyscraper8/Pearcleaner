#!/bin/bash
set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${PROJECT_SCANNER_BOUNDARY_ROOT:-$SCRIPT_ROOT}"
CORE="$ROOT/ProjectScannerCore"
TESTS="$ROOT/ProjectScannerCoreTests"
PROJECT="$ROOT/Pearcleaner.xcodeproj/project.pbxproj"
PRODUCTS_DIR="${1:-}"

fail() {
    echo "project scanner boundary check failed: $1" >&2
    exit 1
}

[[ $# -le 1 ]] || fail "expected zero arguments or one built-products directory"
if [[ -n "${PROJECT_SCANNER_BOUNDARY_ROOT:-}" && -n "$PRODUCTS_DIR" ]]; then
    fail "mutation-root mode does not accept built products"
fi
[[ -d "$CORE" ]] || fail "ProjectScannerCore source directory is missing"
[[ -d "$TESTS" ]] || fail "ProjectScannerCoreTests source directory is missing"
[[ -f "$PROJECT" ]] || fail "Xcode project file is missing"

python3 - "$CORE" "$TESTS" "$PROJECT" <<'PY'
import json
import pathlib
import re
import subprocess
import sys

core = pathlib.Path(sys.argv[1])
tests = pathlib.Path(sys.argv[2])
project = pathlib.Path(sys.argv[3])

def fail(message):
    print(f"project scanner boundary check failed: {message}", file=sys.stderr)
    raise SystemExit(1)

def public_callable_parameters(text):
    declarations = []
    pattern = re.compile(r"\bpublic\s+(?:func\s+[A-Za-z_][A-Za-z0-9_]*\s*|init\s*)\(")
    for match in pattern.finditer(text):
        open_index = match.end() - 1
        depth = 1
        index = open_index + 1
        while index < len(text) and depth:
            if text[index] == "(":
                depth += 1
            elif text[index] == ")":
                depth -= 1
            index += 1
        if depth:
            fail("public API declaration could not be parsed")
        declarations.append(text[open_index + 1:index - 1])
    return declarations

def swift_files(root):
    return sorted(root.rglob("*.swift"))

core_files = swift_files(core)
test_files = swift_files(tests)
core_text = {path: path.read_text(errors="strict") for path in core_files}
test_text = {path: path.read_text(errors="strict") for path in test_files}
relative_core = {path: path.relative_to(core.parent).as_posix() for path in core_files}
relative_tests = {path: path.relative_to(tests.parent).as_posix() for path in test_files}

# plutil is the authoritative OpenStep parser. Count object definitions first,
# because conversion to a dictionary would otherwise collapse duplicate IDs.
pbx_text = project.read_text(errors="strict")
object_ids = re.findall(
    r"^\t\t([A-F0-9]{24})(?:\s+/\*.*?\*/)?\s*=\s*\{",
    pbx_text,
    flags=re.MULTILINE,
)
if len(object_ids) != len(set(object_ids)):
    fail("PBX object IDs must resolve exactly once")
try:
    parsed = json.loads(subprocess.check_output(
        ["/usr/bin/plutil", "-convert", "json", "-o", "-", str(project)],
        stderr=subprocess.STDOUT,
    ))
except (subprocess.CalledProcessError, json.JSONDecodeError):
    fail("PBX project could not be parsed")
objects = parsed.get("objects")
if not isinstance(objects, dict):
    fail("PBX project could not be parsed")

target_names = {
    "ProjectScannerCore", "ProjectScannerCoreTests", "Pearcleaner",
    "PearcleanerTests", "FinderOpen", "PearcleanerHelper",
    "PearcleanerSentinel",
}
targets = {}
target_ids = {}
for name in target_names:
    matches = [
        (identifier, value) for identifier, value in objects.items()
        if isinstance(value, dict)
        and value.get("isa") == "PBXNativeTarget"
        and value.get("name") == name
    ]
    if len(matches) != 1:
        fail(f"{name} target must resolve exactly once")
    target_ids[name], targets[name] = matches[0]

project_objects = [
    identifier for identifier, value in objects.items()
    if isinstance(value, dict) and value.get("isa") == "PBXProject"
]
if len(project_objects) != 1:
    fail("PBX project object must resolve exactly once")
project_id = project_objects[0]

if targets["ProjectScannerCore"].get("packageProductDependencies") != []:
    fail("ProjectScannerCore packageProductDependencies must be empty")

allowed_phase_kinds = {
    "PBXSourcesBuildPhase", "PBXFrameworksBuildPhase",
    "PBXResourcesBuildPhase", "PBXCopyFilesBuildPhase",
}
framework_phases = {}
for name, target in targets.items():
    phase_ids = target.get("buildPhases")
    if not isinstance(phase_ids, list) or len(phase_ids) != len(set(phase_ids)):
        fail("target build phase graph is invalid")
    phases = []
    for phase_id in phase_ids:
        phase = objects.get(phase_id)
        if not isinstance(phase, dict) or phase.get("isa") not in allowed_phase_kinds:
            fail("target build phase graph is invalid")
        phases.append(phase)
        files = phase.get("files")
        if not isinstance(files, list) or len(files) != len(set(files)):
            fail("target framework graph is invalid")
        for build_id in files:
            build_file = objects.get(build_id)
            if not isinstance(build_file, dict) or build_file.get("isa") != "PBXBuildFile":
                fail("target framework graph is invalid")
            references = [
                build_file[key] for key in ("fileRef", "productRef")
                if isinstance(build_file.get(key), str)
            ]
            if len(references) != 1:
                fail("target framework graph is invalid")
            reference = objects.get(references[0])
            if not isinstance(reference, dict) or reference.get("isa") not in {
                "PBXFileReference", "XCSwiftPackageProductDependency",
            }:
                fail("target framework graph is invalid")
    frameworks = [p for p in phases if p.get("isa") == "PBXFrameworksBuildPhase"]
    if len(frameworks) != 1:
        fail("target build phase graph is invalid")
    framework_phases[name] = frameworks[0]

def dependency_targets(name):
    dependency_ids = targets[name].get("dependencies")
    message = (
        "PearcleanerTests host dependency graph is invalid"
        if name == "PearcleanerTests"
        else f"{name} dependency graph is invalid"
    )
    if not isinstance(dependency_ids, list) or len(dependency_ids) != len(set(dependency_ids)):
        fail(message)
    resolved = []
    for dependency_id in dependency_ids:
        dependency = objects.get(dependency_id)
        if not isinstance(dependency, dict) or dependency.get("isa") != "PBXTargetDependency":
            fail(message)
        direct = dependency.get("target")
        proxy = objects.get(dependency.get("targetProxy"))
        if (
            not isinstance(direct, str)
            or not isinstance(objects.get(direct), dict)
            or objects[direct].get("isa") != "PBXNativeTarget"
            or not isinstance(proxy, dict)
            or proxy.get("isa") != "PBXContainerItemProxy"
            or str(proxy.get("proxyType")) != "1"
            or proxy.get("containerPortal") != project_id
            or proxy.get("remoteGlobalIDString") != direct
        ):
            fail(message)
        resolved.append(direct)
    return resolved

core_id = target_ids["ProjectScannerCore"]
if dependency_targets("ProjectScannerCoreTests") != [core_id]:
    fail("ProjectScannerCoreTests dependency graph is invalid")
if dependency_targets("Pearcleaner").count(core_id) != 1:
    fail("Pearcleaner dependency graph is invalid")
if dependency_targets("PearcleanerTests") != [target_ids["Pearcleaner"]]:
    fail("PearcleanerTests host dependency graph is invalid")
for name in ("FinderOpen", "PearcleanerHelper", "PearcleanerSentinel"):
    if core_id in dependency_targets(name):
        fail("non-scanner target links or depends on ProjectScannerCore")

core_product_id = targets["ProjectScannerCore"].get("productReference")
core_product = objects.get(core_product_id)
if (
    not isinstance(core_product, dict)
    or core_product.get("isa") != "PBXFileReference"
    or core_product.get("path") != "libProjectScannerCore.a"
    or core_product.get("explicitFileType") != "archive.ar"
    or core_product.get("sourceTree") != "BUILT_PRODUCTS_DIR"
    or targets["ProjectScannerCore"].get("productType") != "com.apple.product-type.library.static"
    or targets["ProjectScannerCore"].get("productName") != "ProjectScannerCore"
):
    fail("target framework graph is invalid")

def linked_core_count(name):
    return sum(
        1 for build_id in framework_phases[name].get("files", [])
        if (objects[build_id].get("fileRef") or objects[build_id].get("productRef"))
        == core_product_id
    )

for name in ("ProjectScannerCoreTests", "Pearcleaner", "PearcleanerTests"):
    if linked_core_count(name) != 1:
        fail(f"{name} must link ProjectScannerCore exactly once")
for name in ("FinderOpen", "PearcleanerHelper", "PearcleanerSentinel"):
    if linked_core_count(name) != 0:
        fail("non-scanner target links or depends on ProjectScannerCore")

# Imports are an allowlist, not a denylist. Annotated and declaration imports
# are parsed too; unsupported import syntax is rejected closed.
allowed_core_imports = {"Foundation", "CryptoKit", "Darwin"}
allowed_test_imports = {"Foundation", "CryptoKit", "Darwin", "XCTest", "ProjectScannerCore"}
test_imported_core = False
import_line = re.compile(
    r"^\s*(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?\s+)*"
    r"import(?:\s+(?:struct|class|enum|protocol|func|var|let|typealias))?"
    r"\s+([A-Za-z_][A-Za-z0-9_]*)(?:\.[A-Za-z_][A-Za-z0-9_.]*)?\s*$"
)
def imported_modules(text, failure):
    modules = []
    for line in text.splitlines():
        if not re.search(r"\bimport\b", line):
            continue
        match = import_line.match(line)
        if not match:
            fail(failure)
        modules.append(match.group(1))
    return modules

for text in core_text.values():
    for module in imported_modules(text, "scanner core imports a forbidden module"):
        if module not in allowed_core_imports:
            fail("scanner core imports a forbidden module")
for text in test_text.values():
    for module in imported_modules(text, "scanner tests import a forbidden module"):
        if module == "Pearcleaner":
            fail("scanner tests import Pearcleaner")
        if module not in allowed_test_imports:
            fail("scanner tests import a forbidden module")
        test_imported_core |= module == "ProjectScannerCore"
if not test_imported_core:
    fail("scanner tests do not import ProjectScannerCore")

private_state_files = {
    "ProjectScannerCore/Persistence/PrivateStateParentCapability.swift",
    "ProjectScannerCore/Persistence/ProjectState.swift",
    "ProjectScannerCore/Persistence/AtomicStateFile.swift",
    "ProjectScannerCore/Persistence/ProjectStateTransactionLock.swift",
    "ProjectScannerCore/Persistence/StateFileSystemOperations.swift",
    "ProjectScannerCore/Persistence/BackupExclusion.swift",
    "ProjectScannerCore/Persistence/ProjectStateStore.swift",
}
broker_file = "ProjectScannerCore/Containment/ProjectFileBroker.swift"
bookmark_file = "ProjectScannerCore/Persistence/ProjectBookmark.swift"
broker_text = next(text for path, text in core_text.items() if relative_core[path] == broker_file)
raw_call = re.compile(
    r"(?<![A-Za-z0-9_.])(?:(?:Darwin)\.)?"
    r"(open|openat|read|readdir|fstatat|readlinkat|fstat|fcntl|close|write|"
    r"mkdirat|fchmod|fsync|flock|fdopendir|closedir|unlinkat|renameat|lstat)\s*\("
)

def raw_calls(text):
    calls = []
    for line in text.splitlines():
        for match in raw_call.finditer(line):
            if re.search(r"\bfunc\s+$", line[:match.start()]):
                continue
            if line[match.end():].lstrip().startswith(")"):
                continue
            calls.append(match.group(1))
    return calls

state_operations_file = "ProjectScannerCore/Persistence/StateFileSystemOperations.swift"
parent_capability_file = "ProjectScannerCore/Persistence/PrivateStateParentCapability.swift"
backup_file = "ProjectScannerCore/Persistence/BackupExclusion.swift"
frozen_direct_calls = {
    parent_capability_file: {
        "open": 2, "close": 3, "fstat": 2, "fcntl": 1, "lstat": 1,
    },
    backup_file: {"open": 1, "fcntl": 1},
}
for path, text in core_text.items():
    relative = relative_core[path]
    calls = raw_calls(text)
    if not calls:
        continue
    if relative in {broker_file, state_operations_file}:
        continue
    if relative in frozen_direct_calls:
        actual = {name: calls.count(name) for name in set(calls)}
        if actual != frozen_direct_calls[relative]:
            fail("private-state authority escaped its exact allowlist")
        continue
    if relative in private_state_files:
        fail("private-state authority escaped its exact allowlist")
    fail("raw project filesystem authority escaped ProjectFileBroker.swift")
if any(name in {"write", "mkdirat", "fchmod", "fsync", "flock", "unlinkat", "renameat"}
       for name in raw_calls(broker_text)):
    fail("scanner containment code contains a write-capable open flag")

raw_test_files = {
    "ProjectScannerCoreTests/Containment/ContentBrokerTests.swift",
    "ProjectScannerCoreTests/Containment/FileBrokerIntegrationTests.swift",
    "ProjectScannerCoreTests/Containment/FileBrokerRaceTests.swift",
    "ProjectScannerCoreTests/Containment/MountBoundaryIntegrationTests.swift",
    "ProjectScannerCoreTests/Containment/RootCapabilityTests.swift",
    "ProjectScannerCoreTests/Persistence/AtomicStateFileTests.swift",
    "ProjectScannerCoreTests/Persistence/BackupExclusionTests.swift",
    "ProjectScannerCoreTests/Persistence/PrivateStateParentCapabilityTests.swift",
    "ProjectScannerCoreTests/Persistence/ProjectBookmarkTests.swift",
    "ProjectScannerCoreTests/Persistence/ProjectStateStoreTests.swift",
    "ProjectScannerCoreTests/Persistence/StateProcessBoundaryTests.swift",
    "ProjectScannerCoreTests/Support/ScriptedPlatformServices.swift",
    "ProjectScannerCoreTests/Support/TemporaryProjectFixture.swift",
}
for path, text in test_text.items():
    if raw_calls(text) and relative_tests[path] not in raw_test_files:
        fail("raw filesystem test authority escaped its exact allowlist")

for path, text in core_text.items():
    relative = relative_core[path]
    if relative not in {broker_file, bookmark_file} and re.search(r"\.makeFileBroker\s*\(", text):
        fail("RootCapability.makeFileBroker has an unauthorized production call site")
    if relative != broker_file and re.search(r"\.makeTraversal\s*\(", text):
        fail("FileBroker.makeTraversal has an unauthorized production call site")
bookmark_text = next(text for path, text in core_text.items() if relative_core[path] == bookmark_file)
if len(re.findall(r"\.makeFileBroker\s*\(", bookmark_text)) != 1:
    fail("RootCapability.makeFileBroker has an unauthorized production call site")
for required in (
    "private var traversalIssued = false", "guard !traversalIssued else",
    "traversalIssued = true", "disposition = .brokerIssued",
):
    if required not in broker_text:
        fail("FileBroker.makeTraversal authority is not one-shot")

symbol_allowlists = {
    "FileBrokerTestControl": {
        broker_file, "ProjectScannerCoreTests/Containment/FileBrokerRaceTests.swift",
    },
    "ContentBrokerTestControl": {
        broker_file, "ProjectScannerCoreTests/Containment/ContentBrokerTests.swift",
    },
    "StateFileSystemOperations": {
        "ProjectScannerCore/Persistence/AtomicStateFile.swift",
        "ProjectScannerCore/Persistence/BackupExclusion.swift",
        "ProjectScannerCore/Persistence/ProjectStateStore.swift",
        "ProjectScannerCore/Persistence/ProjectStateTransactionLock.swift",
        "ProjectScannerCore/Persistence/StateFileSystemOperations.swift",
        "ProjectScannerCoreTests/Persistence/AtomicStateFileTests.swift",
        "ProjectScannerCoreTests/Persistence/BackupExclusionTests.swift",
        "ProjectScannerCoreTests/Persistence/PrivacySinkCanaryTests.swift",
        "ProjectScannerCoreTests/Persistence/ProjectStateStoreTests.swift",
        "ProjectScannerCoreTests/Persistence/StateProcessBoundaryTests.swift",
        "ProjectScannerCoreTests/Support/ScriptedPlatformServices.swift",
    },
    "BackupExclusionOperations": {
        "ProjectScannerCore/Persistence/AtomicStateFile.swift",
        "ProjectScannerCore/Persistence/BackupExclusion.swift",
        "ProjectScannerCore/Persistence/ProjectStateStore.swift",
        "ProjectScannerCoreTests/Persistence/AtomicStateFileTests.swift",
        "ProjectScannerCoreTests/Persistence/BackupExclusionTests.swift",
        "ProjectScannerCoreTests/Persistence/PrivacySinkCanaryTests.swift",
        "ProjectScannerCoreTests/Persistence/ProjectStateStoreTests.swift",
        "ProjectScannerCoreTests/Persistence/StateProcessBoundaryTests.swift",
        "ProjectScannerCoreTests/Support/ScriptedPlatformServices.swift",
    },
}
all_text = [(relative_core[p], t) for p, t in core_text.items()]
all_text += [(relative_tests[p], t) for p, t in test_text.items()]
for symbol, allowed in symbol_allowlists.items():
    for relative, text in all_text:
        if re.search(rf"\b{symbol}\b", text) and relative not in allowed:
            fail("test control escaped its exact allowlist")

for path in swift_files(core / "Containment"):
    if re.search(r"\b(?:O_WRONLY|O_RDWR|O_CREAT|O_TRUNC)\b", path.read_text()):
        fail("scanner containment code contains a write-capable open flag")
for path, text in core_text.items():
    if relative_core[path] not in private_state_files | {broker_file}:
        continue
    for line in text.splitlines():
        if "flags:" not in line or "O_NOFOLLOW" not in line or "O_DIRECTORY" in line:
            continue
        new_exclusive = "O_CREAT" in line and "O_EXCL" in line
        if not new_exclusive and "O_NONBLOCK" not in line:
            fail("speculative file open is missing O_NONBLOCK")

joined_core = "\n".join(core_text.values())
if re.search(
    r"\b(Process|NSTask|NSXPCConnection|NSWorkspace|URLSession|HelperToolManager|SentinelServiceManager)\b"
    r"|\b(?:posix_spawn|fork|exec[lvpe]*|system|popen)\s*\(", joined_core,
):
    fail("scanner core reaches a forbidden execution, network, or app service")
if re.search(r"\b(?:socket|socketpair|connect|bind|listen|accept|send|sendto|recv|recvfrom|getaddrinfo)\s*\(", joined_core):
    fail("scanner core reaches a Darwin networking primitive")
if re.search(
    r"\b(?:UserDefaults|CFPreferences|AppGroupDefaults|SMAppService|"
    r"printOS|GlobalConsoleManager|UpdaterDebugLogger)\b"
    r"|\bcontainerURL\s*\(\s*forSecurityApplicationGroupIdentifier\s*:",
    joined_core,
):
    fail("scanner core reaches shared preferences or arbitrary-string logging")
if re.search(r"\b(?:print|debugPrint|NSLog|os_log|Logger)\s*\(", joined_core):
    fail("scanner core reaches a generic logging API")

limits_path = core / "Model/ScanLimits.swift"
limits_text = limits_path.read_text()
def scan_limits_arguments(marker):
    marker_index = limits_text.find(marker)
    if marker_index < 0:
        return None
    call_index = limits_text.find("ScanLimits(", marker_index)
    if call_index < 0:
        return None
    start = call_index + len("ScanLimits(")
    depth = 1
    index = start
    while index < len(limits_text) and depth:
        if limits_text[index] == "(":
            depth += 1
        elif limits_text[index] == ")":
            depth -= 1
        index += 1
    if depth:
        return None
    arguments = {}
    for line in limits_text[start:index - 1].splitlines():
        stripped = line.strip().removesuffix(",")
        if not stripped:
            continue
        match = re.fullmatch(r"([A-Za-z][A-Za-z0-9]*):\s*(.+)", stripped)
        if not match or match.group(1) in arguments:
            return None
        arguments[match.group(1)] = match.group(2)
    return arguments

expected_defaults = {
    "generalFiles": "100_000", "secretFileBytes": "5 * 1_024 * 1_024",
    "lockfileBytes": "50 * 1_024 * 1_024", "manifestBytes": "2 * 1_024 * 1_024",
    "installedManifests": "50_000", "directories": "50_000",
    "directoryEntries": "250_000", "traversalDepth": "128",
    "relativePathBytes": "4_096", "structuredDataDepth": "128",
    "parsedScalarBytes": "1 * 1_024 * 1_024", "dependencyNodesPerLockfile": "250_000",
    "dependencyNodesPerSession": "500_000", "findingsPerFile": "2_000",
    "findingsPerSession": "10_000", "inputBytes": "2 * 1_024 * 1_024 * 1_024",
    "wallTimeMilliseconds": "5 * 60 * 1_000", "activeWorkers": "4",
    "activeProjectScans": "1", "gitMetadataDescriptors": "1_024",
    "gitDescriptorReserve": "128", "gitOperationMilliseconds": "30_000",
    "gitOutputBytes": "32 * 1_024 * 1_024", "retainedInputBytes": "256 * 1_024 * 1_024",
    "parserArenaBytes": "256 * 1_024 * 1_024", "findingModelBytes": "128 * 1_024 * 1_024",
    "rssSoftBytes": "512 * 1_024 * 1_024", "rssHardBytes": "1_024 * 1_024 * 1_024",
    "maximumLinkHops": "16", "progressIntervalMilliseconds": "250",
    "cancellationLatencyMilliseconds": "500",
}
if scan_limits_arguments("static let defaults") != expected_defaults:
    fail("ScanLimits defaults changed from the approved values")
expected_ceilings = {
    "generalFiles": "500_000", "secretFileBytes": "50 * 1_024 * 1_024",
    "lockfileBytes": "100 * 1_024 * 1_024", "manifestBytes": "4 * 1_024 * 1_024",
    "installedManifests": "100_000", "directories": "200_000",
    "directoryEntries": "1_000_000", "traversalDepth": "defaults.traversalDepth",
    "relativePathBytes": "defaults.relativePathBytes",
    "structuredDataDepth": "defaults.structuredDataDepth",
    "parsedScalarBytes": "defaults.parsedScalarBytes",
    "dependencyNodesPerLockfile": "1_000_000",
    "dependencyNodesPerSession": "2_000_000",
    "findingsPerFile": "defaults.findingsPerFile",
    "findingsPerSession": "defaults.findingsPerSession",
    "inputBytes": "8 * 1_024 * 1_024 * 1_024",
    "wallTimeMilliseconds": "30 * 60 * 1_000",
    "activeWorkers": "defaults.activeWorkers",
    "activeProjectScans": "defaults.activeProjectScans",
    "gitMetadataDescriptors": "defaults.gitMetadataDescriptors",
    "gitDescriptorReserve": "defaults.gitDescriptorReserve",
    "gitOperationMilliseconds": "defaults.gitOperationMilliseconds",
    "gitOutputBytes": "defaults.gitOutputBytes",
    "retainedInputBytes": "defaults.retainedInputBytes",
    "parserArenaBytes": "defaults.parserArenaBytes",
    "findingModelBytes": "defaults.findingModelBytes",
    "rssSoftBytes": "defaults.rssSoftBytes", "rssHardBytes": "defaults.rssHardBytes",
    "maximumLinkHops": "defaults.maximumLinkHops",
    "progressIntervalMilliseconds": "defaults.progressIntervalMilliseconds",
    "cancellationLatencyMilliseconds": "defaults.cancellationLatencyMilliseconds",
}
if scan_limits_arguments("static let hardCeilings") != expected_ceilings:
    fail("ScanLimits hard ceilings changed from the approved values")
if len(re.findall(r"\bScanLimits\s*\(", limits_text)) != 3:
    fail("ScanLimits construction escaped ScanLimits.swift")
for path, text in core_text.items():
    if path != limits_path and re.search(r"\bScanLimits\s*\(", text):
        fail("ScanLimits construction escaped ScanLimits.swift")
    if path != limits_path and ".hardCeilings" in text:
        fail("ScanLimits.hardCeilings escaped its exact allowlist")
for path, text in test_text.items():
    if ".hardCeilings" in text and relative_tests[path] != "ProjectScannerCoreTests/Model/ScanLimitsTests.swift":
        fail("ScanLimits.hardCeilings escaped its exact allowlist")

budget_block_match = re.search(
    r"final\s+class\s+InputBudget\b(.*?)^final\s+class\s+BudgetReservation\b",
    broker_text,
    re.MULTILINE | re.DOTALL,
)
if not budget_block_match:
    fail("InputBudget construction escaped its exact allowlist")
budget_block = budget_block_match.group(1)
if re.search(r"\b(?:public\s+)?(?:convenience\s+)?init\s*\(\s*maximumInputBytes\s*:", budget_block):
    fail("replacement InputBudget constructor is forbidden")
budget_initializers = re.findall(
    r"\b(?:public\s+)?(?:convenience\s+)?init\s*\(", budget_block
)
if budget_initializers != ["init("] or "init(limits: ScanLimits)" not in budget_block:
    fail("InputBudget construction escaped its exact allowlist")
if re.search(r"public\s+[^\n]*(?:InputBudget|maximumInputBytes|maximumRetainedBytes)", joined_core):
    fail("InputBudget construction escaped its exact allowlist")
budget_calls = []
for path, text in core_text.items():
    count = len(re.findall(r"\bInputBudget\s*\(", text))
    if count:
        budget_calls.append((relative_core[path], count))
if budget_calls != [(broker_file, 1)]:
    fail("InputBudget construction escaped its exact allowlist")
for path, text in test_text.items():
    if (relative_tests[path] != "ProjectScannerCoreTests/Containment/ContentBrokerTests.swift"
            and re.search(r"\bInputBudget\s*\(", text)):
        fail("InputBudget construction escaped its exact allowlist")

coordinator_path = core / "Persistence/ProjectKeyCoordinator.swift"
coordinator_text = coordinator_path.read_text()
coordinator_block = re.search(
    r"public\s+actor\s+ProjectKeyCoordinator\b.*?^}",
    coordinator_text,
    re.MULTILINE | re.DOTALL,
)
coordinator_public_parameters = (
    public_callable_parameters(coordinator_block.group(0)) if coordinator_block else []
)
normalized_coordinator_parameters = [re.sub(r"\s+", " ", value).strip()
                                     for value in coordinator_public_parameters]
if (normalized_coordinator_parameters.count("store: any ProjectKeyMaterialStoring") != 1
        or len(re.findall(r"\bpublic\s+init\s*\(", coordinator_block.group(0))) != 1):
    fail("ProjectKeyCoordinator public initializer is invalid")
if any("random:" in value or "uuid:" in value
       for value in normalized_coordinator_parameters):
    fail("ProjectKeyCoordinator injection escaped its exact allowlist")
for path, text in core_text.items():
    if path != coordinator_path and re.search(r"ProjectKeyCoordinator\s*\(\s*store\s*:.*?\brandom\s*:", text, re.DOTALL):
        fail("ProjectKeyCoordinator injection escaped its exact allowlist")
for path, text in test_text.items():
    if (relative_tests[path] != "ProjectScannerCoreTests/Persistence/ProjectKeyCoordinatorTests.swift"
            and re.search(r"ProjectKeyCoordinator\s*\(\s*store\s*:.*?\brandom\s*:", text, re.DOTALL)):
        fail("ProjectKeyCoordinator injection escaped its exact allowlist")

coverage_path = core / "Coverage/CoverageLedger.swift"
coverage_text = coverage_path.read_text()
if "private init(detectors: [DetectorID])" not in coverage_text:
    fail("coverage detector disabling escaped its exact allowlist")
execution_plan = re.search(
    r"public\s+struct\s+DetectorExecutionPlan\b.*?^}",
    coverage_text,
    re.MULTILINE | re.DOTALL,
)
if (
    not execution_plan
    or len(re.findall(r"\bpublic\b", execution_plan.group(0))) != 2
    or "public static let allEnabled" not in execution_plan.group(0)
):
    fail("coverage detector disabling escaped its exact allowlist")
if re.search(r"public\s+(?:func|init)\s+close\s*\(", coverage_text):
    fail("coverage terminal state became caller-settable")
if any(re.search(r"\b(?:DetectorTerminalState|ScanTerminalState)\b", parameters)
       for parameters in public_callable_parameters(coverage_text)):
    fail("coverage terminal state became caller-settable")
if re.search(r"\bpublic\s+func\s+(?:set|close|complete|partial|terminal)\w*\s*\(", coverage_text):
    fail("coverage terminal state became caller-settable")
for path, text in core_text.items():
    if path != coverage_path and re.search(r"\.close\s*\([^\n]*\bas\s*:", text):
        fail("coverage terminal state became caller-settable")
    if path != coverage_path and "DetectorExecutionPlan(detectors:" in text:
        fail("coverage detector disabling escaped its exact allowlist")

redactor_path = core / "Privacy/PrivacyRedactor.swift"
redactor_text = redactor_path.read_text()
if redactor_text.count("fileprivate init(validatedText: String)") != 1:
    fail("RedactedSourceField construction escaped PrivacyRedactor.swift")
redacted_declaration = re.search(
    r"public\s+struct\s+RedactedSourceField\b.*?^}",
    redactor_text,
    re.MULTILINE | re.DOTALL,
)
if not redacted_declaration or re.search(
    r"\bpublic\s+(?:func|static\s+func|init)\b",
    redacted_declaration.group(0),
):
    fail("RedactedSourceField construction escaped PrivacyRedactor.swift")
for path, text in core_text.items():
    if path != redactor_path and "RedactedSourceField(validatedText:" in text:
        fail("RedactedSourceField construction escaped PrivacyRedactor.swift")
session_text = (core / "Session/SessionStore.swift").read_text()
if any(re.search(r"\b(?:Data|String)\b", parameters)
       for parameters in public_callable_parameters(session_text)):
    fail("session API accepts raw source data")
if re.search(r"\bpublic\s+(?:let|var)\s+\w+\s*:\s*(?:Data|String)\b", session_text):
    fail("session API accepts raw source data")

for type_name in (
    "ProjectBookmark", "ProjectKeyMaterial", "SessionFinding",
    "SuppressionFingerprint", "SuppressionRecord",
):
    if re.search(
        rf"(?:struct|extension)\s+{type_name}\b[^{{\n]*\b(?:Codable|Encodable|Decodable)\b",
        joined_core,
    ):
        fail("opaque persisted type became Codable")
for type_name in ("ProjectBookmark", "ProjectKeyMaterial", "RedactedSourceField"):
    if re.search(
        rf"(?:struct|extension)\s+{type_name}\b[^{{\n]*\b(?:CustomStringConvertible|LocalizedError)\b",
        joined_core,
    ):
        fail("opaque persisted type became string-convertible")
key_declaration = re.search(
    r"public\s+struct\s+ProjectKeyMaterial\b.*?^}",
    (core / "Privacy/Fingerprint.swift").read_text(),
    re.MULTILINE | re.DOTALL,
)
if (
    not key_declaration
    or key_declaration.group(0).count("fileprivate let key: SymmetricKey") != 1
    or len(re.findall(r"(?m)^\s{4}init\s*\(\s*generation\s*:\s*UUID\s*,\s*keyBytes\s*:\s*Data\s*\)", key_declaration.group(0))) != 1
    or re.search(r"public\s+init\s*\(\s*generation\s*:\s*UUID\s*,\s*keyBytes\s*:", key_declaration.group(0))
    or re.search(r"public\s+(?:let|var)\s+(?:key|keyBytes|rawKey|rawBytes|material)\b", key_declaration.group(0))
    or [
        match.group(1) for match in re.finditer(
            r"\bpublic\s+(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\b",
            key_declaration.group(0),
        )
    ] != ["generation"]
    or len(re.findall(r"\bpublic\s+init\s*\(", key_declaration.group(0))) != 1
    or len(re.findall(r"\bpublic\s+func\s+secureStorageRecord\s*\(", key_declaration.group(0))) != 1
    or len(re.findall(r"\bpublic\s+func\s+", key_declaration.group(0))) != 1
):
    fail("ProjectKeyMaterial exposes raw key material")
bookmark_declaration = re.search(
    r"public\s+struct\s+ProjectBookmark\b.*?^}",
    (core / "Persistence/ProjectBookmark.swift").read_text(),
    re.MULTILINE | re.DOTALL,
)
fingerprint_declaration = re.search(
    r"public\s+struct\s+SuppressionFingerprint\b.*?^}",
    (core / "Privacy/Fingerprint.swift").read_text(),
    re.MULTILINE | re.DOTALL,
)
if (
    bookmark_declaration
    and re.search(r"public\s+(?:let|var|func)\s+(?:storage|raw\w*|bytes|data)\b", bookmark_declaration.group(0))
) or (
    fingerprint_declaration
    and re.search(r"public\s+(?:let|var|func)\s+(?:bytes|raw\w*|storage|data)\b", fingerprint_declaration.group(0))
):
    fail("opaque persisted type exposes raw storage")
if (
    bookmark_declaration
    and re.search(r"\bpublic\s+(?:let|var|func|init|static)\b", bookmark_declaration.group(0))
) or (
    fingerprint_declaration
    and re.search(r"\bpublic\s+(?:let|var|func|init|static)\b", fingerprint_declaration.group(0))
):
    fail("opaque persisted type exposes raw storage")
if not bookmark_declaration or bookmark_declaration.group(0).count(
    "fileprivate init(validatedStorage: Data)"
) != 1:
    fail("opaque persisted type exposes raw storage")
if not fingerprint_declaration or fingerprint_declaration.group(0).count(
    "fileprivate init(validatedBytes: Data)"
) != 1:
    fail("opaque persisted type exposes raw storage")
lease_declaration = re.search(
    r"public\s+struct\s+ProjectKeyLease\b.*?^}",
    coordinator_text,
    re.MULTILINE | re.DOTALL,
)
if (
    not lease_declaration
    or re.search(r"public\s+(?:let|var|func)\s+(?:material|keyMaterial|rawKey|rawBytes)\b", lease_declaration.group(0))
    or re.search(r"public\s+func\s+\w+\s*\([^)]*\)\s*->\s*ProjectKeyMaterial\b", lease_declaration.group(0), re.DOTALL)
):
    fail("ProjectKeyLease exposes key material")

root_declaration = re.search(
    r"public\s+final\s+class\s+RootCapability\b.*?^}",
    broker_text,
    re.MULTILINE | re.DOTALL,
)
if (
    not root_declaration
    or re.search(r"public\s+(?:let|var|func)\s+(?:descriptor|rawDescriptor|duplicateDescriptor)\b", root_declaration.group(0))
    or re.search(r"public\s+func\s+\w+\s*\([^)]*\)\s*(?:throws\s*)?->\s*Int32\b", root_declaration.group(0), re.DOTALL)
):
    fail("RootCapability exposes a raw descriptor")

state_path = core / "Persistence/ProjectState.swift"
for path, text in core_text.items():
    if path != state_path and re.search(r"(?:ProjectBookmarkPersistence|SuppressionFingerprintPersistence)\.(?:encode|decode)\s*\(", text):
        fail("persistence bridge call escaped ProjectState.swift")
for path, text in core_text.items():
    if re.search(
        r"\b(?:SuppressionIdentityInput|FingerprintEncoder)\b"
        r"|\b(?:suppressionIdentity|fingerprintIdentity|encodeSuppressionIdentity)\s*\(",
        text,
    ):
        fail("generic suppression identity API is forbidden")

fingerprint_path = core / "Privacy/Fingerprint.swift"
fingerprint_text = fingerprint_path.read_text()
for path, text in core_text.items():
    if path != fingerprint_path and re.search(r"\b(?:FramedMACTestSupport|hmacSHA256)\b", text):
        fail("fingerprint test support has a production call site")
if fingerprint_text.count("FramedMACTestSupport") != 1 \
    or len(re.findall(r"\bhmacSHA256\s*\(", fingerprint_text)) != 1:
    fail("fingerprint test support has a production call site")
if (
    "fullFrameAccumulator" in fingerprint_text
    or re.search(r"\bvar\s+frame\s*=\s*Data\s*\(", fingerprint_text)
    or "Data(borrowedField)" in fingerprint_text
    or "Data(bytes: borrowedField" in fingerprint_text
    or "let view = Data(bytes)" in fingerprint_text
    or "hmac.update(data: view)" not in fingerprint_text
    or "BorrowedHMACDataView" not in fingerprint_text
):
    fail("fingerprint framing accumulates or copies borrowed fields")
if (
    ".subdata(" in redactor_text
    or re.search(r"String\s*\(\s*data\s*:", redactor_text)
    or re.search(r"Data\s*\(\s*utf8\s*\[", redactor_text)
):
    fail("privacy redactor copies whole source input")
PY

if [[ -n "$PRODUCTS_DIR" ]]; then
    [[ -d "$PRODUCTS_DIR" ]] || fail "built-products directory is missing"
    FIXTURES="$SCRIPT_ROOT/script/fixtures/project_scanner_api_boundaries"
    [[ -d "$FIXTURES" ]] || fail "public API fixtures are missing"

    fixture_names=(
        ValidImport.swift
        ProjectKeyMaterialCodable.swift
        ProjectKeyMaterialStringConvertible.swift
        ProjectKeyLeaseMaterial.swift
        SuppressionFingerprintCodable.swift
        SuppressionRecordCodable.swift
        SuppressionFingerprintRawProperty.swift
        SuppressionFingerprintRawInitializer.swift
        ProjectBookmarkCodable.swift
        ProjectBookmarkRawProperty.swift
        ProjectBookmarkRawInitializer.swift
        RedactedSourceFieldPublicInit.swift
        CoverageTerminalSetter.swift
        RootCapabilityRawDescriptor.swift
        InputBudgetRawMaxima.swift
        SessionFindingCodable.swift
        SessionStoreRawData.swift
        SessionStoreRawString.swift
    )
    fixture_entry_count="$(find "$FIXTURES" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d '[:space:]')"
    [[ "$fixture_entry_count" == "${#fixture_names[@]}" ]] \
        || fail "public API fixture set is not exact"
    for fixture_name in "${fixture_names[@]}"; do
        [[ -f "$FIXTURES/$fixture_name" && ! -L "$FIXTURES/$fixture_name" ]] \
            || fail "public API fixture is missing or not a regular file: $fixture_name"
    done

    xcrun swiftc -typecheck -I "$PRODUCTS_DIR" "$FIXTURES/ValidImport.swift" \
        || fail "valid ProjectScannerCore public API import did not typecheck"

    require_rejected_fixture() {
        local fixture="$1"
        local diagnostic_pattern="$2"
        local note_pattern="${3:-}"
        local output
        local diagnostics
        local notes
        if output="$(xcrun swiftc -typecheck -I "$PRODUCTS_DIR" "$FIXTURES/$fixture" 2>&1)"; then
            fail "$fixture unexpectedly typechecked"
        fi
        diagnostics="$(grep -E ':[0-9]+:[0-9]+: error:' <<<"$output" || true)"
        notes="$(grep -E ':[0-9]+:[0-9]+: note:' <<<"$output" || true)"
        if [[ -z "$diagnostics" ]] \
            || grep -E '(expected declaration|expected expression|no such module|cannot load module)' <<<"$diagnostics" >/dev/null \
            || ! grep -E "$diagnostic_pattern" <<<"$diagnostics" >/dev/null \
            || { [[ -n "$note_pattern" ]] && ! grep -E "$note_pattern" <<<"$notes" >/dev/null; }; then
            echo "$output" >&2
            fail "$fixture failed for the wrong diagnostic"
        fi
    }

    require_rejected_fixture ProjectKeyMaterialCodable.swift 'error:.*ProjectKeyMaterial.*(Codable|Decodable|Encodable)'
    require_rejected_fixture ProjectKeyMaterialStringConvertible.swift 'error:.*ProjectKeyMaterial.*CustomStringConvertible'
    require_rejected_fixture ProjectKeyLeaseMaterial.swift "error:.*'material'.*(inaccessible|protection level)"
    require_rejected_fixture SuppressionFingerprintCodable.swift 'error:.*SuppressionFingerprint.*(Codable|Decodable|Encodable)'
    require_rejected_fixture SuppressionRecordCodable.swift 'error:.*SuppressionRecord.*(Codable|Decodable|Encodable)'
    require_rejected_fixture SuppressionFingerprintRawProperty.swift "error:.*'bytes'.*(inaccessible|protection level)"
    require_rejected_fixture SuppressionFingerprintRawInitializer.swift \
        "error:.*'SuppressionFingerprint'.*initializer.*(inaccessible|protection level)" \
        "note:.*init\(validatedBytes:\).*declared here"
    require_rejected_fixture ProjectBookmarkCodable.swift 'error:.*ProjectBookmark.*(Codable|Decodable|Encodable)'
    require_rejected_fixture ProjectBookmarkRawProperty.swift "error:.*'storage'.*(inaccessible|protection level)"
    require_rejected_fixture ProjectBookmarkRawInitializer.swift \
        "error:.*'ProjectBookmark'.*initializer.*(inaccessible|protection level)" \
        "note:.*init\(validatedStorage:\).*declared here"
    require_rejected_fixture RedactedSourceFieldPublicInit.swift \
        "error:.*'RedactedSourceField'.*initializer.*(inaccessible|protection level)" \
        "note:.*init\(validatedText:\).*declared here"
    require_rejected_fixture CoverageTerminalSetter.swift "error:.*'CoverageLedger'.*no member 'close'"
    require_rejected_fixture RootCapabilityRawDescriptor.swift "error:.*'RootCapability'.*no member 'duplicateDescriptor'"
    require_rejected_fixture InputBudgetRawMaxima.swift "error:.*cannot find 'InputBudget' in scope"
    require_rejected_fixture SessionFindingCodable.swift 'error:.*SessionFinding.*(Codable|Decodable|Encodable)'
    require_rejected_fixture SessionStoreRawData.swift "error:.*'Data'.*expected argument type 'ScanLimits'"
    require_rejected_fixture SessionStoreRawString.swift "error:.*'String'.*expected argument type 'ScanLimits'"
fi

echo "project scanner boundary checks passed"
