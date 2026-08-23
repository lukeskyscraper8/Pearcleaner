# Project Scanner Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the independently testable, read-only scanner foundation: its module boundary, bounded models, descriptor-relative containment, coverage transactions, session privacy types, keyed suppression-identity primitives, and minimal atomic project state.

**Architecture:** Add `ProjectScannerCore` as an in-project static Swift library with a one-way dependency from the Pearcleaner app and a hostless macOS 13 test target. The core owns descriptor containment plus opaque security-scoped-bookmark creation/resolution, but no UI, Security-framework, helper, process-launch, network, or third-party dependency; narrow app adapters provide Keychain, Application Support, and typed logging services through core-defined protocols. This slice exposes no product UI and implements no secret rules, Git service, advisory updater, lockfile parser, lifecycle detector, FSEvents watcher, or remediation.

**Tech Stack:** Swift 5 language mode, XCTest, Foundation, CryptoKit, Darwin/POSIX, Xcode project targets, Security and OSLog only in main-app adapters

**Spec:** `docs/superpowers/specs/2026-08-23-developer-exposure-inspector-design.md`

## Global Constraints

- The app and core deployment target remains macOS 13.0; the repository build requires Xcode with the macOS 26 SDK.
- `ProjectScannerCore` is an internal code/dependency boundary inside Pearcleaner's process. It is not a sandbox, entitlement boundary, process boundary, or operating-system capability boundary.
- Dependency direction is `Pearcleaner -> ProjectScannerCore` only. FinderOpen, PearcleanerHelper, and PearcleanerSentinel must not depend on the core.
- Core production imports are limited in this slice to `Foundation`, `CryptoKit`, and `Darwin`. `Security` and `OSLog` remain in narrow app adapters.
- The core has no package-product dependencies and must not import AppKit, SwiftUI, Security, OSLog, ServiceManagement, AlinFoundation, Sparkle, ArgumentParser, helper/Sentinel clients, shell wrappers, or third-party parsers.
- The main scanner launches no child process and performs no network request. No `Process`, `NSTask`, `posix_spawn`, `fork`, `exec`, `system`, `popen`, `NSXPCConnection`, `NSWorkspace`, or `URLSession` API is allowed in this slice.
- Project filesystem authorization comes only from a pinned selected-root descriptor and device/inode identity. String prefix, `realpath`, `standardizedFileURL`, `resolvingSymlinksInPath`, bookmarks, cached paths, and FSEvents paths never authorize a read.
- Traversal is read-only. It never opens project content with `O_WRONLY`, `O_RDWR`, or a creation/truncation flag and never writes in the selected root.
- External links, mount/device changes, special files, identity races, and exhausted budgets are skipped with a typed coverage reason; there is no permissive fallback.
- Raw secret/source bytes may exist only in bounded input buffers. Session and presentation APIs accept typed redacted evidence, not raw snippets or arbitrary diagnostic strings.
- Only a complete whole-run result may replace `lastCompleteSummary`; every terminal attempt may replace only the sanitized `lastAttempt`.
- Private state lives outside the selected project and outside UserDefaults/app groups, under mode-0700 Application Support directories and mode-0600 files, excluded from backup and synchronization.
- The security-scoped bookmark is the sole path-bearing persisted field. Persistent state contains no finding path, package name/version, advisory evidence, source context, lifecycle command, raw or partially revealed secret, or unkeyed content hash.
- Persistent HMAC material uses a 32-byte non-synchronizing Keychain key with `WhenUnlockedThisDeviceOnly`, a matching generation UUID, explicit domain separation, and length-delimited exact fields.
- If Keychain is unavailable, a scan may use an ephemeral in-memory key but cannot apply/create persistent suppressions or update project summaries. Missing key material for already-keyed state requires explicit reset and never auto-creates a replacement.
- Defaults and hard ceilings are copied exactly from spec section 15. Fixed containment, path, parser, finding, concurrency, memory, cancellation, and Git limits are not user-disableable.
- Existing Debug tests, security regression checks, static analysis, and arm64/x86_64 Release builds remain required and receive additive scanner checks.
- Product naming, navigation, rebranding, licensing, Git history, Git execution/XPC, detectors, advisory data, dependency parsing, lifecycle heuristics, watching, and UI remain untouched.

## File and target map

Create these targets and shared scheme:

```text
ProjectScannerCore                 static Swift library, macOS 13
ProjectScannerCoreTests            hostless XCTest bundle, macOS 13
ProjectScannerCore.xcscheme        core build and test scheme
```

Create these source files:

```text
ProjectScannerCore/
  Model/ScannerModule.swift                 module/schema marker
  Model/ScannerTypes.swift                  identifiers and closed state/reason enums
  Model/ScanLimits.swift                    defaults, hard ceilings, validated overrides
  Model/FindingModels.swift                 session-only typed finding headers
  Coverage/CoverageLedger.swift             independent detector transactions and aggregation
  Containment/ProjectFileBroker.swift         file-private descriptors, pinned root, traversal, bounded reads
  Containment/VerifiedRelativePath.swift      raw component path and escaped display form
  Privacy/PrivacyRedactor.swift               file-private evidence construction, masking, escaping, scalar limit
  Privacy/Fingerprint.swift                  framed HMAC-SHA256 suppression identity
  Privacy/ScannerDiagnosticEvent.swift       closed, non-string diagnostic events
  Session/SessionStore.swift                 actor holding session-only safe finding data
  Persistence/PrivateStateParentCapability.swift pinned Application Support parent
  Persistence/ProjectBookmark.swift           opaque validated bookmark and security-scope lease
  Persistence/ProjectState.swift             strictly minimal Codable envelope
  Persistence/ProjectKeyCoordinator.swift    persistent/ephemeral/reset-required key state
  Persistence/ProjectStateTransactionLock.swift in-process and cross-process transaction gate
  Persistence/StateFileSystemOperations.swift closed syscall seam for deterministic durability tests
  Persistence/BackupExclusion.swift          identity-checked backup-exclusion bridge
  Persistence/AtomicStateFile.swift          descriptor-pinned 0700/0600 atomic storage
  Persistence/ProjectStateStore.swift        generation-checked state transactions
  Interfaces/ScannerPlatformServices.swift   app-adapter protocols and sanitized outcomes

ProjectScannerCoreTests/
  Support/TemporaryProjectFixture.swift
  Support/ScriptedPlatformServices.swift
  Support/PrivacyCanaries.swift
  Model/ScannerModuleTests.swift
  Model/ScannerTypesTests.swift
  Model/ScanLimitsTests.swift
  Coverage/CoverageLedgerTests.swift
  Containment/VerifiedRelativePathTests.swift
  Containment/RootCapabilityTests.swift
  Containment/FileBrokerIntegrationTests.swift
  Containment/FileBrokerRaceTests.swift
  Containment/ContentBrokerTests.swift
  Containment/MountBoundaryIntegrationTests.swift
  Privacy/PrivacyRedactorTests.swift
  Privacy/FingerprintTests.swift
  Privacy/SessionStorePrivacyTests.swift
  Persistence/PrivateStateParentCapabilityTests.swift
  Persistence/ProjectBookmarkTests.swift
  Persistence/ProjectKeyCoordinatorTests.swift
  Persistence/AtomicStateFileTests.swift
  Persistence/BackupExclusionTests.swift
  Persistence/ProjectStateStoreTests.swift
  Persistence/PrivacySinkCanaryTests.swift
  Persistence/StateProcessBoundaryTests.swift

Pearcleaner/Logic/ProjectScanner/
  KeychainProjectKeyStore.swift
  ProjectScannerEnvironment.swift
  ScannerDiagnosticsAdapter.swift

PearcleanerTests/
  ProjectScannerAdapterTests.swift
```

Create or modify build enforcement:

```text
Create: Pearcleaner.xcodeproj/xcshareddata/xcschemes/ProjectScannerCore.xcscheme
Create: script/project_scanner_boundary_checks.sh
Create: script/test_project_scanner_boundary_checks.sh
Create: script/test_project_scanner_mount_boundary.sh
Create: script/test_project_scanner_persistence_boundaries.sh
Create: script/fixtures/project_scanner_lock_holder.swift
Create: script/fixtures/project_scanner_api_boundaries/*.swift
Modify: Pearcleaner.xcodeproj/project.pbxproj
Modify: Pearcleaner.xcodeproj/xcshareddata/xcschemes/Pearcleaner Debug.xcscheme
Modify: script/security_regression_checks.sh
Modify: .github/workflows/build.yml
```

No view, navigation, resource, entitlement, helper, Sentinel, Finder extension, or remote-package file changes in this slice.

## Execution prerequisite

Start Task 1 from a worktree with no tracked modifications and with the approved spec plus this plan already committed at `HEAD`. If the current checkout contains any other tracked work, use an isolated worktree instead of folding it into the scanner slice. Preserve and never stage the existing user-owned `.superpowers/`, brainstorm, or unrelated plan files if execution stays in this checkout; their appearance in `git status` is not part of the slice.

Before Task 1, resolve the repository's already-pinned packages once into the shared local cache:

```bash
xcodebuild \
  -resolvePackageDependencies \
  -project Pearcleaner.xcodeproj \
  -scheme "Pearcleaner Debug" \
  -clonedSourcePackagesDirPath .build/SourcePackages
```

Every later local `xcodebuild` command uses that exact cache with `-disableAutomaticPackageResolution`; no task may update `Package.resolved` or introduce a package dependency.

---

### Task 1: Establish the scanner target and dependency boundary

**Files:**
- Create: `ProjectScannerCore/Model/ScannerModule.swift`
- Create: `ProjectScannerCoreTests/Model/ScannerModuleTests.swift`
- Create: `script/project_scanner_boundary_checks.sh`
- Create: `Pearcleaner.xcodeproj/xcshareddata/xcschemes/ProjectScannerCore.xcscheme`
- Modify: `Pearcleaner.xcodeproj/project.pbxproj`
- Modify: `Pearcleaner.xcodeproj/xcshareddata/xcschemes/Pearcleaner Debug.xcscheme`
- Modify: `script/security_regression_checks.sh`

**Interfaces:**
- Consumes: existing Xcode project, `Pearcleaner` target, and `Pearcleaner Debug` shared scheme.
- Produces: module `ProjectScannerCore`; static product `libProjectScannerCore.a`; hostless target `ProjectScannerCoreTests`; `ScannerModule.schemaVersion: UInt32`; structural gate `script/project_scanner_boundary_checks.sh`.

- [ ] **Step 1: Write the failing structural boundary check**

Create an executable Bash script whose initial required-target checks fail before the targets exist:

```bash
#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT/ProjectScannerCore"
PROJECT="$ROOT/Pearcleaner.xcodeproj/project.pbxproj"

fail() {
    echo "project scanner boundary check failed: $1" >&2
    exit 1
}

[[ -d "$CORE" ]] || fail "ProjectScannerCore source directory is missing"
grep -q 'name = ProjectScannerCore;' "$PROJECT" \
    || fail "ProjectScannerCore target is missing"
grep -q 'name = ProjectScannerCoreTests;' "$PROJECT" \
    || fail "ProjectScannerCoreTests target is missing"

if grep -REn '^import (AppKit|SwiftUI|Security|OSLog|ServiceManagement|AlinFoundation|Sparkle|ArgumentParser)$' "$CORE" >/dev/null; then
    fail "scanner core imports a forbidden module"
fi

if grep -REn '\b(Process|NSTask|NSXPCConnection|NSWorkspace|URLSession|HelperToolManager|SentinelServiceManager)\b|\b(posix_spawn|fork|exec[lvpe]*|system|popen)\s*\(' "$CORE" >/dev/null; then
    fail "scanner core reaches a forbidden execution, network, or app service"
fi

if grep -REn '\b(socket|socketpair|connect|bind|listen|accept|send|sendto|recv|recvfrom|getaddrinfo)\s*\(' "$CORE" >/dev/null; then
    fail "scanner core reaches a Darwin networking primitive"
fi

if grep -REn '\b(UserDefaults|CFPreferences|AppGroupDefaults|printOS|GlobalConsoleManager|UpdaterDebugLogger)\b' "$CORE" >/dev/null; then
    fail "scanner core reaches shared preferences or arbitrary-string logging"
fi

if grep -REn '\b(print|debugPrint|NSLog|os_log|Logger)\s*\(' "$CORE" >/dev/null; then
    fail "scanner core reaches a generic logging API"
fi

if [[ -d "$CORE/Containment" ]] \
    && grep -REn '\b(O_WRONLY|O_RDWR|O_CREAT|O_TRUNC)\b' "$CORE/Containment" >/dev/null; then
    fail "scanner containment code contains a write-capable open flag"
fi

echo "project scanner boundary checks passed"
```

Add this line immediately before `test_release_archive_payload.sh` in `script/security_regression_checks.sh`:

```bash
"$ROOT/script/project_scanner_boundary_checks.sh"
```

- [ ] **Step 2: Run the boundary check to verify it fails**

Run:

```bash
chmod +x script/project_scanner_boundary_checks.sh
./script/project_scanner_boundary_checks.sh
```

Expected: exit 1 with `ProjectScannerCore source directory is missing`.

- [ ] **Step 3: Add products, synchronized groups, and target records**

First prove the reserved IDs are unused with `rg 'A200000000000000000000[0-9A-F]{2}' Pearcleaner.xcodeproj/project.pbxproj`. Then use stable new project object IDs in the `A20000000000000000000001` through `A20000000000000000000040` range for the two synchronized groups, two products, build phases, build files, proxies, dependencies, configurations, configuration lists, and native-target records. Preserve `objectVersion = 73`; do not let Xcode rewrite unrelated project sections.

- [ ] **Step 4: Configure targets and the one-way dependency graph**

Configure the targets exactly as follows:

```text
ProjectScannerCore
  productType: com.apple.product-type.library.static
  product: libProjectScannerCore.a
  fileSystemSynchronizedGroup: ProjectScannerCore
  packageProductDependencies: ()
  dependencies: ()
  MACOSX_DEPLOYMENT_TARGET: 13.0
  SDKROOT: macosx
  SUPPORTED_PLATFORMS: macosx
  SWIFT_VERSION: 5.0
  SWIFT_STRICT_CONCURRENCY: complete
  DEFINES_MODULE: YES
  MACH_O_TYPE: staticlib
  SKIP_INSTALL: YES

ProjectScannerCoreTests
  productType: com.apple.product-type.bundle.unit-test
  product: ProjectScannerCoreTests.xctest
  fileSystemSynchronizedGroup: ProjectScannerCoreTests
  packageProductDependencies: ()
  dependency: ProjectScannerCore
  linked product: libProjectScannerCore.a
  TEST_HOST: empty
  BUNDLE_LOADER: empty
  GENERATE_INFOPLIST_FILE: YES
  MACOSX_DEPLOYMENT_TARGET: 13.0
  SDKROOT: macosx
  SWIFT_VERSION: 5.0
  SWIFT_STRICT_CONCURRENCY: complete
```

Add `ProjectScannerCore` as a target dependency and linked static product of `Pearcleaner`. Do not add an embed/copy phase. Add neither new target to FinderOpen, PearcleanerHelper, or PearcleanerSentinel. Add `ProjectScannerCoreTests` to the build and test actions of `Pearcleaner Debug` so the existing CI test command remains comprehensive.

- [ ] **Step 5: Create the hostless core scheme**

Create `ProjectScannerCore.xcscheme` with `ProjectScannerCore` and `ProjectScannerCoreTests` in the build action, only `ProjectScannerCoreTests` in the test action, Debug for test/run/analyze, and Release for archive/profile. The scheme has no runnable application.

- [ ] **Step 6: Write the module marker and smoke test**

```swift
// ProjectScannerCore/Model/ScannerModule.swift
public enum ScannerModule {
    public static let schemaVersion: UInt32 = 1
}
```

```swift
// ProjectScannerCoreTests/Model/ScannerModuleTests.swift
import XCTest
@testable import ProjectScannerCore

final class ScannerModuleTests: XCTestCase {
    func testSchemaStartsAtOne() {
        XCTAssertEqual(ScannerModule.schemaVersion, 1)
    }
}
```

- [ ] **Step 7: Run the narrow tests and boundary check**

Run:

```bash
xcodebuild -quiet \
  -project Pearcleaner.xcodeproj \
  -scheme ProjectScannerCore \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/ProjectScannerCoreDerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  test

./script/project_scanner_boundary_checks.sh
```

Expected: the smoke test passes and the boundary script prints `project scanner boundary checks passed`.

- [ ] **Step 8: Commit the target boundary**

```bash
git add \
  ProjectScannerCore/Model/ScannerModule.swift \
  ProjectScannerCoreTests/Model/ScannerModuleTests.swift \
  Pearcleaner.xcodeproj/project.pbxproj \
  Pearcleaner.xcodeproj/xcshareddata/xcschemes/ProjectScannerCore.xcscheme \
  'Pearcleaner.xcodeproj/xcshareddata/xcschemes/Pearcleaner Debug.xcscheme' \
  script/project_scanner_boundary_checks.sh \
  script/security_regression_checks.sh
git commit -m "Add project scanner core boundary"
```

### Task 2: Define scanner identifiers, terminal states, findings, and limits

**Files:**
- Create: `ProjectScannerCore/Model/ScannerTypes.swift`
- Create: `ProjectScannerCore/Model/ScanLimits.swift`
- Create: `ProjectScannerCore/Model/FindingModels.swift`
- Create: `ProjectScannerCoreTests/Model/ScannerTypesTests.swift`
- Create: `ProjectScannerCoreTests/Model/ScanLimitsTests.swift`

**Interfaces:**
- Consumes: `ScannerModule.schemaVersion` from Task 1.
- Produces: `ProjectID`, `ScanSessionID`, `CoverageTransactionID`, `DetectorID`, `FindingKind`, `RuleID`, `SourceView`, `FindingAssessment`, `FindingProvenance`, `SuppressionEligibility`, `SessionSuppressionState`, `DetectorTerminalState`, `ScanTerminalState`, `CoverageReasonCode`, `ScanLimitField`, `ScanLimits`, `ScanLimitOverrides`, `SessionFindingHeader`.

- [ ] **Step 1: Write failing model and limit tests**

Add tests that assert:

```swift
func testSessionAndProjectIdentifiersAreIndependent() {
    let project = ProjectID(rawValue: UUID())
    let session = ScanSessionID(rawValue: UUID())
    XCTAssertNotEqual(project.rawValue, session.rawValue)
}

func testClosedEnumsExposeStablePersistenceCodes() {
    XCTAssertEqual(DetectorID.secret.rawValue, "secret")
    XCTAssertEqual(DetectorID.nodeLockfile.rawValue, "node_lockfile")
    XCTAssertEqual(DetectorID.advisory.rawValue, "advisory")
    XCTAssertEqual(DetectorTerminalState.unavailable.rawValue, "unavailable")
    XCTAssertEqual(ScanTerminalState.cancelled.rawValue, "cancelled")
    XCTAssertEqual(CoverageReasonCode.identityChanged.rawValue, "identity_changed")
}

func testDefaultsAndHardCeilingsMatchTheApprovedSpec() {
    XCTAssertEqual(ScanLimits.defaults.generalFiles, 100_000)
    XCTAssertEqual(ScanLimits.hardCeilings.generalFiles, 500_000)
    XCTAssertEqual(ScanLimits.defaults.secretFileBytes, 5 * 1_024 * 1_024)
    XCTAssertEqual(ScanLimits.hardCeilings.secretFileBytes, 50 * 1_024 * 1_024)
    XCTAssertEqual(ScanLimits.defaults.inputBytes, 2 * 1_024 * 1_024 * 1_024)
    XCTAssertEqual(ScanLimits.hardCeilings.inputBytes, 8 * 1_024 * 1_024 * 1_024)
    XCTAssertEqual(ScanLimits.defaults.maximumLinkHops, 16)
    XCTAssertEqual(ScanLimits.defaults.activeWorkers, 4)
    XCTAssertEqual(ScanLimits.defaults.activeProjectScans, 1)
}

func testOverrideAboveHardCeilingIsRejectedRatherThanClamped() {
    let overrides = ScanLimitOverrides(generalFiles: 500_001)
    XCTAssertThrowsError(try overrides.applying(to: .defaults)) { error in
        XCTAssertEqual(error as? ScanLimitError, .exceedsHardCeiling(.generalFiles))
    }
}
```

Also add `testFindingHeaderKeepsAssessmentProvenanceAndSuppressionIndependent`, `testMaliciousPackageClassificationIsNotUpstreamSeverity`, `testMissingUpstreamSeverityRemainsEmptyRatherThanInvented`, and `testCoverageTransactionIdentifierIsSessionOnly`.

- [ ] **Step 2: Add only the compiling fail-closed model scaffold**

Add the named types and initializers with the required signatures, but use zero-valued limit constants and make override validation return `.invalidValue`. This is temporary production code only to move RED from missing symbols to observable behavior; do not implement the approved values or state semantics yet.

- [ ] **Step 3: Run the tests to verify behavioral RED**

Run:

```bash
xcodebuild -quiet \
  -project Pearcleaner.xcodeproj \
  -scheme ProjectScannerCore \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/ProjectScannerCoreDerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ProjectScannerCoreTests/ScannerTypesTests \
  -only-testing:ProjectScannerCoreTests/ScanLimitsTests \
  test
```

Expected: XCTest failures on the first stable-code/default-value assertions, for example `generalFiles` is `0` instead of `100_000`; no missing-symbol error remains.

- [ ] **Step 4: Add exact identifier and state types**

Define `ProjectID` and `ScanSessionID` UUID wrappers with explicit initializers, `Codable`, `Hashable`, and `Sendable`. Define `CoverageTransactionID` as a UUID-backed `Hashable` and `Sendable` session token without `Codable`. Define closed `String` enums with these cases:

```swift
public enum DetectorID: String, Codable, CaseIterable, Sendable {
    case secret
    case nodeLockfile = "node_lockfile"
    case advisory
    case lifecycle
    case gitEvidence = "git_evidence"
}

public enum FindingKind: String, Codable, Sendable {
    case probableSecret = "probable_secret"
    case vulnerability
    case maliciousPackage = "malicious_package"
    case lifecycleDeclaration = "lifecycle_declaration"
}

public enum SourceView: String, Codable, Sendable {
    case workingTree = "working_tree"
    case index
    case currentHead = "current_head"
}

public enum DetectorTerminalState: String, Codable, Sendable {
    case complete
    case partial
    case cancelled
    case failed
    case unavailable
    case disabled
}

public enum ScanTerminalState: String, Codable, Sendable {
    case complete
    case partial
    case cancelled
    case failed
    case unavailable
}

public enum CoverageReasonCode: String, Codable, CaseIterable, Sendable {
    case externalBoundary = "external_boundary"
    case mountBoundary = "mount_boundary"
    case identityChanged = "identity_changed"
    case unreadable
    case binary
    case ordinaryFileTooLarge = "ordinary_file_too_large"
    case lockfileTooLarge = "lockfile_too_large"
    case manifestTooLarge = "manifest_too_large"
    case unsupportedLockRevision = "unsupported_lock_revision"
    case unsupportedCoordinate = "unsupported_coordinate"
    case gitPreflightRejected = "git_preflight_rejected"
    case gitIgnoreUnsupported = "git_ignore_unsupported"
    case gitDescriptorBudget = "git_descriptor_budget"
    case gitTimeout = "git_timeout"
    case advisoryCacheMissing = "advisory_cache_missing"
    case globalByteBudget = "global_byte_budget"
    case wallTimeBudget = "wall_time_budget"
    case specialFile = "special_file"
    case symlinkCycle = "symlink_cycle"
    case linkHopLimit = "link_hop_limit"
    case directoryBudget = "directory_budget"
    case entryBudget = "entry_budget"
    case pathTooLong = "path_too_long"
    case cancelled
}
```

Add session-only typed finding dimensions:

```swift
public enum FindingConfidence: String, Sendable, Equatable {
    case high
    case reviewSuggested = "review_suggested"
}

public enum AdvisorySource: String, Sendable, Equatable {
    case osv
}

public enum FindingAssessment: Sendable, Equatable {
    case confidence(FindingConfidence)
    case upstreamSeverity([UpstreamSeverity])
    case sourceClassifiedMaliciousPackage(AdvisorySource)
}

public enum FindingProvenance: Sendable, Equatable {
    case secretRule
    case advisory(source: AdvisorySource, generation: UUID)
    case lifecycleRule
}

public enum SuppressionEligibility: Sendable, Equatable {
    case eligible
    case ineligible(SuppressionIneligibilityReason)
}

public enum SessionSuppressionState: Sendable, Equatable {
    case notSuppressed
    case suppressed
    case unavailableEphemeral
    case keyResetRequired
}
```

`UpstreamSeverity` stores only a validated public-advisory scheme/value pair, has an internal initializer, rejects control/bidirectional scalars and values over 256 Unicode scalars, and is not `Codable` or string-convertible. An empty upstream-severity array represents source absence; the scanner never invents or converts severity. `SuppressionIneligibilityReason` is a closed enum for unstable identity, rule policy, and ephemeral key state.

`RuleID` validates non-empty UTF-8 without control or bidirectional-control scalars. `SessionFindingHeader` conforms to `Sendable` and `Equatable` and contains finding kind, rule ID/version, source view, detector ID, coverage transaction ID, assessment, provenance, suppression eligibility, and exact session suppression state. It has no source-text, package, path, or arbitrary-message field. None of the assessment, provenance, or suppression session types conform to `Codable`.

- [ ] **Step 5: Add exact default and ceiling values**

Implement `ScanLimits` using `UInt64` for counts/bytes and `UInt32` for depths/concurrency. Include these exact values:

```swift
public extension ScanLimits {
    static let defaults = ScanLimits(
        generalFiles: 100_000,
        secretFileBytes: 5 * 1_024 * 1_024,
        lockfileBytes: 50 * 1_024 * 1_024,
        manifestBytes: 2 * 1_024 * 1_024,
        installedManifests: 50_000,
        directories: 50_000,
        directoryEntries: 250_000,
        traversalDepth: 128,
        relativePathBytes: 4_096,
        structuredDataDepth: 128,
        parsedScalarBytes: 1 * 1_024 * 1_024,
        dependencyNodesPerLockfile: 250_000,
        dependencyNodesPerSession: 500_000,
        findingsPerFile: 2_000,
        findingsPerSession: 10_000,
        inputBytes: 2 * 1_024 * 1_024 * 1_024,
        wallTimeMilliseconds: 5 * 60 * 1_000,
        activeWorkers: 4,
        activeProjectScans: 1,
        gitMetadataDescriptors: 1_024,
        gitDescriptorReserve: 128,
        gitOperationMilliseconds: 30_000,
        gitOutputBytes: 32 * 1_024 * 1_024,
        retainedInputBytes: 256 * 1_024 * 1_024,
        parserArenaBytes: 256 * 1_024 * 1_024,
        findingModelBytes: 128 * 1_024 * 1_024,
        rssSoftBytes: 512 * 1_024 * 1_024,
        rssHardBytes: 1_024 * 1_024 * 1_024,
        maximumLinkHops: 16,
        progressIntervalMilliseconds: 250,
        cancellationLatencyMilliseconds: 500
    )
}
```

The module-internal `hardCeilings` value raises only the values that differ in spec section 15: general files 500,000; secret file 50 MiB; lockfile 100 MiB; manifest 4 MiB; installed manifests 100,000; directories 200,000; entries 1,000,000; dependency nodes 1,000,000 per lockfile and 2,000,000 per session; input 8 GiB; wall time 30 minutes. Every other value equals `defaults` and is not overridable. It is used only inside validation and named tests; production callers cannot pass the complete ceiling object directly as a scan configuration.

`ScanLimitOverrides` conforms to `Codable`, `Sendable`, and `Equatable` and contains optionals only for the values whose defaults differ from their hard ceilings. `applying(to:)` rejects any zero value, any attempt to encode an unknown/fixed field, and any value above `hardCeilings`; it does not clamp. Its decoder rejects unknown keys so a future setting cannot silently acquire authority on an older build.

Declare an explicit `fileprivate` full initializer in `ScanLimits.swift`; do not rely on Swift's synthesized module-internal memberwise initializer. The same file alone constructs public `defaults`, internal `hardCeilings`, and the value returned by strict `ScanLimitOverrides.applying(to:)`. Task 12 rejects every `ScanLimits(` construction and every production `.hardCeilings` reference in any other file. Core detectors and the future orchestrator therefore cannot manufacture or directly select the full ceiling object merely because they share the module.

- [ ] **Step 6: Run model tests and the full core suite**

Run:

```bash
xcodebuild -quiet \
  -project Pearcleaner.xcodeproj \
  -scheme ProjectScannerCore \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/ProjectScannerCoreDerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Expected: all core tests pass.

- [ ] **Step 7: Commit the stable domain model**

```bash
git add \
  ProjectScannerCore/Model/ScannerTypes.swift \
  ProjectScannerCore/Model/ScanLimits.swift \
  ProjectScannerCore/Model/FindingModels.swift \
  ProjectScannerCoreTests/Model/ScannerTypesTests.swift \
  ProjectScannerCoreTests/Model/ScanLimitsTests.swift
git commit -m "Define project scanner models and limits"
```

### Task 3: Implement independent detector coverage transactions

**Files:**
- Create: `ProjectScannerCore/Coverage/CoverageLedger.swift`
- Create: `ProjectScannerCoreTests/Coverage/CoverageLedgerTests.swift`

**Interfaces:**
- Consumes: `CoverageTransactionID`, all cases of `DetectorID`, `DetectorTerminalState`, `ScanTerminalState`, `CoverageReasonCode`, `AdvisorySource`, and `ScanSessionID` from Task 2.
- Produces: immutable `DetectorExecutionPlan.allEnabled`; `CoverageDelta`, `DetectorCoverageDetail`, `DetectorCoverageSnapshot`, `ScanCoverageSnapshot`, closed `DetectorInterruption` and `ScanSessionCondition`, and actor `CoverageLedger` with `begin`, fact-only `record`, derived `finish`, exceptional `interrupt`, monotonic session-condition `record`, and argument-free `finalize` operations.

- [ ] **Step 1: Write failing coverage state-machine tests**

Cover all of these behaviors with named XCTest methods:

```swift
func testAllEnabledDetectorsCompleteProducesCompleteRun() async throws
func testOpenEnabledTransactionPreventsFinalization() async throws
func testFinishDerivesCompleteFromReconciledFacts() async throws
func testFinishDerivesPartialFromAnySkipOrUnsupportedFact() async throws
func testUnresolvedCandidateAccountingRejectsFinish() async throws
func testIncompleteTypedDetailRejectsFinish() async throws
func testCallerCannotSubmitCompleteOrPartialTerminalState() async throws
func testAllKnownDetectorsArePlannedAndCannotBeOmitted() async throws
func testCancellationWinsOverCompletedDetectorWork() async throws
func testRootAuthorizationFailureProducesUnavailable() async throws
func testDetectorTransactionFinishesOrInterruptsExactlyOnce() async throws
func testClosedTransactionRejectsFurtherCounters() async throws
func testConcurrentCounterUpdatesLoseNoEvents() async throws
func testReasonAndByteCountsAreCopiedIntoImmutableSnapshots() async throws
func testDetectorLimitAffectsOnlyItsDetector() async throws
func testGlobalLimitMakesTheWholeRunPartial() async throws
func testRecordedLimitCannotBeClearedOrFinalizedAsNormal() async throws
func testCounterOverflowFailsTheTransaction() async throws
func testOverflowingMultiFieldDeltaAppliesNoPartialCounterChange() async throws
func testFindingCoverageTransactionResolvesToExactlyOneSnapshot() async throws
func testFinalizedLedgerRejectsEveryFurtherMutation() async throws
func testLockfileCoverageCanCompleteWhileAdvisoryCoverageIsUnavailable() async throws
func testGitStatusIsRecordedPerSessionRepositoryIdentity() async throws
func testLockfileFormatCoordinateAndInstalledManifestDetailsAreImmutable() async throws
func testAdvisoryGenerationProvenanceAgeAndValidationRemainSeparate() async throws
```

The concurrency test creates 100 child tasks, each recording one candidate file and 10 bytes into the same open transaction, then asserts 100 files and 1,000 bytes.

- [ ] **Step 2: Add only the compiling fail-closed ledger scaffold**

Add the public value signatures and actor methods, but make mutation/finalization throw `CoverageLedgerError.notImplemented`. The test target must compile before any state transition is implemented.

- [ ] **Step 3: Run the coverage tests to verify behavioral RED**

Run:

```bash
xcodebuild -quiet \
  -project Pearcleaner.xcodeproj \
  -scheme ProjectScannerCore \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/ProjectScannerCoreDerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ProjectScannerCoreTests/CoverageLedgerTests \
  test
```

Expected: the first transition test fails with `.notImplemented`, not a compiler error.

- [ ] **Step 4: Implement checked counters and immutable snapshots**

Use explicit deltas rather than arbitrary dictionaries:

```swift
public enum CoverageDelta: Sendable, Equatable {
    case candidate(files: UInt64, bytes: UInt64)
    case scanned(files: UInt64, bytes: UInt64)
    case skipped(reason: CoverageReasonCode, files: UInt64, bytes: UInt64)
    case unsupported(reason: CoverageReasonCode, files: UInt64, bytes: UInt64)
    case failed(reason: CoverageReasonCode, files: UInt64, bytes: UInt64)
}

public struct DetectorCoverageSnapshot: Sendable, Equatable {
    public let transactionID: CoverageTransactionID
    public let detector: DetectorID
    public let terminalState: DetectorTerminalState
    public let candidateFiles: UInt64
    public let scannedFiles: UInt64
    public let skippedFiles: UInt64
    public let unsupportedFiles: UInt64
    public let failedFiles: UInt64
    public let candidateBytes: UInt64
    public let scannedBytes: UInt64
    public let skippedBytes: UInt64
    public let unsupportedBytes: UInt64
    public let failedBytes: UInt64
    public let reasonCounts: [CoverageReasonCode: UInt64]
    public let details: [DetectorCoverageDetail]
}
```

Define closed, session-only detail values for:

```swift
public enum DetectorCoverageDetail: Sendable, Equatable {
    case gitRepository(
        RepositoryCoverageID,
        preflight: GitPreflightStatus,
        operation: GitOperationStatus
    )
    case lockfile(format: LockfileFormat, status: LockfileCoverageStatus)
    case coordinates(status: CoordinateCoverageStatus, count: UInt64)
    case installedManifests(InstalledManifestAvailability, count: UInt64)
    case competingLockfiles(CompetingLockfileState)
    case advisory(AdvisoryCoverageMetadata)
}
```

`RepositoryCoverageID` is a random UUID-backed session identity with no path and no `Codable` conformance. The status/format/availability types are closed enums. `AdvisoryCoverageMetadata` keeps generation UUID, `AdvisorySource`, age, last-success/activation timestamps, and validation state as separate typed fields; it has no URL or arbitrary prose. A detail containing a count validates overflow and declared limits before insertion.

Every addition uses `addingReportingOverflow`. Compute and validate every field in a `CoverageDelta` against a local copy before committing any counter; overflow applies none of that delta, closes only that detector as failed, and returns `CoverageLedgerError.counterOverflow(detector)`. `ScanCoverageSnapshot` and `DetectorCoverageSnapshot` conform to `Sendable` and `Equatable`, copy all values, and never retain mutable storage. Each detector snapshot carries its unique transaction ID, so a `SessionFindingHeader` resolves to exactly one coverage record. The snapshots deliberately do not conform to `Codable`; Task 11 maps only approved aggregates and advisory/cache metadata into narrower persistence DTOs.

- [ ] **Step 5: Implement the actor and terminal-state precedence**

`DetectorExecutionPlan` stores exactly one immutable participation record for every `DetectorID.allCases` value. In this slice its sole public value is `.allEnabled`; it has no public memberwise initializer and no API that accepts a caller-selected set. User-selected disabling is UI/configuration work and must arrive later as a separately reviewed proof-carrying constructor. There is no runtime `markDisabled` operation.

At initialization the ledger creates one planned transaction ID for every detector in the execution plan. `begin` transitions that exact planned record to open and returns its existing ID; a second begin fails. This means an omitted detector remains visibly planned rather than disappearing from the snapshot. A closed internal requirements table defines which typed detail variants and reconciliation fields each detector must supply; callers cannot replace that table or claim that an incomplete detail is complete.

Expose only token-scoped detector updates and monotonic session-condition recording:

```swift
public actor CoverageLedger {
    public init(
        sessionID: ScanSessionID,
        executionPlan: DetectorExecutionPlan = .allEnabled
    )

    public func begin(_ detector: DetectorID) throws -> CoverageTransactionID
    public func record(_ delta: CoverageDelta, in transaction: CoverageTransactionID) throws
    public func record(
        _ detail: DetectorCoverageDetail,
        in transaction: CoverageTransactionID
    ) throws
    public func finish(_ transaction: CoverageTransactionID) throws
    public func interrupt(
        _ transaction: CoverageTransactionID,
        because reason: DetectorInterruption
    ) throws
    public func record(_ condition: ScanSessionCondition) throws
    public func finalize() throws -> ScanCoverageSnapshot
}

public enum ScanSessionCondition: Sendable, Equatable {
    case globalLimit(CoverageReasonCode)
    case cancelled
    case failed
    case rootUnavailable
}

public enum DetectorInterruption: Sendable, Equatable {
    case cancelled
    case failed(CoverageReasonCode)
    case unavailable(CoverageReasonCode)
}
```

`finish` is the only normal terminal operation. It requires checked equality of candidate files and bytes with the sum of scanned, skipped, unsupported, and failed outcome files and bytes; an outcome can never exceed the candidate total while recording, and unresolved accounting rejects finish. Exact reconciliation, no skipped/unsupported/failed facts, and every detector-specific typed detail complete derives `.complete`; any recorded coverage-limiting fact derives `.partial`. Counter overflow closes only that detector as `.failed`. `DetectorInterruption` has no complete or partial case, so callers can report exceptional facts but cannot assert a successful terminal state.

Session conditions are monotonic and never accept `.normal`. Recording a second condition keeps the more severe state under this exact precedence: `rootUnavailable -> unavailable`; `failed -> failed`; `cancelled -> cancelled`; a global limit -> partial. A condition auto-closes every planned/open detector that cannot continue with the matching typed terminal state and reason, without rewriting an already finished trustworthy peer. Without a session condition, `finalize()` rejects every still-planned or open detector and succeeds only after all planned detectors finish or interrupt explicitly. It produces complete only when every enabled record derived complete; any enabled partial/failed/unavailable record produces partial. The caller cannot pass a disposition at finishing or finalization and cannot restore a less severe state.

After successful finalization, freeze the actor and reject every `begin`, counter/detail/condition `record`, `finish`, `interrupt`, or second `finalize` call with `.alreadyFinalized`.

The lockfile and advisory detectors always use distinct transactions. A valid, fully reconciled lockfile parse can derive `.complete` while advisory matching interrupts as `.unavailable`; the immutable snapshot preserves both states and the whole run becomes `.partial` without relabelling parsing as unavailable.

- [ ] **Step 6: Run focused and full core tests**

Run:

```bash
xcodebuild -quiet \
  -project Pearcleaner.xcodeproj \
  -scheme ProjectScannerCore \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/ProjectScannerCoreDerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Expected: all core tests pass under complete strict-concurrency checking.

- [ ] **Step 7: Commit the coverage ledger**

```bash
git add \
  ProjectScannerCore/Coverage/CoverageLedger.swift \
  ProjectScannerCoreTests/Coverage/CoverageLedgerTests.swift
git commit -m "Add transactional scanner coverage ledger"
```

### Task 4: Add raw-path and owned-descriptor primitives, then pin the selected root

**Files:**
- Create: `ProjectScannerCore/Containment/ProjectFileBroker.swift`
- Create: `ProjectScannerCore/Containment/VerifiedRelativePath.swift`
- Create: `ProjectScannerCoreTests/Support/TemporaryProjectFixture.swift`
- Create: `ProjectScannerCoreTests/Containment/VerifiedRelativePathTests.swift`
- Create: `ProjectScannerCoreTests/Containment/RootCapabilityTests.swift`

**Interfaces:**
- Consumes: `CoverageReasonCode` and the fixed `ScanLimits.defaults` path-byte and link-hop values from Task 2.
- Produces inside one containment file: file-private `OwnedFileDescriptor` and raw-descriptor operations; public `FileIdentity`, `VerifiedPathComponent`, `VerifiedRelativePath`, `EscapedDisplayPath`, `RootCapability`; sanitized `ContainmentError` without associated paths or arbitrary strings.

- [ ] **Step 1: Add failing raw-path and root-pinning tests**

Use a UUID-named `mkdtemp` fixture with explicit `defer` cleanup. Add tests for:

```swift
func testRawComponentsPreserveCaseAndBytesWithoutUnicodeFolding() throws
func testComponentRejectsEmptyDotDotDotSlashAndNUL() throws
func testRelativePathCountsRawBytesIncludingSeparators() throws
func testRelativePathRejectsMoreThanOneHundredTwentyEightComponents() throws
func testDisplayEscapesInvalidUTF8ControlsAndBidirectionalScalars() throws
func testSelectedDirectoryPinsDeviceAndInode() throws
func testSelectedRootSymlinkIsRejected() throws
func testSelectedRegularFileIsRejected() throws
func testRenamingPinnedRootDoesNotChangeCapabilityIdentity() throws
func testReplacingOriginalPathDoesNotRetargetCapability() throws
func testFileIdentityIncludesStatusChangeTimestamp() throws
func testClosingCapabilityPreventsNewBrokerCreation() throws
func testConcurrentCloseAndBrokerCreationNeverUsesAClosedDescriptor() async throws
func testConcurrentBrokerVendsAllowExactlyOneBrokerPerCapability() async throws
func testContainmentErrorsContainOnlyClosedReasonCodes() throws
```

The replacement test opens `root`, renames it to `root-moved`, creates a different directory at the old pathname, and proves a broker created from the capability remains pinned to the original moved directory. No public or module-internal API returns or accepts a raw project descriptor.

- [ ] **Step 2: Add only the compiling fail-closed containment scaffold**

Add the exact type signatures with validators that reject every path and `RootCapability.open` that throws `.notImplemented`. Do not open a descriptor yet.

- [ ] **Step 3: Run the containment primitive tests to verify behavioral RED**

Run:

```bash
xcodebuild -quiet \
  -project Pearcleaner.xcodeproj \
  -scheme ProjectScannerCore \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/ProjectScannerCoreDerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ProjectScannerCoreTests/VerifiedRelativePathTests \
  -only-testing:ProjectScannerCoreTests/RootCapabilityTests \
  test
```

Expected: a valid-component or valid-root assertion fails with `.notImplemented`; no missing-symbol failure remains.

- [ ] **Step 4: Implement descriptor ownership and immutable identity**

Use a lock only to make close/duplicate lifetime safe; never expose the stored descriptor publicly:

```swift
import Darwin
import Foundation

fileprivate final class OwnedFileDescriptor: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32

    init(taking value: Int32) throws {
        guard value >= 0 else { throw ContainmentError.openFailed }
        self.value = value
    }

    deinit {
        closeIfNeeded()
    }

    func duplicate() throws -> OwnedFileDescriptor {
        try lock.withLock {
            guard value >= 0 else { throw ContainmentError.closedCapability }
            let duplicate = fcntl(value, F_DUPFD_CLOEXEC, 0)
            guard duplicate >= 0 else { throw ContainmentError.openFailed }
            return try OwnedFileDescriptor(taking: duplicate)
        }
    }

    func withFileDescriptor<T>(_ body: (Int32) throws -> T) throws -> T {
        try lock.withLock {
            guard value >= 0 else { throw ContainmentError.closedCapability }
            return try body(value)
        }
    }

    func closeIfNeeded() {
        lock.withLock {
            if value >= 0 {
                Darwin.close(value)
                value = -1
            }
        }
    }
}

public struct FileIdentity: Sendable, Equatable, Hashable {
    public let device: UInt64
    public let inode: UInt64
    public let size: UInt64
    public let mode: UInt16
    public let modificationSeconds: Int64
    public let modificationNanoseconds: Int64
    public let statusChangeSeconds: Int64
    public let statusChangeNanoseconds: Int64

    init(_ value: stat) throws
}
```

The internal initializer converts `stat` fields with checked, non-negative conversions. `ContainmentError` is a closed enum such as `.invalidSelection`, `.rootIsLink`, `.notDirectory`, `.openFailed`, `.identityChanged`, `.mountBoundary`, `.closedCapability`, and `.pathTooLong`; it has no `String`, `URL`, `NSError`, or underlying-error payload.

- [ ] **Step 5: Implement raw components and escaped display paths**

`VerifiedPathComponent` stores `Data` and accepts bytes only when they are non-empty, contain no NUL or slash, are neither `.` nor `..`, and are at most 255 bytes. `VerifiedRelativePath` stores a non-empty component array, rejects more than 128 components, computes raw byte length including separators with overflow checks, and rejects totals over 4,096 bytes.

Do not conform either type to `Codable`, `CustomStringConvertible`, or `LocalizedError`. Expose exact HMAC input only as a copy of the component array:

```swift
public struct VerifiedRelativePath: Sendable, Equatable, Hashable {
    let components: [VerifiedPathComponent]

    var identityComponents: [Data] {
        components.map(\.bytes)
    }

    public func escapedForDisplay() -> EscapedDisplayPath
}
```

Raw components and `identityComponents` remain module-internal. The app can compare the opaque value and request `escapedForDisplay()`, but cannot retrieve exact filesystem bytes; only core containment and HMAC code can.

For display, valid printable UTF-8 scalars remain visible; C0/C1 controls, DEL, U+202A through U+202E, and U+2066 through U+2069 use `\\u{HEX}`; invalid UTF-8 bytes use `\\xNN`; `/` is inserted only between verified components. `EscapedDisplayPath` conforms to `Sendable`, `Equatable`, and `Hashable`, has an internal initializer, and exposes only a read-only public `text` property.

- [ ] **Step 6: Implement root acquisition without retaining an authorization path**

`RootCapability.open(selectedURL:)` performs this exact order:

```swift
public final class RootCapability: @unchecked Sendable {
    public let identity: FileIdentity
    private let lock = NSLock()
    private var descriptor: OwnedFileDescriptor?

    private init(descriptor: OwnedFileDescriptor, identity: FileIdentity) {
        self.descriptor = descriptor
        self.identity = identity
    }

    public static func open(selectedURL: URL) throws -> RootCapability {
        try selectedURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw ContainmentError.invalidSelection }

            var inspected = stat()
            guard lstat(path, &inspected) == 0 else { throw ContainmentError.openFailed }
            guard inspected.st_mode & S_IFMT != S_IFLNK else {
                throw ContainmentError.rootIsLink
            }
            guard inspected.st_mode & S_IFMT == S_IFDIR else {
                throw ContainmentError.notDirectory
            }

            let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw ContainmentError.openFailed }
            let owned = try OwnedFileDescriptor(taking: fd)

            var opened = stat()
            guard fstat(fd, &opened) == 0 else { throw ContainmentError.openFailed }
            guard inspected.st_dev == opened.st_dev,
                  inspected.st_ino == opened.st_ino,
                  opened.st_mode & S_IFMT == S_IFDIR else {
                throw ContainmentError.identityChanged
            }

            return RootCapability(descriptor: owned, identity: try FileIdentity(opened))
        }
    }

    func makeFileBroker(limits: ScanLimits) throws -> FileBroker

    public func close() {
        let removed = lock.withLock { () -> OwnedFileDescriptor? in
            defer { descriptor = nil }
            return descriptor
        }
        removed?.closeIfNeeded()
    }

    deinit { close() }
}
```

The stored object contains no `URL` or path string. The module-internal `makeFileBroker(limits:)` is a lock-protected one-shot transfer: it removes the one `OwnedFileDescriptor` from the capability and passes that same owner into the broker. A second or concurrent vend fails with `.brokerAlreadyIssued`; `close()` atomically removes/closes the same optional, so close/vend cannot duplicate or resurrect authority. The test-control overload goes through this identical one-shot transfer. There is no `duplicateDescriptor`, raw `Int32`, or descriptor-wrapper API outside `ProjectFileBroker.swift`. A fresh bookmark resolution produces a fresh capability for a later scan. There is no production call site in this foundation; the future core scan orchestrator must become the sole allowlisted caller and vend exactly once per session. Task 9's core bookmark resolver never constructs a capability without this fresh open and identity check.

- [ ] **Step 7: Run containment tests and the boundary gate**

Run:

```bash
xcodebuild -quiet \
  -project Pearcleaner.xcodeproj \
  -scheme ProjectScannerCore \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/ProjectScannerCoreDerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  test

./script/project_scanner_boundary_checks.sh
```

Expected: all core tests pass; the boundary gate finds no write-capable containment flag.

- [ ] **Step 8: Commit the root capability**

```bash
git add \
  ProjectScannerCore/Containment/ProjectFileBroker.swift \
  ProjectScannerCore/Containment/VerifiedRelativePath.swift \
  ProjectScannerCoreTests/Support/TemporaryProjectFixture.swift \
  ProjectScannerCoreTests/Containment/VerifiedRelativePathTests.swift \
  ProjectScannerCoreTests/Containment/RootCapabilityTests.swift
git commit -m "Pin scanner roots with read-only descriptors"
```

### Task 5: Implement descriptor-relative streaming traversal

**Files:**
- Modify: `ProjectScannerCore/Containment/ProjectFileBroker.swift`
- Create: `ProjectScannerCoreTests/Containment/FileBrokerIntegrationTests.swift`
- Create: `ProjectScannerCoreTests/Containment/FileBrokerRaceTests.swift`
- Modify: `ProjectScannerCoreTests/Support/TemporaryProjectFixture.swift`

**Interfaces:**
- Consumes: the file-private root descriptor machinery, `FileIdentity`, `VerifiedRelativePath`, `CoverageReasonCode`, and validated `ScanLimits`.
- Produces: actor `FileBroker`; actor `FileTraversal`; `TraversalEvent`; opaque `FileCandidate`; file-private `FileAccessToken` and `OpenedReadFile`; `TraversalSummary`; internal closed `FileBrokerTestControl` that exposes pause/resume points but no descriptor, path authorization, or callback.

- [ ] **Step 1: Write failing traversal and race tests**

Use real temporary filesystem objects. Cover:

```swift
func testEnumeratesNestedRegularFilesIncludingHiddenFiles() async throws
func testRelativeFileSymlinkInsideRootProducesCandidate() async throws
func testRelativeDirectorySymlinkInsideRootCanBeTraversed() async throws
func testDotDotInLinkTargetIsAcceptedOnlyWhileStackStaysInRoot() async throws
func testAbsoluteAndRelativeExternalLinksAreSkipped() async throws
func testExactlySixteenLinkHopsAreAcceptedAndSeventeenAreSkipped() async throws
func testFourThousandNinetySixByteLinkTargetIsAcceptedButTruncationIsRejected() async throws
func testSymlinkCycleIsSkipped() async throws
func testFinderAliasBytesAreTreatedAsARegularFile() async throws
func testInRootHardlinkPathsProduceSeparateCandidates() async throws
func testFIFOAndUnixSocketAreSkippedBeforeRead() async throws
func testCharacterAndBlockDeviceModesClassifyAsSpecialWithoutOpening() throws
func testDifferentDeviceIdentityMapsToMountBoundary() throws
func testDepthPathEntryAndDirectoryBudgetsStopWithoutSampling() async throws
func testOverlongTotalPathProducesSafeSkipWithoutConstructingInvalidPath() async throws
func testMalformedEntryNameProducesSafeEscapedSkipLocation() async throws
func testCandidateReplacementBeforeReopenIsRejected() async throws
func testRegularEntryReplacedByFIFOBeforeOpenIsRejectedWithoutBlocking() async throws
func testRegularEntryReplacedBySocketBeforeOpenIsRejectedWithoutBlocking() async throws
func testRelativeLinkTargetReplacementBeforeOpenIsRejected() async throws
func testRetargetedLinkIsRejectedEvenWhenOriginalTargetStillExists() async throws
func testEntryVanishingAfterReaddirProducesTypedSkip() async throws
func testUnreadableSubtreeProducesTypedCoverageWithoutStoppingPeers() async throws
func testRenamingParentThenReplacingItsPathCannotRedirectBroker() async throws
func testOutsideCanaryIsNeverReturnedDuringBoundedRenameRace() async throws
func testConcurrentTraversalVendsAllowExactlyOneTraversalPerBroker() async throws
func testEarlyTraversalCancellationClosesItsDirectoryStack() async throws
func testReadOnlyProjectTraversalNeedsNoWritePermission() async throws
func testTraversalDoesNotChangeProjectTreeSnapshot() async throws
```

`TemporaryProjectFixture` gains POSIX helpers for raw-byte filenames, `symlink`, `link`, `mkfifo`, Unix-domain socket creation, recursive `(relative bytes, identity, mode, size, content hash)` snapshots, and a sibling outside-root canary. Every helper uses a unique fixture root and closes descriptors in `defer`.

- [ ] **Step 2: Add only the compiling fail-closed broker scaffold**

Add the exact candidate/event/broker/traversal/platform-operation signatures. Make `next()` return `.skipped(location: .unrepresentable(parent: nil, escapedLeaf: nil), reason: .unreadable)` and `openForRead` throw `.notImplemented`; no POSIX child open occurs.

- [ ] **Step 3: Run the broker tests to verify behavioral RED**

Run:

```bash
xcodebuild -quiet \
  -project Pearcleaner.xcodeproj \
  -scheme ProjectScannerCore \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/ProjectScannerCoreDerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ProjectScannerCoreTests/FileBrokerIntegrationTests \
  -only-testing:ProjectScannerCoreTests/FileBrokerRaceTests \
  test
```

Expected: the first regular-file candidate assertion receives the scaffold `.unreadable` skip; no missing-symbol error remains.

- [ ] **Step 4: Define the streaming, unforgeable traversal API**

```swift
struct FileCandidate: Sendable, Equatable {
    let logicalPath: VerifiedRelativePath
    let identity: FileIdentity
    let byteCount: UInt64
    fileprivate let accessToken: FileAccessToken

    fileprivate init(
        logicalPath: VerifiedRelativePath,
        identity: FileIdentity,
        byteCount: UInt64,
        accessToken: FileAccessToken
    )
}

enum TraversalEvent: Sendable, Equatable {
    case candidate(FileCandidate)
    case skipped(location: SkippedTraversalLocation, reason: CoverageReasonCode)
}

enum SkippedTraversalLocation: Sendable, Equatable {
    case verified(VerifiedRelativePath)
    case unrepresentable(
        parent: VerifiedRelativePath?,
        escapedLeaf: EscapedDisplayPath?
    )
}

actor FileBroker {
    fileprivate init(
        rootDescriptor: OwnedFileDescriptor,
        rootIdentity: FileIdentity,
        limits: ScanLimits,
        testControl: FileBrokerTestControl?
    )
    func makeTraversal() throws -> FileTraversal
    func revalidate(_ candidate: FileCandidate) async -> CandidateRevalidation
    fileprivate func openForRead(_ candidate: FileCandidate) async throws -> OpenedReadFile
}

actor FileTraversal {
    func next() async throws -> TraversalEvent?
    func summary() -> TraversalSummary
}
```

Keep `OwnedFileDescriptor`, `OpenedReadFile`, all methods that reveal or accept an `Int32`, `FileAccessToken`, its fields, `FileBroker`'s initializer, and `FileCandidate`'s initializer `fileprivate` in `ProjectFileBroker.swift`. `RootCapability.makeFileBroker(limits:)` is the only module-internal construction route; a test-only overload accepts the closed control without exposing a descriptor. `FileBroker`, traversal, candidates, and events are module-internal because the later public scan orchestrator, not the app, owns enumeration. `FileBroker.makeTraversal()` is also one-shot actor state: the first call creates one file-private duplicate of the retained broker root for the traversal and initializes the only per-scan directory/entry/depth counters, while a second or concurrent call fails with `.traversalAlreadyIssued`. Abandonment/cancellation cannot mint a replacement traversal; a later scan begins from a freshly resolved root and broker. The token is an immutable `Sendable`, `Equatable`, and `Hashable` value containing the broker-instance nonce, resolved physical raw components, expected final identity, and the complete bounded link proof: every traversed symlink's logical location, inspected identity, and exact target bytes. `openForRead` rejects a candidate issued by any other broker and replays that proof from the broker's retained pinned-root owner before trusting the physical target. `OpenedReadFile` owns an `O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC` descriptor and cannot cross the file boundary. `revalidate` exercises the same proof but closes the descriptor and returns only a closed validation result, so integration tests can observe replacement rejection without acquiring content. `next()` returns one event at a time; it must not accumulate the candidate set or use an unbounded `AsyncStream` buffer.

Production code calls Darwin directly inside this file. `FileBrokerTestControl` is an internal actor with a closed `FileBrokerTestPoint` enum for the exact boundaries between `readdir`/`fstatat`, `fstatat`/`openat`, and symlink inspect/`readlinkat`/target open. A test can wait for a point, mutate its own fixture externally, and resume; it supplies no closure, descriptor, or repository-derived value. The public initializer has no test-control parameter. Task 12's source gate permits the control only in this one containment file and the named race-test file.

`SkippedTraversalLocation.unrepresentable` allows an overlong total path or malformed leaf to be reported without constructing an invalid `VerifiedRelativePath`. It retains at most the already-verified parent plus a bounded escaped display leaf, never raw unverified bytes.

- [ ] **Step 5: Implement the bounded raw directory cursor**

Each directory frame owns a descriptor/DIR cursor, logical component stack, resolved physical component stack, and ancestry identity set. For every `readdir` name other than `.` and `..`, charge the total-entry budget before inspection and copy the bounded raw `d_name` bytes before the next `readdir` call. Reject malformed or overlong names with a typed skip; never construct a `String` to reopen an entry.

- [ ] **Step 6: Implement identity-checked regular-file and directory admission**

For each copied entry:

1. call `fstatat(parentFD, entryNameCString, &inspectedStat, AT_SYMLINK_NOFOLLOW)`;
2. classify with `S_IFMT`;
3. open a directory with `O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC`, or speculatively open a claimed regular file with `O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC`;
4. `fstat` the opened descriptor and compare device, inode, and type with the inspected entry;
5. reject a device unequal to the root device as `.mountBoundary`;
6. enforce path bytes, depth, directories, and entries before pushing/yielding; and
7. retain no absolute project path.

The loop shape is:

```swift
func next() throws -> TraversalEvent? {
    while let frame = stack.last {
        guard let entry = try frame.nextEntry() else {
            stack.removeLast().close()
            continue
        }

        entries = try checkedIncrement(entries)
        let inspected = try inspect(entry, relativeTo: frame)

        switch inspected.kind {
        case .regular:
            return try admitRegular(inspected, frame: frame)
        case .directory:
            try pushDirectory(inspected, frame: frame)
        case .symbolicLink:
            if let event = try resolveLink(inspected, frame: frame) {
                return event
            }
        case .unsupported:
            return .skipped(location: inspected.safeLocation, reason: .specialFile)
        }
    }

    return nil
}
```

All helper methods use only descriptors and raw components. `O_NONBLOCK` is mandatory on every untrusted final-component open expected to be regular, including symlink-target replay and content reopen. A regular-to-FIFO replacement therefore returns promptly for post-open type rejection rather than blocking before `fstat`; socket and other special replacements are likewise typed skips/errors. Regular files retain harmless `O_NONBLOCK`. `FileManager.enumerator`, `realpath`, `URL.standardizedFileURL`, and `URL.resolvingSymlinksInPath` are prohibited for authorization.

- [ ] **Step 7: Implement bounded in-root relative-link resolution**

Read link bytes with `readlinkat` into a 4,097-byte probe buffer. Accept returned lengths only through 4,096 bytes; a return of 4,097 means truncation/over-limit and is skipped as `.pathTooLong`. Reject an absolute first byte `/`. Parse `/`-separated raw components from the containing physical stack: ignore `.`, pop one component for `..`, and reject any pop below root. Resolve each component anew from a duplicate of the root descriptor with `fstatat/openat` no-follow checks. Nested links count toward one 16-hop budget.

For a link to a regular file, yield the logical link path with an access token containing the resolved physical components and complete link proof. For a link to a directory, carry that proof into descendant tokens while retaining the logical link path. On reopen, re-inspect every symlink and require both identity and target bytes to match before resolving again; retargeting the link is `.identityChanged` even when the old target still exists. Detect a repeated directory identity in the active ancestry as `.symlinkCycle`. An unprovable, absolute, escaping, or changed target returns `.externalBoundary` or `.identityChanged`; it is never retried through a string path.

- [ ] **Step 8: Implement deterministic race defenses and make the initial proofs pass**

Use `FileBrokerTestControl` for the decisive races: vanish after `readdir`; replace a regular entry between inspect and open with another file, a FIFO, and a Unix-domain socket; and replace/retarget a symlink between inspection, target-byte read, and open. The FIFO case uses a bounded `ContinuousClock` assertion and no writer, proving the speculative open cannot block. Then exercise the module-internal boundary by enumerating a candidate, replacing it, and calling `revalidate`; the expected identity/proof must reject the replacement. Rename an already opened parent and put an external symlink at its former pathname; traversal must continue through the pinned descriptor or reject changed identity, never read the outside canary.

The bounded rename stress test performs 1,000 replacement attempts from a child task and accepts only an in-root candidate or typed skip. It fails immediately if outside-canary bytes or identity appear. Give `FileTraversal` an idempotent `cancel()` that closes its entire directory stack synchronously; an internal read-only descriptor-accounting snapshot lets `@testable` tests prove the count returns to zero after completion, cancellation, error, and early abandonment without comparing process-global descriptor counts. Compare the full tree snapshot before and after all traversal tests.

- [ ] **Step 9: Run broker, full core, and boundary tests**

Run:

```bash
xcodebuild -quiet \
  -project Pearcleaner.xcodeproj \
  -scheme ProjectScannerCore \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/ProjectScannerCoreDerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  test

./script/project_scanner_boundary_checks.sh
```

Expected: all tests pass; project snapshots are unchanged; the outside canary is never observed.

- [ ] **Step 10: Commit the file broker**

```bash
git add \
  ProjectScannerCore/Containment/ProjectFileBroker.swift \
  ProjectScannerCoreTests/Support/TemporaryProjectFixture.swift \
  ProjectScannerCoreTests/Containment/FileBrokerIntegrationTests.swift \
  ProjectScannerCoreTests/Containment/FileBrokerRaceTests.swift
git commit -m "Add descriptor-relative project traversal"
```

### Task 6: Add bounded content admission and post-read identity checks

**Files:**
- Modify: `ProjectScannerCore/Containment/ProjectFileBroker.swift`
- Create: `ProjectScannerCoreTests/Containment/ContentBrokerTests.swift`
- Modify: `ProjectScannerCoreTests/Support/TemporaryProjectFixture.swift`

**Interfaces:**
- Consumes file-privately: `FileBroker.openForRead`; module-internally consumes `FileCandidate`, validated `ScanLimits`, and coverage reason codes.
- Produces: closed `ContentPurpose`; internal limit-derived lock-backed `InputBudget`; actor `ContentBroker`; reference type `ContentLease`; `ContentAdmission`; `ContentReadError`; internal closed `ContentBrokerTestControl` with no raw-byte or descriptor access.

- [ ] **Step 1: Write failing content-budget and mutation tests**

Add these tests:

```swift
func testReadsARegularCandidateInBoundedChunks() async throws
func testPerDetectorLimitSkipsWholeFileWithoutSampling() async throws
func testPurposeSelectsValidatedConfiguredLimitWithoutCallerOverride() async throws
func testTwentyMiBLockfileLeaseCannotExposeBytesForSecretInspection() async throws
func testGlobalInputLimitStopsAtTheBoundary() async throws
func testPreAdmissionFailuresConsumeNeitherInputNorRetainedBudget() async throws
func testConcurrentReservationsNeverExceedInputOrRetainedLimits() async throws
func testMultipleContentBrokersFromOneFileBrokerShareOneSessionBudget() async throws
func testLogicalHardlinkPathsAreChargedSeparately() async throws
func testOneLeaseSharedAcrossDetectorPassesIsChargedOnce() async throws
func testRetainedInputBudgetReleasesWhenLeaseDeinitializes() async throws
func testReplacementBeforeReadReturnsIdentityChanged() async throws
func testReplacementByFIFOBeforeContentReopenReturnsPromptlyWithoutReading() async throws
func testMutationOrTruncationDuringReadDiscardsAllBytes() async throws
func testEqualSizeMutationWithRestoredMTimeStillFailsCTimeCheck() async throws
func testCancellationDiscardsPartialBuffer() async throws
func testCancellationCompletesWithinFiveHundredMilliseconds() async throws
func testReadErrorsExposeOnlySanitizedCodes() async throws
func testContentBrokerNeverWritesTheCandidate() async throws
```

For the during-read case, use `ContentBrokerTestControl` to pause after the first real 64 KiB read, mutate the test fixture externally, and resume. Closed fault cases can force a read error at a chosen chunk without receiving the descriptor or buffer. The production broker factory exposes no test control or callback and publishes no lease before its final `fstat` comparison.

- [ ] **Step 2: Add only the compiling fail-closed content scaffold**

Add the exact purpose/budget/lease/admission/broker signatures. Make every `read` return `.skipped(reason: .unreadable, bytes: 0)` without opening or allocating.

- [ ] **Step 3: Run content tests to verify behavioral RED**

Run:

```bash
xcodebuild -quiet \
  -project Pearcleaner.xcodeproj \
  -scheme ProjectScannerCore \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/ProjectScannerCoreDerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ProjectScannerCoreTests/ContentBrokerTests \
  test
```

Expected: the bounded regular-file read test receives the scaffold `.unreadable` skip; no missing-symbol error remains.

- [ ] **Step 4: Implement checked global and retained-buffer admission**

```swift
final class InputBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let limits: ScanLimits
    private var admittedInputBytes: UInt64 = 0
    private var pendingInputBytes: UInt64 = 0
    private var retainedBytes: UInt64 = 0

    init(limits: ScanLimits) {
        self.limits = limits
    }

    func reserve(
        admittedFileBytes: UInt64,
        for purpose: ContentPurpose
    ) throws -> BudgetReservation
}

final class BudgetReservation: @unchecked Sendable {
    func commit() throws -> RetainedBudgetLease
    func cancel()
    deinit
}

final class RetainedBudgetLease: @unchecked Sendable {
    deinit
}
```

Only `InputBudget.init(limits:)` exists, and the type and initializer are internal to `ProjectFileBroker.swift`; there is no initializer accepting maxima. The budget stores the one validated `ScanLimits` value and derives the global input ceiling, retained ceiling, requested purpose ceiling, and complete authorized-purpose set from it. Each `FileBroker` constructs exactly one budget and shares that same object with every content broker it vends. No caller can provide, replace, or reset a budget, and creating a second content broker does not create a second allowance. `reserve` performs checked `admitted + pending + requested` and retained-byte admission under one lock. `BudgetReservation` is a single-use final reference type: `commit()` atomically moves pending input to admitted input and transfers retained ownership once; `cancel()` or `deinit` rolls back both pending counters, and every second terminal call is a harmless no-op. No identity/open/read failure consumes admitted input. `RetainedBudgetLease.deinit` releases only retained bytes; admitted input remains a cumulative per-broker scan charge.

`ContentLease` is a final `@unchecked Sendable` class. It stores private immutable bytes, the `RetainedBudgetLease`, byte count, and the set of `ContentPurpose` values whose validated file-size ceiling admits that count. Its public API exposes only `byteCount`. Its module-internal `withBytes(for:_:)` invokes the borrowed-buffer body only for an authorized purpose and otherwise throws the purpose's typed oversized reason. The raw `Data` is private even inside other source files. A 20 MiB lockfile lease can be shared without a second global input charge, but secret inspection receives no bytes because its 5 MiB purpose is absent. Separate candidate tokens always charge input separately.

- [ ] **Step 5: Implement the read/revalidate/discard sequence**

```swift
enum ContentAdmission: Sendable {
    case admitted(ContentLease)
    case skipped(reason: CoverageReasonCode, bytes: UInt64)
}

enum ContentPurpose: Sendable, Equatable {
    case secretInspection
    case nodeLockfileParsing
    case packageManifestParsing
}

actor ContentBroker {
    fileprivate init(
        fileBroker: FileBroker,
        budget: InputBudget,
        testControl: ContentBrokerTestControl?
    )

    func read(
        _ candidate: FileCandidate,
        for purpose: ContentPurpose
    ) async -> ContentAdmission
}
```

Add module-internal `FileBroker.makeContentBroker()` as the only factory. It passes the broker's existing budget into the file-private initializer. A test-only `makeContentBroker(testControl:)` overload still uses that same budget and accepts only `ContentBrokerTestControl`, whose closed pause/fault enum cannot receive a descriptor, bytes, or a callback. Implement the EINTR-safe `Darwin.read` loop file-privately. There is no content-broker initializer or factory accepting limits, raw maxima, a replacement budget, or a fault callback.

The budget maps `.secretInspection`, `.nodeLockfileParsing`, and `.packageManifestParsing` internally to the validated secret, lockfile, and manifest limits. There is no API accepting a byte ceiling, a second limits value, or an arbitrary detector ID.

Before allocating, reject a candidate whose declared size exceeds the selected purpose limit. Obtain one pending reservation for both logical input and retained bytes, then pass the opaque candidate back to its broker and compare the reopened identity with the candidate. Allocate one exact-size mutable `Data` buffer only while that reservation is live. Ask the injected reader to fill slices of the already-reserved buffer in chunks of at most 64 KiB, so there is no second uncharged content buffer. Check `Task.checkCancellation()` between chunks, reject growth beyond the declared size or limit, then `fstat` again and compare device, inode, type, final size, modification seconds/nanoseconds, and status-change seconds/nanoseconds. Only after every check succeeds, commit the reservation and construct `ContentLease`. On any error, cancellation, short/extra content inconsistency, or changed identity, reset the buffer and let the reservation roll back; never return partial bytes.

The cancellation-latency test uses `ContinuousClock` and a scripted reader that signals after one chunk. It cancels then lets subsequent reads return immediately, asserts the broker completes in under the fixed 500 ms ceiling, and proves no partial lease escapes. It contains no sleep-based race.

The code accepts only the broker's read-only, nonblocking regular-file descriptor. It does not open from `logicalPath`, a URL, or a cached string. The broker uses `O_NONBLOCK` for the speculative reopen and rejects any non-regular post-open type before entering the read loop.

- [ ] **Step 6: Run focused, full, and boundary checks**

Run:

```bash
xcodebuild -quiet \
  -project Pearcleaner.xcodeproj \
  -scheme ProjectScannerCore \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/ProjectScannerCoreDerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  test

./script/project_scanner_boundary_checks.sh
```

Expected: all tests pass and no write-capable project handle is present.

- [ ] **Step 7: Commit bounded content admission**

```bash
git add \
  ProjectScannerCore/Containment/ProjectFileBroker.swift \
  ProjectScannerCoreTests/Containment/ContentBrokerTests.swift \
  ProjectScannerCoreTests/Support/TemporaryProjectFixture.swift
git commit -m "Add bounded scanner content admission"
```

### Task 7: Enforce redacted presentation, typed diagnostics, and session-only findings

**Files:**
- Create: `ProjectScannerCore/Privacy/PrivacyRedactor.swift`
- Create: `ProjectScannerCore/Privacy/ScannerDiagnosticEvent.swift`
- Create: `ProjectScannerCore/Session/SessionStore.swift`
- Create: `ProjectScannerCore/Interfaces/ScannerPlatformServices.swift`
- Create: `ProjectScannerCoreTests/Support/PrivacyCanaries.swift`
- Create: `ProjectScannerCoreTests/Privacy/PrivacyRedactorTests.swift`
- Create: `ProjectScannerCoreTests/Privacy/SessionStorePrivacyTests.swift`
- Modify: `ProjectScannerCore/Model/FindingModels.swift`

**Interfaces:**
- Consumes: `SessionFindingHeader`, `VerifiedRelativePath`, `EscapedDisplayPath`, detector/reason codes, and `ScanSessionID`.
- Produces: module-internal `RedactionSpan`, `MaskingRuleResult`, `RedactionResult`, and `PrivacyRedactor`; public `RedactedSourceField`, `SessionFinding`, `SessionAppendResult`, actor `SessionStore`, `ScannerDiagnosticEvent`, and `ScannerDiagnosticSinking`.

- [ ] **Step 1: Write failing redaction and session privacy tests**

Add tests for:

```swift
func testOneMatchBecomesTheFixedRedactedToken() throws
func testEveryMatchInTheFieldIsMasked() throws
func testAdjacentAndOverlappingSpansMergeWithoutRevealingBytes() throws
func testDifferentSecretLengthsProduceTheSameToken() throws
func testControlAndBidirectionalScalarsAreEscaped() throws
func testOutputIsLimitedToTwoHundredFortyUnicodeScalars() throws
func testMalformedUTF8ReturnsMetadataOnly() throws
func testSpanInsideAMultibyteScalarReturnsMetadataOnly() throws
func testUncertainSecondaryMaskingReturnsMetadataOnly() throws
func testZeroLengthSpanReturnsMetadataOnly() throws
func testMissingExpectedSecondaryRuleResultReturnsMetadataOnly() throws
func testEmptySpanListReturnsMetadataOnlyInThisSlice() throws
func testMoreThanTwoThousandTotalSpansReturnsMetadataOnlyBeforeSorting() throws
func testScalarLimitNeverSplitsTheFixedRedactionToken() throws
func testLargeInputProducesOnlyBoundedStreamingOutput() throws
func testSessionStoreAcceptsRedactedEvidenceAndRelativeLocation() async throws
func testSessionSnapshotContainsOnlyTypedRedactedEvidence() async throws
func testSessionStoreAcceptsExactFindingAndModelBudgetBoundary() async throws
func testSessionStoreRejectsOneFindingOrByteOverBudgetBeforeRetention() async throws
func testConcurrentSessionAppendsNeverExceedFindingOrModelByteLimits() async throws
func testClearingSessionReleasesAllDetailedFindings() async throws
func testDiagnosticEventContainsOnlyClosedCodesAndNumbers() throws
func testSecretCanaryNeverAppearsInEvidenceOrRecordedDiagnosticFields() async throws
```

Use distinct 48-byte ASCII canaries for secret, path, package, advisory, and script values. Search every public `String` plus every typed field captured by a recording diagnostic sink.

- [ ] **Step 2: Add only the compiling fail-closed privacy scaffold**

Add the exact privacy/session/diagnostic signatures. Make redaction always return `.metadataOnly`, session append always return `.limitReached`, and snapshots remain empty.

- [ ] **Step 3: Run privacy tests to verify behavioral RED**

Run:

```bash
xcodebuild -quiet \
  -project Pearcleaner.xcodeproj \
  -scheme ProjectScannerCore \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/ProjectScannerCoreDerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ProjectScannerCoreTests/PrivacyRedactorTests \
  -only-testing:ProjectScannerCoreTests/SessionStorePrivacyTests \
  test
```

Expected: the first valid masking test receives `.metadataOnly` and the first valid append is rejected; no missing-symbol error remains.

- [ ] **Step 4: Add an evidence type that cannot be initialized from raw text outside the core**

```swift
public struct RedactedSourceField: Sendable, Equatable {
    public let text: String

    fileprivate init(validatedText: String) {
        self.text = validatedText
    }
}

struct RedactionSpan: Sendable, Equatable {
    let utf8Range: Range<Int>

    init(utf8Range: Range<Int>) {
        self.utf8Range = utf8Range
    }
}

enum MaskingRuleResult: Sendable, Equatable {
    case complete(ruleID: RuleID, spans: [RedactionSpan])
    case uncertain(ruleID: RuleID)
}

enum RedactionResult: Sendable, Equatable {
    case redacted(RedactedSourceField)
    case metadataOnly
}
```

Define `RedactedSourceField` and `PrivacyRedactor` in the same `PrivacyRedactor.swift` file. Do not conform the evidence type to `Codable`, `CustomStringConvertible`, or `LocalizedError`; its only initializer is `fileprivate`, so no detector or other core file can self-attest that arbitrary source is safe. `RedactionSpan`, `MaskingRuleResult`, `RedactionResult`, and `PrivacyRedactor` remain module-internal. Public session APIs accept `RedactedSourceField`, never a `String`/`Data` source snippet. Task 12 rejects every `RedactedSourceField(` construction outside `PrivacyRedactor.swift` in production core.

- [ ] **Step 5: Implement all-span masking and fail-closed decoding**

Initialize `PrivacyRedactor` with the exact enabled masking-rule ID set. `redact(utf8:ruleResults:)` returns `.metadataOnly` unless results contain every expected rule exactly once, every rule reports `.complete`, the checked total span count is between one and the fixed 2,000 findings-per-file limit, the whole input is strict UTF-8, every range is non-empty and within bounds and starts/ends on a UTF-8 scalar boundary, and every span can be merged deterministically. Count and reject excessive spans before flattening or sorting them. A missing, duplicate, uncertain, or unexpected rule result fails closed. Sort by lower bound, merge overlapping/adjacent spans, append untouched decoded segments and exactly `[REDACTED]` for each merged span, then escape controls/bidirectional scalars.

After validating the complete rule inventory and merging ranges, make one streaming pass over the original bounded buffer. The UTF-8 scalar decoder must validate the entire input even after the presentation limit is reached, but it retains only the current scalar, merged-range cursor, and at most 240 escaped output scalars. When the cursor enters a merged range, validate and consume its scalars without materializing or emitting them, then append one atomic `[REDACTED]` segment only if the complete token fits. For bytes outside a range, decode one strict UTF-8 scalar, escape it if required, and append it only while capacity remains. Invalid UTF-8, a non-scalar span boundary, or any decoder uncertainty discards the local output and returns `.metadataOnly`.

Use this bounded loop shape after validation; the named helpers operate directly on borrowed indices into `utf8` and never create a `Data` slice or whole-source `String`:

```swift
var outputSegments: [RedactedOutputSegment] = []
var scalarCount = 0

guard streamValidatedUTF8(
    utf8,
    masking: mergedRanges,
    through: { event in
        appendBoundedEscaped(
            event,
            to: &outputSegments,
            scalarCount: &scalarCount,
            scalarLimit: 240
        )
    }
) else {
    return .metadataOnly
}

guard let limited = joinValidatedSegments(outputSegments, scalarLimit: 240) else {
    return .metadataOnly
}
return .redacted(RedactedSourceField(validatedText: limited))
```

Build `outputSegments` as typed `.text` and `.redactionToken` segments rather than one undifferentiated string. Coalesce adjacent safe text scalars into bounded segments. Truncation may shorten only a text segment; it either includes the complete `[REDACTED]` token or stops before it. Do not call `Data.subdata`, materialize a `Data` value from a UTF-8 slice, decode the whole input into a `String`, or retain a source-sized array of scalars/segments. The large-input test uses a 5 MiB valid buffer with matches inside and beyond the retained presentation window, asserts the fixed output ceiling, proves every emitted token is complete and neither raw match appears, and runs through an internal peak-output-scalar counter capped at 240 rather than relying on process RSS. An empty aggregate span set returns `.metadataOnly` in this slice. A later lifecycle-detector slice may introduce a separate proof-carrying no-match path after the complete secret-rule inventory has run; this foundation must not let a caller promote arbitrary unmasked text into `RedactedSourceField`.

- [ ] **Step 6: Add typed findings, session storage, and diagnostics**

```swift
public struct SessionFinding: Sendable, Equatable {
    public let header: SessionFindingHeader
    public let location: VerifiedRelativePath?
    public let displayPath: EscapedDisplayPath?
    public let line: UInt64?
    public let evidence: RedactedSourceField?
}

public actor SessionStore {
    private var findings: [SessionFinding] = []

    public init(limits: ScanLimits)

    public func append(_ finding: SessionFinding) -> SessionAppendResult

    public func snapshot() -> [SessionFinding] {
        findings
    }

    public func clear() {
        findings.removeAll(keepingCapacity: false)
    }
}
```

`SessionFindingHeader`, `EscapedDisplayPath`, and every field of `SessionFinding` conform to `Equatable`, allowing synthesis. `SessionFinding` and `SessionStore` do not conform to `Codable`. They contain no raw snippet field.

`SessionStore` tracks checked finding count and a conservative `estimatedModelBytes` for every retained finding, including UTF-8 storage for escaped paths, redacted evidence, and public-advisory severity values. It computes every component and the aggregate with `addingReportingOverflow`; overflow returns `.limitReached` without changing either counter or the array. It accepts exactly the fixed 10,000-finding and 128 MiB boundaries, rejects before array growth or retention with `.limitReached`, and marks the owning detector coverage partial through the caller. `clear()` drops the array capacity and resets both counters. Individual inputs are already bounded by path/evidence/type limits before append.

Define diagnostics as a closed enum plus typed scalar payload:

```swift
public enum ScannerDiagnosticCode: String, Sendable, Equatable {
    case sessionStarted = "session_started"
    case detectorFinished = "detector_finished"
    case coverageLimited = "coverage_limited"
    case rootAuthorizationFailed = "root_authorization_failed"
    case keyUnavailable = "key_unavailable"
    case stateReadFailed = "state_read_failed"
    case stateWriteFailed = "state_write_failed"
}

public enum SanitizedSystemErrorCategory: String, Sendable, Equatable {
    case permissionDenied = "permission_denied"
    case unavailable
    case invalidData = "invalid_data"
    case inputOutput = "input_output"
    case resourceLimit = "resource_limit"
    case cancelled
    case unknown
}

public struct ScannerDiagnosticEvent: Sendable, Equatable {
    public let sessionID: ScanSessionID
    public let detector: DetectorID?
    public let code: ScannerDiagnosticCode
    public let reason: CoverageReasonCode?
    public let count: UInt64?
    public let bytes: UInt64?
    public let durationMilliseconds: UInt64?
    public let systemCategory: SanitizedSystemErrorCategory?
}

public protocol ScannerDiagnosticSinking: Sendable {
    func record(_ event: ScannerDiagnosticEvent) async
}
```

There is no message, label, URL, path, filename, package, advisory, script, evidence, fingerprint, command, or underlying-error field.

- [ ] **Step 7: Run privacy, full core, and structural checks**

Run:

```bash
xcodebuild -quiet \
  -project Pearcleaner.xcodeproj \
  -scheme ProjectScannerCore \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/ProjectScannerCoreDerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  test

./script/project_scanner_boundary_checks.sh
```

Expected: all tests pass and no arbitrary-string logging API is reachable from the core.

- [ ] **Step 8: Commit the privacy/session kernel**

```bash
git add \
  ProjectScannerCore/Privacy/PrivacyRedactor.swift \
  ProjectScannerCore/Privacy/ScannerDiagnosticEvent.swift \
  ProjectScannerCore/Session/SessionStore.swift \
  ProjectScannerCore/Interfaces/ScannerPlatformServices.swift \
  ProjectScannerCore/Model/FindingModels.swift \
  ProjectScannerCoreTests/Support/PrivacyCanaries.swift \
  ProjectScannerCoreTests/Privacy/PrivacyRedactorTests.swift \
  ProjectScannerCoreTests/Privacy/SessionStorePrivacyTests.swift
git commit -m "Add scanner privacy and session kernel"
```

### Task 8: Add opaque fingerprints and a private framed-HMAC primitive

**Files:**
- Create: `ProjectScannerCore/Privacy/Fingerprint.swift`
- Create: `ProjectScannerCoreTests/Privacy/FingerprintTests.swift`

**Interfaces:**
- Consumes for primitive test vectors only: bounded `VerifiedRelativePath` and a borrowed field buffer.
- Produces publicly: `ProjectKeyMaterial` and opaque persistable `SuppressionFingerprint`. Produces internally for `@testable` verification only: `FramedMACTestVector` and `FramedMACTestSupport`, plus a narrow fingerprint persistence bridge. Produces file-privately: `SuppressionMACFramer`; this slice exposes no production suppression-identity encoder.

- [ ] **Step 1: Write failing cryptographic identity tests**

Add:

```swift
func testRFC4231SHA256HMACTestVector() throws
func testSameKeyAndPrimitiveFieldsProduceSameFingerprint() throws
func testTaggedFieldChangeChangesFingerprint() throws
func testRawPathComponentChangeChangesPrimitiveOutput() throws
func testCaseAndUnicodeNormalizationAreNotFolded() throws
func testBorrowedFieldChangeChangesFingerprint() throws
func testPathFramingCannotExceedVerifiedFourThousandNinetySixByteBound() throws
func testFieldBoundaryAmbiguityCannotCollide() throws
func testFixedPrimitiveDomainAndTagsMatchGoldenFrame() throws
func testBorrowedFieldUsesANonOwningDataView() throws
func testPersistenceBridgeRejectsAnythingOtherThanThirtyTwoBytes() throws
func testSecureStorageRecordRoundTripsFixedVersionAndLength() throws
func testSecureStorageRecordRejectsUnknownVersionOrLength() throws
```

Task 12's compile-fail API fixtures prove that `ProjectKeyMaterial` is neither `Codable` nor `CustomStringConvertible`, and that the fingerprint exposes no raw bytes or initializer; ordinary XCTest cannot prove those absences.

The RFC 4231 case uses 20 bytes of `0x0b`, message `Hi There`, and expected SHA-256 HMAC `b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7`. It exercises the module-internal `hmacSHA256(message:key:)` helper directly because the production `ProjectKeyMaterial` policy intentionally accepts only 32-byte keys. The framing tests exercise incremental HMAC only through the test support with valid 32-byte project material.

- [ ] **Step 2: Add only the compiling fail-closed fingerprint scaffold**

Add the exact key, fingerprint, persistence-bridge, test-vector, and test-support signatures plus module-internal `hmacSHA256(message:key:)`. Validate fixed byte lengths, but make both the helper and test-support fingerprint operation throw `FingerprintError.notImplemented` before computing HMAC. This keeps the RFC RED run behavioral rather than a missing-symbol failure.

- [ ] **Step 3: Run fingerprint tests to verify behavioral RED**

Run:

```bash
xcodebuild -quiet \
  -project Pearcleaner.xcodeproj \
  -scheme ProjectScannerCore \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/ProjectScannerCoreDerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ProjectScannerCoreTests/FingerprintTests \
  test
```

Expected: the RFC HMAC assertion fails with `.notImplemented`; no missing-symbol error remains.

- [ ] **Step 4: Define non-persistable key material and fixed-size opaque output**

```swift
public struct ProjectKeyMaterial: Sendable {
    public let generation: UUID
    fileprivate let key: SymmetricKey

    init(generation: UUID, keyBytes: Data) throws {
        guard keyBytes.count == 32 else { throw FingerprintError.invalidKeyLength }
        self.generation = generation
        self.key = SymmetricKey(data: keyBytes)
    }

    public init(secureStorageRecord: Data) throws
    public func secureStorageRecord() -> Data
}

public struct SuppressionFingerprint: Sendable, Equatable, Hashable {
    fileprivate let bytes: Data

    fileprivate init(validatedBytes: Data) throws {
        guard validatedBytes.count == 32 else { throw FingerprintError.invalidFingerprintLength }
        self.bytes = validatedBytes
    }
}

enum SuppressionFingerprintPersistence {
    static func encode(_ value: SuppressionFingerprint) -> Data
    static func decode(_ bytes: Data) throws -> SuppressionFingerprint
}
```

`ProjectKeyMaterial` is not `Codable` or string-convertible. Its raw 32-byte initializer is module-internal for the key coordinator; the app can only decode/encode the fixed secure-storage record required by its Keychain adapter. `SuppressionFingerprint` is not `Codable`, validates exactly 32 bytes on every construction or private-state decoding path, and exposes neither bytes nor a raw-byte initializer. The internal persistence bridge is defined in the same file so it can use the file-private storage; Task 12 permits its production use only from `ProjectState.swift`. `secureStorageRecord()` is the sole key-byte export: it returns exactly version byte `0x01`, 16 generation-UUID bytes, and 32 key bytes for immediate handoff to the Keychain adapter. There is no raw-key property, generic fingerprint encoder, description, or debug representation. The matching initializer rejects every other length or version.

- [ ] **Step 5: Implement domain-separated, tagged, length-delimited framing**

Implement only a file-private framing engine in this detector-free slice. It feeds a four-byte big-endian field count into an incremental `HMAC<SHA256>`, then for each field feeds one-byte tag, eight-byte big-endian length, and exact bytes. A path field contains its component count followed by a length and bytes for each component. It never concatenates components with a delimiter or assembles the complete frame in a second `Data` buffer.

The test support uses a fixed non-production domain and typed test vector:

```swift
struct FramedMACTestVector: Sendable {
    let fixedInteger: UInt32
    let fixedBytes: Data
    let relativePath: VerifiedRelativePath
}

fileprivate struct SuppressionMACFramer {
    private var hmac: HMAC<SHA256>
    private var remainingFields: UInt32

    init(keyMaterial: ProjectKeyMaterial, fieldCount: UInt32)
    mutating func updateField(tag: UInt8, bytes: Data) throws
    mutating func updatePathField(tag: UInt8, path: VerifiedRelativePath) throws
    mutating func updateBorrowedField(
        tag: UInt8,
        bytes: UnsafeRawBufferPointer
    ) throws
    mutating func finalize() throws -> SuppressionFingerprint
}

enum FramedMACTestSupport {
    static func fingerprint(
        _ vector: FramedMACTestVector,
        borrowedField: UnsafeRawBufferPointer,
        keyMaterial: ProjectKeyMaterial
    ) throws -> SuppressionFingerprint
}
```

`FramedMACTestSupport` frames exactly six fields: fixed ASCII domain `com.lukerow.Pearcleaner.project-scanner.suppression.framing-test.v1`, `ScannerModule.schemaVersion`, the vector's integer, its owned bytes, its verified path, and the borrowed field. It exists only to test the primitive and is rejected at every production call site by Task 12. `updateUInt32` and every field-length helper write big-endian bytes and use checked conversions. `updatePathField` computes and validates its total framed length first, then feeds existing component buffers one at a time. `VerifiedRelativePath` already proves at most 128 components and 4,096 cumulative component/separator bytes; recheck those invariants rather than accepting a free `[Data]`. `finalize` rejects too few or too many fields.

`updateBorrowedField` feeds its header first, then creates one immutable, function-local `Data(bytesNoCopy:count:deallocator: .none)` view over a non-empty pointer solely because the macOS 13 CryptoKit HMAC API accepts `DataProtocol`; it calls `hmac.update(data:)` synchronously and never returns, retains, mutates, or appends that view. Empty input feeds only its zero-length header. The alias test compares the source and local view base addresses through an internal test-only observation before the update. Callers use `Data.withUnsafeBytes` only around this synchronous HMAC call, so the admitted lease keeps backing storage alive throughout. No owned frame or borrowed-field copy exists outside the already-budgeted caller buffer.

Task 12 rejects a public or module-internal generic production `SuppressionIdentityInput`, `FingerprintEncoder`, arbitrary `FindingKind` encoder, pre-concatenated detector blob, or production call to the test support. Later detector slices must add distinct typed entry points in `Fingerprint.swift`, with separate domains, fields, and golden tests after their semantic identities exist. In particular, the secret entry point must require exact matched bytes and separately typed versioned structural fields defined by the secret rule; lifecycle and dependency identities use their own typed inputs. Those entry points call the file-private framer field-by-field and never accept one caller-composed identity blob.

- [ ] **Step 6: Run cryptographic and full core tests**

Run:

```bash
xcodebuild -quiet \
  -project Pearcleaner.xcodeproj \
  -scheme ProjectScannerCore \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/ProjectScannerCoreDerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Expected: the RFC vector and every exact-identity separation test pass.

- [ ] **Step 7: Commit HMAC identity framing**

```bash
git add \
  ProjectScannerCore/Privacy/Fingerprint.swift \
  ProjectScannerCoreTests/Privacy/FingerprintTests.swift
git commit -m "Add private scanner fingerprint framing"
```

### Task 9: Add opaque bookmark access and narrow app platform adapters

**Files:**
- Create: `ProjectScannerCore/Persistence/PrivateStateParentCapability.swift`
- Create: `ProjectScannerCore/Persistence/ProjectBookmark.swift`
- Create: `ProjectScannerCoreTests/Persistence/PrivateStateParentCapabilityTests.swift`
- Create: `ProjectScannerCoreTests/Persistence/ProjectBookmarkTests.swift`
- Create: `Pearcleaner/Logic/ProjectScanner/KeychainProjectKeyStore.swift`
- Create: `Pearcleaner/Logic/ProjectScanner/ProjectScannerEnvironment.swift`
- Create: `Pearcleaner/Logic/ProjectScanner/ScannerDiagnosticsAdapter.swift`
- Create: `PearcleanerTests/ProjectScannerAdapterTests.swift`
- Modify: `ProjectScannerCore/Interfaces/ScannerPlatformServices.swift`
- Modify: `Pearcleaner.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `ProjectKeyMaterial`, `RootCapability`, `ScannerDiagnosticEvent`, and `ScannerDiagnosticSinking` from the core.
- Produces in core: `PrivateStateParentCapability`, opaque `ProjectBookmark`, `ResolvedProjectBookmarkLease`, `ProjectBookmarkAccess`, and internal `BookmarkClient`; core protocols `ProjectKeyMaterialStoring` and `ScannerEnvironmentProviding`. Produces in the app: `KeychainProjectKeyStore`, `ProjectScannerEnvironment`, and `ScannerDiagnosticsAdapter`.

- [ ] **Step 1: Write failing app-adapter tests with injected system clients**

Add app-hosted tests for:

```swift
func testKeychainAddUsesWhenUnlockedThisDeviceOnlyAndDisablesSync() async throws
func testKeychainQueryUsesFixedServiceAccountAndNoAccessGroup() async throws
func testKeychainNotFoundMapsToMissing() async throws
func testKeychainInteractionNotAllowedMapsToUnavailable() async throws
func testKeychainMalformedRecordMapsToInvalidRecordWithoutOverwrite() async throws
func testKeychainDuplicateNeverOverwritesExistingMaterial() async throws
func testPrivateStateParentCapabilityRejectsSymlinkAndIdentityRace() throws
func testEnvironmentPinsApplicationSupportNotAppGroupOrUserDefaults() throws
func testDiagnosticsAdapterForwardsOnlyTypedCodesAndNumbers() async throws
```

In `ProjectBookmarkTests`, add `testCreationUsesReadOnlySecurityScopeAndReturnsOpaqueValue`, `testArbitraryDataCannotConstructABookmark`, `testRoundTripRequiresFreshRootCapabilityOpen`, `testStaleBookmarkIsReportedAndDoesNotAuthorizeRoot`, `testMovedBookmarkedRootKeepsIdentityAfterFreshOpen`, `testReplacementAtFormerBookmarkPathIsNotSilentlyAuthorized`, `testAccessFailureReturnsNoLease`, `testStoredBookmarkBytesStillRequireResolutionValidation`, and `testConcurrentLeaseCloseStopsSecurityScopeExactlyOnce`. Inject `SecItemClient`, `ApplicationSupportLocating`, and `ScannerLogWriting` in app files and internal `BookmarkClient` in the core bookmark file. Tests use recording fakes; they do not write to the developer's real Keychain, security-scope store, or unified log.

- [ ] **Step 2: Add target membership and compiling fail-closed scaffolds**

First prove IDs `A20000000000000000000041` through `A20000000000000000000046` are unused. Add explicit file references and Sources build-phase entries for the three `Pearcleaner/Logic/ProjectScanner` app adapters because `Pearcleaner/Logic` is a manual PBX group. Do not add them to FinderOpen, PearcleanerHelper, PearcleanerSentinel, or the core target.

Then add exact injected protocols and core/app signatures. Return `.unavailable(.systemFailure)` from key operations, throw closed unavailable errors from bookmark/environment operations, and make the diagnostic adapter drop the typed event. Do not call Security, bookmark, filesystem, or OSLog APIs yet. With source membership already present, the next run must fail on scaffold behavior rather than missing app symbols.

- [ ] **Step 3: Run adapter tests to verify behavioral RED**

Run:

```bash
xcodebuild -quiet \
  -project Pearcleaner.xcodeproj \
  -scheme "Pearcleaner Debug" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/ProjectScannerAdapterDerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:PearcleanerTests/ProjectScannerAdapterTests \
  test

xcodebuild -quiet \
  -project Pearcleaner.xcodeproj \
  -scheme ProjectScannerCore \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/ProjectScannerCoreDerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ProjectScannerCoreTests/ProjectBookmarkTests \
  test
```

Expected: the first fixed Keychain-query assertion sees no recorded system call and valid bookmark creation receives the closed scaffold error; no missing-symbol error remains.

- [ ] **Step 4: Define sanitized platform protocols in the core**

```swift
public enum StoredKeyRead: Sendable {
    case found(ProjectKeyMaterial)
    case missing
    case invalidRecord
    case unavailable(KeyStoreUnavailableReason)
}

public enum StoredKeyCreate: Sendable {
    case created(ProjectKeyMaterial)
    case existing(ProjectKeyMaterial)
    case invalidRecord
    case unavailable(KeyStoreUnavailableReason)
}

public protocol ProjectKeyMaterialStoring: Sendable {
    func read() async -> StoredKeyRead
    func createIfMissing(_ material: ProjectKeyMaterial) async -> StoredKeyCreate
}

public protocol ScannerEnvironmentProviding: Sendable {
    func privateStateParent() throws -> PrivateStateParentCapability
}
```

`PrivateStateParentCapability.open(applicationSupportURL:)` uses `lstat`, a no-follow read-only directory open, `fstat`, device/inode/type comparison, effective-user ownership validation, and rejection of group/world-writable mode. It stores only an owned descriptor and immutable identity; no URL or path survives initialization. `KeyStoreUnavailableReason` and environment errors are closed enums without paths, status messages, or underlying errors. Bookmark creation/resolution stays in `ProjectScannerCore/Persistence/ProjectBookmark.swift`; only the injected `BookmarkClient` touches Foundation's path-bearing bookmark APIs, and no raw-data bookmark protocol crosses the public boundary.

- [ ] **Step 5: Implement the fixed Keychain query and record format**

Use `Security` only in `KeychainProjectKeyStore.swift`. The fixed generic-password identity is:

```swift
private let service = "com.lukerow.Pearcleaner.project-scanner.hmac"
private let account = "suppression-v1"
```

The add dictionary contains:

```swift
[
    kSecClass: kSecClassGenericPassword,
    kSecAttrService: service,
    kSecAttrAccount: account,
    kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    kSecAttrSynchronizable: kCFBooleanFalse as Any,
    kSecValueData: encodedRecord
]
```

The read dictionary includes the same class/service/account/synchronizable fields plus `kSecReturnData: true` and `kSecMatchLimit: kSecMatchLimitOne`. It contains no access group. Add uses `ProjectKeyMaterial.secureStorageRecord()` and read uses `ProjectKeyMaterial.init(secureStorageRecord:)`; the core codec owns the exact `0x01 + UUID + 32-byte key` format and rejects every other length/version. Keep the mutable record buffer in the narrowest scope and reset its bytes immediately after `SecItemAdd` returns. Map `errSecItemNotFound` to `.missing`, malformed item bytes to `.invalidRecord`, `errSecInteractionNotAllowed` to `.unavailable(.interactionNotAllowed)`, and all other statuses to `.unavailable(.systemFailure)` without retaining the numeric status in project state or an arbitrary log message. On `errSecDuplicateItem`, read the existing item; never update or replace it automatically, including when that existing item is invalid.

- [ ] **Step 6: Implement opaque bookmark access, environment, and typed logging**

```swift
public struct ProjectBookmark: Sendable, Equatable {
    fileprivate let storage: Data

    fileprivate init(validatedStorage: Data) throws
}

enum ProjectBookmarkPersistence {
    static func encode(_ bookmark: ProjectBookmark) -> Data
    static func decode(_ storage: Data) throws -> ProjectBookmark
}
```

`ProjectBookmark.swift` keeps a versioned envelope in public opaque `ProjectBookmark` with no public raw-data initializer, decoder, property, `Codable` conformance, description, or string conversion. The envelope contains the bounded Foundation bookmark bytes plus the selected root's stable device/inode/type identity; it does not store size, modification time, or status-change time, so a move or ordinary directory-content change does not invalidate the same object. The complete envelope is capped at 1 MiB and strictly length/version validated. A narrow internal `ProjectBookmarkPersistence` bridge in the same file encodes and reconstructs that envelope; Task 12 permits the bridge's production use only from `ProjectState.swift`.

`ProjectBookmarkAccess.create(selectedURL:)` first opens the selection with `RootCapability`, asks its internal `BookmarkClient` for bookmark data using exactly `.withSecurityScope` and `.securityScopeAllowOnlyReadAccess` with no extra resource keys or relative URL, resolves it once, rejects stale data, starts security-scoped access, freshly opens the resolved root, and requires stable device/inode/type equality with the selected root before stopping that validation scope and constructing the envelope. A start-access or identity failure returns no value. Arbitrary bytes can never enter this type through a public API.

`ProjectBookmarkAccess.resolve(_:)` extracts only the envelope's private Foundation bookmark bytes and expected stable identity, rejects staleness without starting scope, calls `startAccessingSecurityScopedResource()`, then immediately calls `RootCapability.open` on the resolved URL and requires device/inode/type equality with the stored identity. A replacement at the former path therefore cannot inherit authority even if a resolver returns it. The method returns a final `ResolvedProjectBookmarkLease` that exposes only the pinned `RootCapability`; it privately retains the URL solely to stop security scope. The lease has lock-protected idempotent `close()` plus `deinit`, and its concurrent-close test proves `stopAccessingSecurityScopedResource()` is called exactly once. No URL or bookmark bytes cross into `SessionStore`, logging, or persistence APIs other than the opaque bookmark's internal encoding.

`ProjectScannerEnvironment.privateStateParent()` asks its injected `ApplicationSupportLocating` only for the user's Application Support directory and immediately passes that URL through `PrivateStateParentCapability.open(applicationSupportURL:)`. It does not append or create scanner directories; Task 11 does that descriptor-relatively from the pinned parent.

It never consults UserDefaults, the app-group container, the selected project, or a cached private-state path.

`ScannerDiagnosticsAdapter` imports OSLog and maps only enum raw values and numeric fields into one static log format using privacy-public interpolation. App-internal `ScannerLogWriting` accepts a typed `ScannerDiagnosticEvent`, not a message string; neither it nor the adapter has a method accepting `String`, `Error`, `URL`, or finding evidence. Tests inject a recording writer and inspect every forwarded field.

- [ ] **Step 7: Run adapter, core, and boundary tests**

Run:

```bash
xcodebuild -quiet \
  -project Pearcleaner.xcodeproj \
  -scheme "Pearcleaner Debug" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/ProjectScannerAdapterDerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:PearcleanerTests/ProjectScannerAdapterTests \
  test

xcodebuild -quiet \
  -project Pearcleaner.xcodeproj \
  -scheme ProjectScannerCore \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/ProjectScannerCoreDerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  test

./script/project_scanner_boundary_checks.sh
```

Expected: app adapters and core tests pass; the core itself still has no Security or OSLog import.

- [ ] **Step 8: Commit the platform boundary**

```bash
git add \
  ProjectScannerCore/Persistence/PrivateStateParentCapability.swift \
  ProjectScannerCore/Persistence/ProjectBookmark.swift \
  ProjectScannerCoreTests/Persistence/PrivateStateParentCapabilityTests.swift \
  ProjectScannerCoreTests/Persistence/ProjectBookmarkTests.swift \
  Pearcleaner/Logic/ProjectScanner/KeychainProjectKeyStore.swift \
  Pearcleaner/Logic/ProjectScanner/ProjectScannerEnvironment.swift \
  Pearcleaner/Logic/ProjectScanner/ScannerDiagnosticsAdapter.swift \
  PearcleanerTests/ProjectScannerAdapterTests.swift \
  ProjectScannerCore/Interfaces/ScannerPlatformServices.swift \
  Pearcleaner.xcodeproj/project.pbxproj
git commit -m "Add scanner platform service adapters"
```

### Task 10: Implement persistent, ephemeral, and reset-required key state

**Files:**
- Create: `ProjectScannerCore/Persistence/ProjectKeyCoordinator.swift`
- Create: `ProjectScannerCoreTests/Support/ScriptedPlatformServices.swift`
- Create: `ProjectScannerCoreTests/Persistence/ProjectKeyCoordinatorTests.swift`
- Modify: `ProjectScannerCore/Interfaces/ScannerPlatformServices.swift`

**Interfaces:**
- Consumes: `ProjectKeyMaterialStoring` and `ProjectKeyMaterial`.
- Produces: `ExistingKeyedState`, `ProjectKeyLease`, `ProjectKeyAccess`, `ProjectKeyRevalidation`, actor `ProjectKeyCoordinator`, `SecureRandomGenerating`, and `UUIDGenerating`.

- [ ] **Step 1: Write failing key-state tests**

Use a scripted store whose reads and creates return an ordered sequence. Add:

```swift
func testFirstUseCreatesOnePersistentKeyAndGeneration() async throws
func testConcurrentFirstUseCreatesAtMostOnePersistentKeyAndGeneration() async throws
func testExistingKeyWithoutProjectStateCanBeReused() async throws
func testMatchingStoredAndKeychainGenerationsPermitPersistence() async throws
func testTemporaryKeychainUnavailabilityReturnsEphemeralLease() async throws
func testEphemeralLeaseCanFingerprintButReportsNoPersistentSuppressionAuthority() async throws
func testMissingKeyForExistingKeyedStateRequiresReset() async throws
func testInvalidKeychainRecordRequiresResetAndNeverCreatesOrOverwrites() async throws
func testGenerationMismatchRequiresReset() async throws
func testMissingKeyForExistingStateNeverCallsCreate() async throws
func testDuplicateCreateLoadsAndUsesTheWinningExistingKey() async throws
func testRevalidationImmediatelyBeforeCommitDetectsGenerationChange() async throws
func testRevalidationUnavailabilityAbortsPersistenceWithoutRequiringReset() async throws
func testGeneratedKeysAreExactlyThirtyTwoRandomBytes() async throws
```

The fake records call order and creation count so “never auto-create replacement” is an observed assertion.

- [ ] **Step 2: Add only the compiling fail-closed coordinator scaffold**

Add the exact lease/access/revalidation/random-source/coordinator signatures. Make every access return `.resetRequired` and every revalidation return `.resetRequired`; do not read or create key material yet.

- [ ] **Step 3: Run key-state tests to verify behavioral RED**

Run:

```bash
xcodebuild -quiet \
  -project Pearcleaner.xcodeproj \
  -scheme ProjectScannerCore \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/ProjectScannerCoreDerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ProjectScannerCoreTests/ProjectKeyCoordinatorTests \
  test
```

Expected: the first-use test receives scaffold `.resetRequired`; no missing-symbol error remains.

- [ ] **Step 4: Define lease and outcome types**

```swift
public enum ExistingKeyedState: Sendable, Equatable {
    case none
    case generation(UUID)
}

public struct ProjectKeyLease: Sendable {
    public enum Persistence: Sendable, Equatable {
        case persistent(generation: UUID)
        case ephemeral
    }

    let material: ProjectKeyMaterial
    public let persistence: Persistence

    public var permitsPersistentState: Bool {
        if case .persistent = persistence { return true }
        return false
    }

    public var permitsPersistentSuppression: Bool {
        permitsPersistentState
    }
}

public enum ProjectKeyAccess: Sendable {
    case ready(ProjectKeyLease)
    case resetRequired
}

public enum ProjectKeyRevalidation: Sendable, Equatable {
    case valid
    case ephemeralOnly
    case resetRequired
}

extension ProjectKeyLease {
    static func persistent(_ material: ProjectKeyMaterial) -> Self {
        Self(
            material: material,
            persistence: .persistent(generation: material.generation)
        )
    }

    static func ephemeral(_ material: ProjectKeyMaterial) -> Self {
        Self(material: material, persistence: .ephemeral)
    }
}
```

An ephemeral lease contains a fresh 32-byte in-memory HMAC key and a random generation used only for that process lifetime. It may create in-memory correlation fingerprints, but both persistent-authority properties are false. No ephemeral material conforms to `Codable`.

- [ ] **Step 5: Implement exact first-use and existing-state behavior**

```swift
public actor ProjectKeyCoordinator {
    public init(store: any ProjectKeyMaterialStoring)

    init(
        store: any ProjectKeyMaterialStoring,
        random: any SecureRandomGenerating,
        uuid: any UUIDGenerating
    )

    public func access(for state: ExistingKeyedState) async throws -> ProjectKeyAccess {
        switch await store.read() {
        case .found(let material):
            switch state {
            case .none:
                return .ready(.persistent(material))
            case .generation(let expected) where expected == material.generation:
                return .ready(.persistent(material))
            case .generation:
                return .resetRequired
            }

        case .missing:
            guard state == .none else { return .resetRequired }
            let proposed = try generateMaterial()
            switch await store.createIfMissing(proposed) {
            case .created(let material), .existing(let material):
                return .ready(.persistent(material))
            case .invalidRecord:
                return .resetRequired
            case .unavailable:
                return .ready(.ephemeral(proposed))
            }

        case .invalidRecord:
            return .resetRequired

        case .unavailable:
            return .ready(.ephemeral(try generateMaterial()))
        }
    }
}
```

Define module-internal throwing `SecureRandomGenerating.bytes(count:)` and `UUIDGenerating.makeUUID()` in the core. The sole public coordinator initializer accepts only the key store and installs file-private production implementations: `SystemRandomNumberGenerator` fills exactly 32 independently generated bytes and the platform UUID generator creates the generation. The core does not import Security or ask the app adapter to create randomness. A module-internal initializer permits deterministic sources only for the named coordinator tests; Task 12 rejects every other call site. `generateMaterial()` rejects a generator result whose count is not exactly 32 with a closed, payload-free coordinator error, and never derives the HMAC key from UUID bytes. `ProjectKeyLease.material` is module-internal, so public callers can pass an opaque lease back to state APIs but cannot extract its key material.

- [ ] **Step 6: Implement immediate pre-persistence revalidation**

`revalidate(_ lease:)` returns `.ephemeralOnly` for an ephemeral lease. For a persistent lease, read Keychain again: matching generation returns `.valid`; temporary unavailability returns `.ephemeralOnly`; missing, invalid-record, or changed generation returns `.resetRequired`. It performs no creation and exposes no key bytes or system error text.

This slice intentionally defines no key/state deletion API: reset is destructive and must be invoked only from the separately reviewed user-confirmation flow in the UI slice. The foundation exposes `.resetRequired`, never repairs automatically, and leaves a generation-bound global reset transaction as an explicit prerequisite of that later flow rather than adding an uncallable or convention-only authorization token here.

- [ ] **Step 7: Run key-state and full core tests**

Run:

```bash
xcodebuild -quiet \
  -project Pearcleaner.xcodeproj \
  -scheme ProjectScannerCore \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/ProjectScannerCoreDerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Expected: all key state transitions and full core tests pass.

- [ ] **Step 8: Commit key coordination**

```bash
git add \
  ProjectScannerCore/Persistence/ProjectKeyCoordinator.swift \
  ProjectScannerCore/Interfaces/ScannerPlatformServices.swift \
  ProjectScannerCoreTests/Support/ScriptedPlatformServices.swift \
  ProjectScannerCoreTests/Persistence/ProjectKeyCoordinatorTests.swift
git commit -m "Add fail-closed scanner key coordination"
```

### Task 11: Persist only the minimal project envelope with atomic generation checks

**Files:**
- Create: `ProjectScannerCore/Persistence/ProjectState.swift`
- Create: `ProjectScannerCore/Persistence/StateFileSystemOperations.swift`
- Create: `ProjectScannerCore/Persistence/BackupExclusion.swift`
- Create: `ProjectScannerCore/Persistence/AtomicStateFile.swift`
- Create: `ProjectScannerCore/Persistence/ProjectStateTransactionLock.swift`
- Create: `ProjectScannerCore/Persistence/ProjectStateStore.swift`
- Create: `ProjectScannerCoreTests/Persistence/AtomicStateFileTests.swift`
- Create: `ProjectScannerCoreTests/Persistence/BackupExclusionTests.swift`
- Create: `ProjectScannerCoreTests/Persistence/ProjectStateStoreTests.swift`
- Create: `ProjectScannerCoreTests/Persistence/PrivacySinkCanaryTests.swift`
- Modify: `ProjectScannerCoreTests/Support/ScriptedPlatformServices.swift`
- Modify: `ProjectScannerCoreTests/Support/PrivacyCanaries.swift`

**Interfaces:**
- Consumes: `ProjectID`, `ScanLimitOverrides`, `ScanCoverageSnapshot`, `SuppressionFingerprint`, `RuleID`, `ProjectKeyLease`, `ProjectKeyCoordinator`, `PrivateStateParentCapability`, `ScannerEnvironmentProviding`, and the internal `UUIDGenerating` boundary.
- Produces internally: `PersistedProjectState`, `PersistedCompleteSummary`, `PersistedAttempt`, `PersistedDetectorCoverage`, closed `StateSyscallSite`, `StateFileSystemOperations`, closed `BackupResourceSite`, `BackupExclusionOperations`, identity-checked `BackupExclusion`, and `AtomicStateFile`.
- Produces publicly: `SuppressionRecord`, `AttemptSummaryMetadata`, `ProjectConfigurationSnapshot`, `ProjectRegistration`, `ProjectStateCommit`, `ProjectStateAccess`, and actor `ProjectStateStore`.

- [ ] **Step 1: Write failing schema, transaction, mode, and privacy tests**

Use a real temporary state root and real bytes on disk. Add:

```swift
func testRegistersMinimalProjectWithBookmarkAsOnlyPathBearingField() async throws
func testStateDirectoryIsMode0700AndFileIsMode0600() async throws
func testExistingOwnerControlled0755PearcleanerParentAllows0700ScannerChild() async throws
func testGroupOrWorldWritablePearcleanerParentIsRejected() async throws
func testStateDirectoryIsExcludedFromBackup() async throws
func testBackupExclusionFollowsThePinnedDirectoryAcrossRename() async throws
func testBackupExclusionRejectsReplacementBeforeFileReferenceValidation() async throws
func testBackupExclusionFailureNeverTouchesOutsideCanary() async throws
func testSymlinkedPearcleanerParentCannotRedirectStateToOutsideCanary() async throws
func testFirstUseFsyncsEachNewDirectoryBeforeItsParent() async throws
func testFirstUseFsyncsNewLockFileBeforeScannerDirectory() async throws
func testCompleteRunAtomicallyUpdatesCompleteSummaryAndAttempt() async throws
func testPartialCancelledFailedAndUnavailableUpdateOnlyLastAttempt() async throws
func testPartialAttemptCannotCarryAnUnrelatedCompleteSummary() async throws
func testPartialAttemptNeverReappearsAsLastCompleteAfterReload() async throws
func testGenerationMismatchBeforeCommitLeavesPriorBytesUnchanged() async throws
func testTemporaryKeychainFailureLeavesPriorBytesUnchanged() async throws
func testPreRenameAtomicWriteFailureLeavesPriorFileReadableAndUnchanged() async throws
func testPostRenameDirectorySyncFailureReportsDurabilityUncertainWithNewFileVisible() async throws
func testTwoIndependentStoresDoNotLoseConcurrentSuppressionsOrSummaryUpdates() async throws
func testScriptedLockContentionIsBoundedAndCancellationAware() async throws
func testEachStateSyscallFailureIsInjectedAtTheNamedSite() async throws
func testEachBackupResourceFailureIsInjectedAtTheNamedSite() async throws
func testCorruptOversizedOrUnknownSchemaStateFailsClosed() async throws
func testUnknownTopLevelAndNestedJSONKeysFailClosed() async throws
func testDestinationSymlinkIsReplacedWithoutTouchingOutsideCanary() async throws
func testStateFileReplacedByFIFOFailsPromptlyWithoutBlocking() async throws
func testLockFileReplacedBySpecialFileFailsPromptlyWithoutBlocking() async throws
func testCrashLeftStagingFilesAreCleanedOnlyUnderTheTransactionLock() async throws
func testMoreThanOneHundredTwentyEightStagingFilesFailsClosed() async throws
func testStateIsNeverWrittenToSelectedRootUserDefaultsOrAppGroup() async throws
func testPersistentBytesExcludeFindingPathPackageVersionAdvisoryScriptAndSecret() async throws
func testLogsErrorsAndTemporaryNamesExcludePrivacyCanaries() async throws
func testSuppressionRecordStoresOnlyFingerprintRuleVersionAndCreationTime() async throws
func testPersistentLoadExposesSuppressionsOnlyAfterGenerationMatch() async throws
func testEphemeralAndResetRequiredLoadsExposeNoApplicableSuppressions() async throws
func testRegistrationGeneratesItsOwnRandomProjectIdentifier() async throws
```

The privacy test decodes the JSON object and permits the user-assigned label only in `label` and path-bearing bytes only in the internal persisted `bookmark` field. Public registration accepts only `ProjectBookmark`; no arbitrary `Data` can masquerade as bookmark authority. The test searches the state file, staging directory, diagnostic events, and failure values for every other canary. It also scans for SQLite/WAL/journal sidecars and fails if any exist because this implementation uses one bounded JSON envelope per project.

- [ ] **Step 2: Add only the compiling fail-closed persistence scaffold**

Add the exact DTO, capability, closed syscall/resource seams, lock, atomic-file, and store signatures. The production operations delegate to Darwin/Foundation, while tests can select one closed `StateSyscallSite` to fail without providing arbitrary paths, descriptors, bytes, or callbacks. Make opening/loading/writing/registering throw `ProjectStateError.notImplemented` before creating a directory or file.

- [ ] **Step 3: Run persistence tests to verify behavioral RED**

Run:

```bash
xcodebuild -quiet \
  -project Pearcleaner.xcodeproj \
  -scheme ProjectScannerCore \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/ProjectScannerCoreDerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ProjectScannerCoreTests/AtomicStateFileTests \
  -only-testing:ProjectScannerCoreTests/BackupExclusionTests \
  -only-testing:ProjectScannerCoreTests/ProjectStateStoreTests \
  -only-testing:ProjectScannerCoreTests/PrivacySinkCanaryTests \
  test
```

Expected: the first registration test receives `.notImplemented` and the temporary state root remains empty; no missing-symbol error remains.

- [ ] **Step 4: Define the strict persisted envelope**

```swift
struct PersistedProjectState: Codable, Sendable, Equatable {
    public let schemaVersion: UInt32
    public let projectID: ProjectID
    public var label: String?
    let bookmark: Data
    public let keyGeneration: UUID
    public var scannerSchemaVersion: UInt32
    public var advisoryCacheSchemaVersion: UInt32?
    public var lastCompleteSummary: PersistedCompleteSummary?
    public var lastAttempt: PersistedAttempt?
    public var limitOverrides: ScanLimitOverrides
    public var watchEnabled: Bool
    var suppressions: [PersistedSuppressionRecord]
}

struct PersistedSuppressionRecord: Codable, Sendable, Equatable {
    let fingerprint: Data
    let ruleID: RuleID
    let ruleVersion: UInt32
    let createdAt: Date
}

public struct SuppressionRecord: Sendable, Equatable {
    public let fingerprint: SuppressionFingerprint
    public let ruleID: RuleID
    public let ruleVersion: UInt32
    public let createdAt: Date
}
```

`PersistedDetectorCoverage` contains only detector ID/state, aggregate file/byte counters, and reason-code counts. `PersistedAttempt` contains timestamp, overall terminal state, sanitized detector coverage, advisory/cache schema/generation/freshness metadata, and no session ID or detailed finding. `PersistedCompleteSummary` has an initializer that accepts a coverage snapshot only when its whole-run state is `.complete`; every other state throws `.notComplete`. The internal DTOs alone store bookmark bytes and fingerprint bytes, reconstructed through the narrow validated bridges from Tasks 8 and 9. `SuppressionRecord`, `ProjectBookmark`, and `SuppressionFingerprint` are not `Codable`.

- [ ] **Step 5: Implement strict schema validation and decoding**

Use strict custom decoding: every persisted DTO first opens a container keyed by dynamic `AnyCodingKey`, compares its raw-string `allKeys` with that DTO's exact static allowlist, and rejects any unknown top-level or nested key. Only then decode values through the typed `CodingKeys` container. Use one explicitly configured JSON codec: sorted keys for deterministic test bytes, dates as integer milliseconds since Unix epoch with checked conversion, and the standard Foundation base64 representation only for the DTO's bookmark/fingerprint byte fields. Reject non-integral, negative, non-finite, or out-of-range dates. Schema version must equal 1; bookmark must be non-empty and no larger than 1 MiB; each fingerprint bridge must validate exactly 32 bytes; label must be at most 200 Unicode scalars and contain no control/bidirectional scalar; suppressions are capped at 10,000; duplicate fingerprints are rejected; all counters and rule versions must be valid. The complete summary's terminal state is structurally fixed to complete.

- [ ] **Step 6: Open and pin the private state directory**

`AtomicStateFile.open(parent:)` duplicates the pinned Application Support descriptor from `PrivateStateParentCapability`. From that descriptor it creates/opens the fixed shared `Pearcleaner` component and then the scanner-exclusive fixed `ProjectScanner` component using descriptor-relative `mkdirat`, no-follow `fstatat`, `openat` with `O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC`, and post-open device/inode/type/owner checks at every hop. Pearcleaner's existing `UndoHistoryManager` may already have created the shared `Pearcleaner` directory with mode 0755, so an existing shared hop is accepted only when it is an effective-user-owned directory with no group/world write bit; do not chmod or otherwise alter it. A newly created shared hop is mode 0700. The dedicated `ProjectScanner` child must be exactly mode 0700 whether new or existing. A symlink, ownership mismatch, identity race, writable shared hop, or non-0700 scanner child fails closed without repair. For a newly created component only, use `fchmod` and re-read metadata so umask cannot weaken its required mode.

After each first-use `mkdirat`, open and verify the new child, `fsync` the child directory, then `fsync` its already-pinned parent before moving to the next component. A newly created `.state.lock` is similarly mode-verified and `fsync`ed before the final scanner directory is `fsync`ed. Any failure makes persistence unavailable; the plan never reports successful durable creation from directory-entry state that was not synchronized.

Set and re-read backup exclusion before accepting the final directory. `BackupExclusion` may use `F_GETPATH` exactly once to obtain an ephemeral bridge URL from the already-verified descriptor, but it immediately converts that URL to Foundation's file-reference URL and discards the path URL. It opens the file-reference URL read-only/no-follow and requires device/inode/type equality with the pinned descriptor before setting `URLResourceKey.isExcludedFromBackupKey`. It clears the cached resource value, reads the key back as `true`, reopens the file reference, and repeats the identity comparison. A replacement before file-reference creation is rejected; a rename after creation follows the original object. There is no pathname fallback. Any unsupported file-reference conversion, set/read failure, identity change, or outside-canary touch makes persistent state unavailable. Retain only the final directory descriptor. Accept only filenames generated as `project-<lowercase UUID>.json`.

Route `fcntl(F_GETPATH)`, path-to-file-reference conversion, reference-URL open/identity verification, backup-key set, resource-cache eviction, backup-key readback, and final reference reopen through internal `BackupExclusionOperations`, each tagged with a closed `BackupResourceSite`. Its production implementation performs only those fixed operations. The scripted test implementation can fail one site or execute the fixed rename/replacement pause, but cannot supply a different URL, key, descriptor, or callback. `BackupExclusionTests` exercises every site and the real rename/replacement integration cases.

- [ ] **Step 7: Implement atomic bounded writes**

Create `ProjectStateTransactionLock` with a process-global actor gate plus a mode-0600 regular lock file named exactly `.state.lock` under the pinned scanner directory. Create it with `O_EXCL` first so first-use durability is observable, otherwise reopen it descriptor-relatively with `O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC`; then require an effective-user-owned regular file with mode exactly 0600 before using it. Acquisition first obtains a cancellation-aware actor permit, then uses `flock(LOCK_EX | LOCK_NB)` retries driven by `ContinuousClock`, checking cancellation at least every 25 ms and stopping after five seconds with the payload-free `.transactionBusy` error. Release unlocks the file and returns the actor permit in `defer`. Unit tests use the closed syscall seam for deterministic busy/cancellation behavior; Task 12 adds a real second-process holder and `SIGKILL` release proof. Every load-mutate-Keychain-revalidate-write transaction holds this lock from its initial read through the commit outcome; no public mutation closure is exposed.

Route every persistence descriptor duplication/close, `mkdirat`, `openat`, `fstatat`, `fstat`, `fchmod`, `read`, `write`, `fsync`, `renameat`, `unlinkat`, `flock`, `fdopendir`, `readdir`, and `closedir` call through internal `StateFileSystemOperations`, tagged with a closed `StateSyscallSite`. The production implementation is a thin EINTR-safe Darwin delegate. `ScriptedStateFileSystemOperations` delegates to the real operation by default and can apply one fixed test outcome at one named site: fail with a selected errno before the call, fail after a successful call, or stop the test process after a successful call. It cannot substitute a state path, state descriptor, data buffer, directory entry, or arbitrary callback. The type and all raw private-state descriptors remain internal to the persistence files and named tests. This seam drives directory-enumeration, cleanup, lock, read/write, every pre/post-commit failure assertion, and the Task 12 crash victim without changing public APIs.

For a write:

1. reject payloads over 8 MiB;
2. create `.state-<random UUID>.tmp` with `openat(rootFD, temporaryNameCString, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)`;
3. call `fchmod(fd, 0o600)`;
4. write all bytes with an EINTR-safe loop;
5. `fsync` the file;
6. `renameat` the temporary name over the destination;
7. `fsync` the directory; and
8. unlink the staging file on every pre-rename failure.

`renameat` is the commit point. A failure before it leaves the prior destination untouched. If `renameat` succeeds but the following directory `fsync` fails, the new file is already visible; return `.committedDurabilityUncertain` rather than throwing an error that implies rollback. A normal write returns `.committed`.

On store open, hold the same transaction lock while boundedly enumerating crash-left staging entries. Remove only effective-user-owned, mode-0600 regular files whose complete name matches `.state-<lowercase UUID>.tmp`; use descriptor-relative metadata/open/unlink checks and never follow a link. Refuse persistent operation if more than 128 matching staging entries exist or any matching entry has an unexpected type, owner, or mode. Unknown non-staging names are left untouched.

- [ ] **Step 8: Implement bounded identity-checked reads**

For a read, use `openat` with `O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC`, require an effective-user-owned regular file, verify mode 0600 and size at most 8 MiB before allocation, read exactly that size, and `fstat` again. Use the same nonblocking flag on speculative staging-file opens. Reject any device, inode, type, size, modification-time, or status-change-time change. FIFO/socket/device replacements therefore fail promptly before any read loop. Errors are closed `ProjectStateError` cases with no associated path, payload, or underlying string.

Do not use `Data.write(.atomic)`, UserDefaults, app-group storage, SQLite, or a project-derived filename.

- [ ] **Step 9: Add the typed project-state API**

Keep raw envelope loading and mutation internal. Expose typed methods rather than a general mutation closure:

```swift
public actor ProjectStateStore {
    public init(
        environment: any ScannerEnvironmentProviding,
        keyCoordinator: ProjectKeyCoordinator
    ) throws

    public func register(
        label: String?,
        bookmark: ProjectBookmark,
        limitOverrides: ScanLimitOverrides,
        lease: ProjectKeyLease
    ) async throws -> ProjectRegistration

    public func recordAttempt(
        projectID: ProjectID,
        coverage: ScanCoverageSnapshot,
        finishedAt: Date,
        metadata: AttemptSummaryMetadata,
        lease: ProjectKeyLease
    ) async throws -> ProjectStateCommit

    public func addSuppression(
        projectID: ProjectID,
        record: SuppressionRecord,
        lease: ProjectKeyLease
    ) async throws -> ProjectStateCommit

    public func loadSummary(
        projectID: ProjectID
    ) throws -> ProjectConfigurationSnapshot?

    public func loadForScan(
        projectID: ProjectID
    ) async throws -> ProjectStateAccess?
}
```

The public initializer calls `environment.privateStateParent()`, opens the fixed descriptor-relative scanner state through `AtomicStateFile.open(parent:)`, and installs the platform UUID generator; it accepts no URL, path, raw descriptor, persistence seam, or caller-selected randomness. Add a module-internal initializer for tests that accepts an already-pinned `PrivateStateParentCapability`, the same `ProjectKeyCoordinator`, `UUIDGenerating`, `StateFileSystemOperations`, and `BackupExclusionOperations`. It feeds those closed dependencies through the same `AtomicStateFile.open` construction path and exposes no public mutation closure or filesystem authority. `ProjectStateStore` creates the random project ID inside `register`; callers cannot supply one. `ProjectRegistration` contains the new project ID, a suppression-free `ProjectConfigurationSnapshot`, and its `ProjectStateCommit`. `ProjectConfigurationSnapshot` exposes the opaque `ProjectBookmark`, never its bytes. The store invokes `ProjectBookmarkPersistence` only while translating to/from its internal DTO. `ProjectStateCommit` is a closed enum with `.committed` and `.committedDurabilityUncertain`; it never carries a path or error string.

`AttemptSummaryMetadata` contains only advisory/cache schema, generation, provenance, freshness, and validation fields approved for persistence. It has no package, version, advisory finding, path, source, or arbitrary-string field.

`loadSummary` returns label, bookmark, sanitized summaries, validated limits, and watch preference, but no suppression record. `loadForScan` loads the envelope internally and calls `ProjectKeyCoordinator.access(for: .generation(envelope.keyGeneration))`. Its closed result is:

```swift
public enum ProjectStateAccess: Sendable {
    case persistent(
        ProjectConfigurationSnapshot,
        suppressions: [SuppressionRecord],
        lease: ProjectKeyLease
    )
    case ephemeral(
        ProjectConfigurationSnapshot,
        lease: ProjectKeyLease
    )
    case resetRequired(ProjectConfigurationSnapshot)
}
```

Only `.persistent` exposes applicable suppressions, and it asserts the returned lease generation matches the envelope. Ephemeral and reset-required cases expose no suppression array or fingerprint.

- [ ] **Step 10: Enforce generation checks and complete-summary rules**

Every write requires a persistent lease whose generation equals the envelope. Immediately before calling `AtomicStateFile.write`, call `ProjectKeyCoordinator.revalidate(lease)` and proceed only on `.valid`. `.ephemeralOnly` throws `.ephemeralRun`; `.resetRequired` throws `.keyResetRequired`. `recordAttempt` constructs `PersistedAttempt` itself from the one supplied `ScanCoverageSnapshot`. It derives and replaces `lastCompleteSummary` only when that same snapshot's whole-run state is `.complete`; all other terminal states replace only `lastAttempt`. Every thrown pre-commit failure leaves the prior file untouched; a post-rename directory-sync failure returns `.committedDurabilityUncertain` with the new envelope visible.

The transaction lock spans the initial envelope read, mutation, immediate Keychain revalidation, encoding, and `AtomicStateFile.write`. Two independently constructed stores therefore cannot overwrite each other's suppression or restore an older summary. The concurrency test uses two real stores pointing at the same pinned directory, not a mocked commit callback.

- [ ] **Step 11: Run persistence, privacy, full core, and structural checks**

Run:

```bash
xcodebuild -quiet \
  -project Pearcleaner.xcodeproj \
  -scheme ProjectScannerCore \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/ProjectScannerCoreDerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  test

./script/project_scanner_boundary_checks.sh
```

Expected: all state, privacy, and core tests pass; project and outside-canary snapshots remain unchanged.

- [ ] **Step 12: Commit minimal atomic state**

```bash
git add \
  ProjectScannerCore/Persistence/ProjectState.swift \
  ProjectScannerCore/Persistence/StateFileSystemOperations.swift \
  ProjectScannerCore/Persistence/BackupExclusion.swift \
  ProjectScannerCore/Persistence/AtomicStateFile.swift \
  ProjectScannerCore/Persistence/ProjectStateTransactionLock.swift \
  ProjectScannerCore/Persistence/ProjectStateStore.swift \
  ProjectScannerCoreTests/Persistence/AtomicStateFileTests.swift \
  ProjectScannerCoreTests/Persistence/BackupExclusionTests.swift \
  ProjectScannerCoreTests/Persistence/ProjectStateStoreTests.swift \
  ProjectScannerCoreTests/Persistence/PrivacySinkCanaryTests.swift \
  ProjectScannerCoreTests/Support/ScriptedPlatformServices.swift \
  ProjectScannerCoreTests/Support/PrivacyCanaries.swift
git commit -m "Persist minimal project scanner state"
```

### Task 12: Add real mount-boundary and repository-wide release gates

**Files:**
- Create: `ProjectScannerCoreTests/Containment/MountBoundaryIntegrationTests.swift`
- Create: `ProjectScannerCoreTests/Persistence/StateProcessBoundaryTests.swift`
- Create: `script/test_project_scanner_mount_boundary.sh`
- Create: `script/test_project_scanner_persistence_boundaries.sh`
- Create: `script/test_project_scanner_boundary_checks.sh`
- Create: `script/fixtures/project_scanner_lock_holder.swift`
- Create: `script/fixtures/project_scanner_api_boundaries/ValidImport.swift`
- Create: `script/fixtures/project_scanner_api_boundaries/ProjectKeyMaterialCodable.swift`
- Create: `script/fixtures/project_scanner_api_boundaries/ProjectKeyMaterialStringConvertible.swift`
- Create: `script/fixtures/project_scanner_api_boundaries/ProjectKeyLeaseMaterial.swift`
- Create: `script/fixtures/project_scanner_api_boundaries/SuppressionFingerprintCodable.swift`
- Create: `script/fixtures/project_scanner_api_boundaries/SuppressionRecordCodable.swift`
- Create: `script/fixtures/project_scanner_api_boundaries/SuppressionFingerprintRawProperty.swift`
- Create: `script/fixtures/project_scanner_api_boundaries/SuppressionFingerprintRawInitializer.swift`
- Create: `script/fixtures/project_scanner_api_boundaries/ProjectBookmarkCodable.swift`
- Create: `script/fixtures/project_scanner_api_boundaries/ProjectBookmarkRawProperty.swift`
- Create: `script/fixtures/project_scanner_api_boundaries/ProjectBookmarkRawInitializer.swift`
- Create: `script/fixtures/project_scanner_api_boundaries/RedactedSourceFieldPublicInit.swift`
- Create: `script/fixtures/project_scanner_api_boundaries/CoverageTerminalSetter.swift`
- Create: `script/fixtures/project_scanner_api_boundaries/RootCapabilityRawDescriptor.swift`
- Create: `script/fixtures/project_scanner_api_boundaries/InputBudgetRawMaxima.swift`
- Create: `script/fixtures/project_scanner_api_boundaries/SessionFindingCodable.swift`
- Create: `script/fixtures/project_scanner_api_boundaries/SessionStoreRawData.swift`
- Create: `script/fixtures/project_scanner_api_boundaries/SessionStoreRawString.swift`
- Modify: `script/project_scanner_boundary_checks.sh`
- Modify: `.github/workflows/build.yml`

**Interfaces:**
- Consumes: complete `ProjectScannerCore` and app adapters from Tasks 1-11.
- Produces: real mounted-filesystem, cross-process lock, and crash-recovery proofs; stricter static/API/target-graph gates; additive CI coverage; and final slice-1 verification evidence.

- [ ] **Step 1: Write the opt-in mounted-filesystem integration test**

This is acceptance proof for the mount-device rejection implemented in Task 5; it adds no new production behavior.

The test requires `PROJECT_SCANNER_MOUNT_FIXTURE_ROOT` and `PROJECT_SCANNER_MOUNT_CANARY`. If either is absent, it throws `XCTSkip` for ordinary local core-test runs. When present, it opens the fixture root, traverses all events, and asserts:

```swift
XCTAssertTrue(events.contains { event in
    if case .skipped(_, .mountBoundary) = event { return true }
    return false
})
XCTAssertFalse(admittedBuffers.contains { $0.range(of: canaryData) != nil })
```

It also compares a project snapshot before and after and fails if any file changed.

- [ ] **Step 2: Create the real APFS mount harness**

```bash
#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/project-scanner-mount.XXXXXX)"
FIXTURE="$WORK/root"
MOUNT="$FIXTURE/mounted"
IMAGE="$WORK/mount.dmg"
CANARY="PROJECT_SCANNER_EXTERNAL_MOUNT_CANARY_7F6B9A2D"
SOURCE_PACKAGES="${PROJECT_SCANNER_SOURCE_PACKAGES:-$ROOT/.build/SourcePackages}"
ATTACH_LOG="$WORK/attach.log"
ATTACHED_DEVICE=""

is_mount_active() {
    /sbin/mount | /usr/bin/grep -F " on $MOUNT (" >/dev/null
}

cleanup() {
    local command_status=$?
    if [[ -z "$ATTACHED_DEVICE" && -f "$ATTACH_LOG" ]]; then
        ATTACHED_DEVICE="$(awk '/^\/dev\// { device = $1 } END { print device }' "$ATTACH_LOG")"
    fi
    if [[ -n "$ATTACHED_DEVICE" ]] || is_mount_active; then
        if ! hdiutil detach "${ATTACHED_DEVICE:-$MOUNT}" >/dev/null; then
            echo "could not detach scanner test image; retained fixture at $WORK" >&2
            exit 1
        fi
    fi
    if is_mount_active || hdiutil info | /usr/bin/grep -F "$IMAGE" >/dev/null; then
        echo "scanner test image may still be attached; retained fixture at $WORK" >&2
        exit 1
    fi
    [[ "$WORK" == /tmp/project-scanner-mount.* && -d "$WORK" ]] || exit 1
    rm -rf "$WORK"
    exit "$command_status"
}
trap cleanup EXIT

mkdir -p "$MOUNT"
hdiutil create -quiet -size 64m -fs APFS -volname ProjectScannerBoundary "$IMAGE"
hdiutil attach -nobrowse -mountpoint "$MOUNT" "$IMAGE" > "$ATTACH_LOG"
ATTACHED_DEVICE="$(awk -v mount_point="$MOUNT" '$NF == mount_point { print $1 }' "$ATTACH_LOG")"
[[ -n "$ATTACHED_DEVICE" ]] && is_mount_active \
    || { echo "scanner test image did not mount as expected" >&2; exit 1; }
printf '%s' "$CANARY" > "$MOUNT/canary.txt"

PROJECT_SCANNER_MOUNT_FIXTURE_ROOT="$FIXTURE" \
PROJECT_SCANNER_MOUNT_CANARY="$CANARY" \
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
  test
```

Run `chmod +x script/test_project_scanner_mount_boundary.sh`. The script treats image creation, attach, test, or detach failure as a failed gate; only the ordinary test suite may skip when the environment variables are absent. Before any recursive cleanup it independently checks the live mount table and `hdiutil info`; a partial attach or detach uncertainty deliberately retains the exact disposable fixture instead of deleting a possibly mounted tree.

- [ ] **Step 3: Write the failing negative boundary suite before strengthening the checker**

Create `test_project_scanner_boundary_checks.sh`. It builds a fresh exact `mktemp -d /tmp/project-scanner-boundary.XXXXXX` fixture per case, copies only the core/test source trees and `project.pbxproj`, and runs the current checker with `PROJECT_SCANNER_BOUNDARY_ROOT` pointing at that fixture. Add trap cleanup with the same validated-temp guard used by the mount script. This mutation/meta-suite covers only source, PBX, and static-checker invariants; it does not claim to typecheck the compiled-module API fixtures without a built-products directory.

The baseline fixture must pass. Then independently inject one violation at a time and require a non-zero status plus its exact closed gate message for every source/PBX/static invariant listed in Step 4, including every PBX reference-resolution break, raw project-descriptor access outside the broker file, a speculative regular-file open missing `O_NONBLOCK`, `ScanLimits(` construction or `.hardCeilings` use outside `ScanLimits.swift`, redaction construction outside the redactor file, generic fingerprint identity API, persistence-bridge call outside `ProjectState.swift`, replacement budget constructor, and coverage terminal-state setter. A checker parse error never counts as detecting the injected violation. The direct built-products checker invocation in Step 4, CI, and the local matrix separately baseline-loads `ValidImport.swift` and requires every compile-fail public API fixture to be rejected independently.

Run `chmod +x script/test_project_scanner_boundary_checks.sh`, then run the negative suite against the Task 1 checker before implementing the new rules. Expected: the suite itself fails with `expected rejection did not occur` for the first newly specified invariant. Preserve that RED evidence; do not weaken a fixture or expected message to make the test pass.

- [ ] **Step 4: Strengthen static, API, and target-graph boundary checks**

Extend `project_scanner_boundary_checks.sh` to verify:

```text
ProjectScannerCore packageProductDependencies is empty.
ProjectScannerCoreTests depends on ProjectScannerCore.
Pearcleaner depends on and links ProjectScannerCore.
FinderOpen, PearcleanerHelper, and PearcleanerSentinel do not depend on or link ProjectScannerCore.
Every dependency, proxy, build phase, build file, and product reference used for those claims resolves exactly once.
ProjectScannerCore production imports are a subset of Foundation, CryptoKit, and Darwin.
ProjectScannerCoreTests imports ProjectScannerCore and never Pearcleaner.
Project project-content descriptors and Darwin traversal/read calls occur only in ProjectFileBroker.swift.
RootCapability.makeFileBroker is a tested one-shot descriptor transfer and has no production call site until a reviewed core scan orchestrator is added.
FileBroker.makeTraversal is a tested one-shot traversal/counter authority.
Private-state descriptor/syscall seams occur only in the named Persistence files and tests.
Containment files contain no write-capable open flag.
Every speculative untrusted regular-file open in containment or private state includes O_NONBLOCK before post-open type validation.
Core production files contain none of the execution, network, helper, shared-defaults, app-group, or arbitrary-string logging symbols from Global Constraints.
InputBudget has only the validated-limits initializer, is created once by FileBroker, and cannot be supplied to a public API.
ScanLimits construction occurs only in ScanLimits.swift through defaults, hard ceilings, and validated overrides.
ProjectKeyCoordinator's public initializer accepts only the key store; deterministic RNG/UUID injection is limited to its implementation and named tests.
Coverage has no caller-set complete/partial terminal operation or runtime detector-disable operation.
RedactedSourceField construction occurs only in PrivacyRedactor.swift in production.
Session public APIs accept no raw String or Data snippet, and session finding types are not Codable.
ProjectBookmark, SuppressionFingerprint, and SuppressionRecord are non-Codable; the opaque types expose no raw storage or initializer.
ProjectKeyLease exposes no key material.
Bookmark/fingerprint persistence bridges are called only by ProjectState.swift in production.
There is no generic detector suppression-identity input or encoder.
FramedMACTestSupport and the RFC helper have no production call site in this detector-free slice.
Fingerprint framing incrementally authenticates a non-owning borrowed-field view; it has no full-frame accumulator or borrowed-field Data copy.
PrivacyRedactor has no source-copying Data.subdata, Data slice materialization, or whole-input String(data:) path.
```

Parse named targets from `PBXNativeTarget`, then resolve rather than grep their referenced IDs. For each `dependencies` ID, require exactly one `PBXTargetDependency`; resolve its direct `target` or its `PBXContainerItemProxy.remoteGlobalIDString` to exactly one native target. Resolve every `buildPhases` ID exactly once to its correct `PBXSourcesBuildPhase`, `PBXFrameworksBuildPhase`, `PBXResourcesBuildPhase`, or copy-files subtype. Then locate the one frameworks phase and resolve each referenced `PBXBuildFile` and its `fileRef` or `productRef` through to the core static-library product. Fail on an absent, duplicate, dangling, or wrong-kind ID. Require the app and test target edges to resolve to `ProjectScannerCore`, and require the helper, Sentinel, and Finder targets to resolve to no core edge. Do not reject the app adapter's intentional Security/OSLog imports or the persistence writer's private-state write flags.

Iterate every core `import` line through a `case` allowlist of `Foundation`, `CryptoKit`, and `Darwin`; reject all other imports. The raw-project-access gate allows `open`, `openat`, `read`, `readdir`, `fstatat`, `readlinkat`, project `Int32` wrappers, and project descriptor duplication only in `ProjectFileBroker.swift`; the separately named persistence files are allowlisted solely for private Application Support state. Reject every `ScanLimits(` construction and every `.hardCeilings` reference outside `ScanLimits.swift` and the named limit tests. Limit `FileBrokerTestControl`, `ContentBrokerTestControl`, `StateFileSystemOperations`, and `BackupExclusionOperations` references to their owning production file and exact test files. Require the explicit `fileprivate init(validatedText:)` and reject every other production `RedactedSourceField(` call site. Reject production calls to `FramedMACTestSupport` or the RFC helper, and reject either persistence bridge outside its allowlist.

When passed a built-products directory, first typecheck `ValidImport.swift` successfully with `xcrun swiftc -typecheck -I "$PRODUCTS_DIR"`. Then require every negative fixture to fail independently. This proves the module is loadable before treating failure as evidence of an absent API.

Use one fixture per invariant, with these representative shapes (the remaining raw bookmark/fingerprint and session fixtures follow the same one-violation rule):

```swift
// ValidImport.swift
import ProjectScannerCore
func acceptsProjectIDType(_ type: ProjectID.Type) {}

// ProjectKeyMaterialCodable.swift
import ProjectScannerCore
func requiresCodable<T: Codable>(_ type: T.Type) {}
func misuse() { requiresCodable(ProjectKeyMaterial.self) }

// ProjectKeyMaterialStringConvertible.swift
import ProjectScannerCore
func requiresStringConvertible<T: CustomStringConvertible>(_ type: T.Type) {}
func misuse() { requiresStringConvertible(ProjectKeyMaterial.self) }

// ProjectKeyLeaseMaterial.swift
import ProjectScannerCore
func misuse(_ lease: ProjectKeyLease) { _ = lease.material }

// SuppressionFingerprintCodable.swift
import ProjectScannerCore
func requiresCodable<T: Codable>(_ type: T.Type) {}
func misuse() { requiresCodable(SuppressionFingerprint.self) }

// SuppressionFingerprintRawProperty.swift
import ProjectScannerCore
func misuse(_ value: SuppressionFingerprint) { _ = value.bytes }

// SuppressionFingerprintRawInitializer.swift
import Foundation
import ProjectScannerCore
func misuse(_ bytes: Data) { _ = try? SuppressionFingerprint(validatedBytes: bytes) }

// ProjectBookmarkCodable.swift
import ProjectScannerCore
func requiresCodable<T: Codable>(_ type: T.Type) {}
func misuse() { requiresCodable(ProjectBookmark.self) }

// ProjectBookmarkRawProperty.swift
import ProjectScannerCore
func misuse(_ value: ProjectBookmark) { _ = value.storage }

// ProjectBookmarkRawInitializer.swift
import Foundation
import ProjectScannerCore
func misuse(_ bytes: Data) { _ = try? ProjectBookmark(validatedStorage: bytes) }

// CoverageTerminalSetter.swift
import ProjectScannerCore
func misuse(_ ledger: CoverageLedger, _ transaction: CoverageTransactionID) async throws {
    try await ledger.close(transaction, as: .complete)
}

// RootCapabilityRawDescriptor.swift
import ProjectScannerCore
func misuse(_ root: RootCapability) throws { _ = try root.duplicateDescriptor() }

// InputBudgetRawMaxima.swift
import ProjectScannerCore
func misuse() { _ = InputBudget(maximumInputBytes: 1, maximumRetainedBytes: 1) }

// RedactedSourceFieldPublicInit.swift
import ProjectScannerCore
func misuse() { _ = RedactedSourceField(validatedText: "raw") }
```

Keep the separate `SessionFindingCodable`, `SessionStoreRawData`, and `SessionStoreRawString` fixtures from the file list. Run the now-strengthened negative suite and the checker against the built module. Expected: the baseline and valid import pass, every isolated negative case fails for its intended reason, and the suite is green.

- [ ] **Step 5: Prove real cross-process locking and crash recovery**

Create `StateProcessBoundaryTests.swift` with opt-in tests gated by exact environment variables. `script/test_project_scanner_persistence_boundaries.sh` runs `xcodebuild build-for-testing` once into a shared derived-data directory, then invokes each parent, crash-victim, and recovery case with `test-without-building` against that same build and package cache. It compiles `project_scanner_lock_holder.swift` into a validated `mktemp -d /tmp/project-scanner-process.XXXXXX` directory and passes only that helper path plus a disposable state root to the tests. The helper opens the exact test-created `.state.lock`, acquires `flock(LOCK_EX)`, writes a fixed ready byte, and blocks. The test proves a separately running process forces the five-second typed timeout, cancellation still completes within 500 ms, and `SIGKILL` of the holder releases the kernel lock so a later transaction succeeds. Same-process descriptors are not accepted as this proof.

For crash recovery, the script launches the exact crash-victim XCTest in a child `xcodebuild` with a shared disposable state root, one closed `StateSyscallSite`, and a PID-file path. At test start the victim writes only its own PID to that test-control file. `ScriptedStateFileSystemOperations` then performs real syscalls and raises `SIGSTOP` immediately after (a) temporary-file `fsync` but before `renameat`, and (b) `renameat` but before directory `fsync`. The parent validates that the PID belongs to the expected test executable and is stopped, sends `SIGKILL`, requires the victim build to fail, and starts a fresh recovery test on the same root. The pre-rename case must expose the whole old envelope and clean only the valid staging file while holding the real transaction lock. The post-rename case must expose the whole new envelope, never torn JSON. Both cases verify mode/owner, leave the outside canary unchanged, and prove a subsequent durable commit succeeds. The core/app never imports `Process`; process control exists only in this test and script.

Run `chmod +x script/test_project_scanner_persistence_boundaries.sh` and execute it. Any compile, readiness, PID-validation, signal, timeout, recovery, or cleanup failure fails the gate; cleanup refuses recursive deletion unless the exact validated temp prefix and live child/process checks are clear.

- [ ] **Step 6: Add scanner gates to CI without removing existing checks**

In `.github/workflows/build.yml`, after dependency resolution and before the app Debug build, add:

```yaml
      - name: Test ProjectScannerCore
        run: >-
          xcodebuild -quiet
          -project Pearcleaner.xcodeproj
          -scheme ProjectScannerCore
          -configuration Debug
          -destination 'platform=macOS'
          -derivedDataPath "$CI_DERIVED_DATA"
          -clonedSourcePackagesDirPath "$CI_SOURCE_PACKAGES"
          -disableAutomaticPackageResolution
          CODE_SIGNING_ALLOWED=NO
          test

      - name: Test ProjectScannerCore with Thread Sanitizer
        run: >-
          xcodebuild -quiet
          -project Pearcleaner.xcodeproj
          -scheme ProjectScannerCore
          -configuration Debug
          -destination 'platform=macOS'
          -derivedDataPath .build/ScannerTSANDerivedData
          -clonedSourcePackagesDirPath "$CI_SOURCE_PACKAGES"
          -disableAutomaticPackageResolution
          -enableThreadSanitizer YES
          CODE_SIGNING_ALLOWED=NO
          test

      - name: Test scanner persistence process boundaries
        env:
          PROJECT_SCANNER_SOURCE_PACKAGES: ${{ env.CI_SOURCE_PACKAGES }}
        run: ./script/test_project_scanner_persistence_boundaries.sh

      - name: Test scanner mount boundary
        env:
          PROJECT_SCANNER_SOURCE_PACKAGES: ${{ env.CI_SOURCE_PACKAGES }}
        run: ./script/test_project_scanner_mount_boundary.sh

      - name: Verify scanner API and dependency boundaries
        run: >-
          ./script/project_scanner_boundary_checks.sh
          "$CI_DERIVED_DATA/Build/Products/Debug"

      - name: Test scanner boundary checks
        run: ./script/test_project_scanner_boundary_checks.sh
```

Keep the existing app test, security regression check, analyzer, and arm64/x86_64 Release builds unchanged.

- [ ] **Step 7: Run the complete local verification matrix**

Run:

```bash
xcodebuild \
  -resolvePackageDependencies \
  -project Pearcleaner.xcodeproj \
  -scheme "Pearcleaner Debug" \
  -clonedSourcePackagesDirPath .build/SourcePackages

xcodebuild -quiet \
  -project Pearcleaner.xcodeproj \
  -scheme ProjectScannerCore \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/ProjectScannerCoreDerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  test

xcodebuild -quiet \
  -project Pearcleaner.xcodeproj \
  -scheme "Pearcleaner Debug" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/ProjectScannerAppDerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  test

xcodebuild -quiet \
  -project Pearcleaner.xcodeproj \
  -scheme ProjectScannerCore \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/ProjectScannerTSANDerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution \
  -enableThreadSanitizer YES \
  CODE_SIGNING_ALLOWED=NO \
  test

./script/security_regression_checks.sh
./script/project_scanner_boundary_checks.sh \
  .build/ProjectScannerCoreDerivedData/Build/Products/Debug
./script/test_project_scanner_boundary_checks.sh
./script/test_project_scanner_persistence_boundaries.sh
./script/test_project_scanner_mount_boundary.sh

xcodebuild -quiet \
  -project Pearcleaner.xcodeproj \
  -scheme "Pearcleaner Debug" \
  -configuration Debug \
  -destination 'generic/platform=macOS' \
  -derivedDataPath .build/ProjectScannerAnalyzeDerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  analyze

xcodebuild -quiet \
  -project Pearcleaner.xcodeproj \
  -scheme "Pearcleaner Release" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath .build/ProjectScannerReleaseArmDerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=NO \
  ARCHS=arm64 \
  build

xcodebuild -quiet \
  -project Pearcleaner.xcodeproj \
  -scheme "Pearcleaner Release" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath .build/ProjectScannerReleaseIntelDerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=NO \
  ARCHS=x86_64 \
  build

SLICE_BASE="$(git rev-parse HEAD~11)"
git diff --check "$SLICE_BASE"
```

Expected: core and app tests pass; the full core suite is race-free under Thread Sanitizer; the real mount, second-process lock, and crash-recovery gates pass without reading either outside canary; all structural/security scripts pass; analysis succeeds; both Release architectures build; and the diff check is empty. No visual check is required because this slice adds no UI.

- [ ] **Step 8: Inspect the complete diff against scope**

Run:

```bash
SLICE_BASE="$(git rev-parse HEAD~11)"
git status --short
git diff --name-status "$SLICE_BASE"
git diff "$SLICE_BASE" -- ProjectScannerCore ProjectScannerCoreTests Pearcleaner/Logic/ProjectScanner PearcleanerTests/ProjectScannerAdapterTests.swift script .github/workflows/build.yml Pearcleaner.xcodeproj
```

Expected: only the files enumerated by this plan have changed. The existing `.superpowers/`, brainstorm, and unrelated plan files remain unstaged and untouched. There are no changes to views, resources, entitlements, helper, Sentinel, FinderOpen, remote dependency versions, naming, navigation, or release publication.

- [ ] **Step 9: Commit the release gates**

```bash
git add \
  ProjectScannerCoreTests/Containment/MountBoundaryIntegrationTests.swift \
  ProjectScannerCoreTests/Persistence/StateProcessBoundaryTests.swift \
  script/test_project_scanner_mount_boundary.sh \
  script/test_project_scanner_persistence_boundaries.sh \
  script/test_project_scanner_boundary_checks.sh \
  script/fixtures/project_scanner_lock_holder.swift \
  script/fixtures/project_scanner_api_boundaries \
  script/project_scanner_boundary_checks.sh \
  .github/workflows/build.yml
git commit -m "Add scanner foundation verification gates"
```

- [ ] **Step 10: Verify the complete twelve-commit slice**

```bash
FINAL_SLICE_BASE="$(git rev-parse HEAD~12)"
git log --oneline --reverse "$FINAL_SLICE_BASE"..HEAD
git diff --check "$FINAL_SLICE_BASE" HEAD
git diff --name-status "$FINAL_SLICE_BASE" HEAD
git status --short
```

Expected: exactly the twelve task commits appear in order; the complete committed diff is whitespace-clean and contains only planned files. Pre-existing untracked design material remains untracked.

## Slice completion contract

Slice 1 is complete only when all twelve task commits are present and the full Task 12 verification matrix passes. At that point Pearcleaner has an internal, read-only scanner foundation and platform boundary, but no scanner UI or detector is usable by a person. Begin the separately reviewed slice-2 plan only after reviewing the actual slice-1 diff, dependency graph, filesystem behavior, persistence bytes, test evidence, and signed-product implications.
