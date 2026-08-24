# Project Scanner Slice 2 — Git Evidence and Secret Detection Implementation Plan

**Date:** 2026-08-24
**Status:** Approved implementation plan
**Prerequisite:** Project Scanner Foundation (slice 1) merged at `eb5a627` or later
**Reviewer:** Luke

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver slice 2 of the Developer Exposure Inspector: a production-signed Git feasibility gate, a versioned secret detector with correlation identities, metadata-only Git descriptor collection, a sandboxed Git-evidence XPC service with a minimal signed runner, and a hardened Git evidence provider — all headless and without product UI.

**Architecture:** Slice 2 extends `ProjectScannerCore` with `SecretDetector`, `GitIgnoreClassifier`, `GitRepositoryPreflight`, `GitEvidenceProvider`, and a minimal `ScanCoordinator` that orchestrates working-tree enumeration, secret matching, and Git index/`HEAD` evidence when an allowlisted OS/arch tuple passes the signed feasibility registry. Git execution stays outside the core: two new signed targets (`GitRunner`, `GitEvidenceService`) plus narrow app adapters that own `NSXPCConnection`, code signing, and entitlements. Production Git evidence code may land only after the disposable signed feasibility harness archives passing evidence for the exact tuple being enabled.

**Tech Stack:** Swift 5, XCTest, Foundation, CryptoKit, Darwin/POSIX, Security (app/service targets only), XPC, App Sandbox, Xcode embedded XPC service packaging, existing `ProjectScannerCore` foundation from slice 1

**Spec:** `docs/superpowers/specs/2026-08-23-developer-exposure-inspector-design.md` (§10 Git evidence, §11.1 Secret detector, §22 step 2)

## Global Constraints

- Deployment target remains macOS 13.0; build requires Xcode with the macOS 26 SDK.
- Dependency direction remains `Pearcleaner -> ProjectScannerCore` only. `ProjectScannerCore` must not import AppKit, SwiftUI, Security, OSLog, `NSXPCConnection`, helper/Sentinel clients, or third-party parsers.
- `ProjectScannerCore` still launches no child process directly. Its sole permitted process boundary is the injected `GitEvidenceExecuting` protocol implemented by a narrow app adapter that talks to `GitEvidenceService`.
- **Signed feasibility gate (§10.5):** the first deliverable is a disposable, production-signed harness. Git evidence is enabled only for an exact OS-version/architecture tuple archived by that harness. Untested, expired, or failed tuples default to Git unavailable. No direct main-process Git, libgit2, live repository configuration, bookmarks, directory grants, or weaker fallback.
- Git metadata descriptors are read-only regular files opened through `ProjectFileBroker`; at most 1,024 descriptors per operation with a 128-descriptor reserve below `RLIMIT_NOFILE`; batches of at most 32; operations serialized per repository.
- Allowed Git operations are fixed equivalents of `git ls-files`, `git ls-tree -r -z`, and `git cat-file` batch only, using a service-authored synthetic administrative view and `/usr/bin/git` to the verified Apple-signed system image.
- Git-evidence service sandbox: no user-selected-file, bookmark, Full Disk Access, network, automation, app-group, or privileged-helper entitlement. Runner inherits sandbox and may transition only to `/usr/bin/git`.
- Secret detector: versioned rule pack; standalone entropy never creates a finding; raw match bytes exist only in bounded input buffers; all presentation flows through `PrivacyRedactor`; correlation uses keyed in-memory identities via extended fingerprint encoders in `Fingerprint.swift`.
- Git evidence covers working tree, current index, and current `HEAD` snapshot only — no history traversal.
- This slice exposes no product UI, navigation, rebranding, advisory updater, lockfile parsers, lifecycle detector, FSEvents watcher, or remediation command UI.
- Only a complete whole-run result may replace `lastCompleteSummary`; Git partial/unavailable never masquerades as complete.
- Existing slice-1 CI gates, security regression checks, static analysis, and arm64/x86_64 Release builds remain required and receive additive checks.

## File and target map

Create these targets:

```text
GitRunner                         signed command-line tool, App Sandbox + inheritance
GitEvidenceService                embedded XPC service, restrictive App Sandbox
GitFeasibilityHarness             disposable signed app/service bundle for §10.5 evidence
```

Create these source trees:

```text
ProjectScannerCore/
  Git/
    GitRepositoryPreflight.swift       bounded .git layout/config validation
    GitMetadataDescriptor.swift        typed roles, identities, manifest caps
    GitIgnoreClassifier.swift          native bounded ignore grammar
    GitEvidenceModels.swift            operations, facts, preflight outcomes
    GitEvidenceProvider.swift          descriptor open, invoke executor, revalidate
  Detectors/
    SecretRulePack.swift               versioned rules, structural checks
    SecretDetector.swift               streaming matcher over ContentBroker leases
    SecretMatchIdentity.swift          in-memory correlation identity
    SecretMatchCorrelator.swift        working tree vs index vs HEAD
  Orchestration/
    ScanCoordinator.swift              headless session owner, cancellation, budgets

ProjectScannerCoreTests/
  Git/
    GitRepositoryPreflightTests.swift
    GitIgnoreClassifierGoldenTests.swift
    GitEvidenceProviderTests.swift
  Detectors/
    SecretRulePackTests.swift
    SecretDetectorCorpusTests.swift
    SecretMatchCorrelatorTests.swift
  Orchestration/
    ScanCoordinatorIntegrationTests.swift
  Privacy/
    SecretFingerprintTests.swift

GitEvidenceShared/
  GitEvidenceXPCProtocol.swift         shared protocol + operation enums (no AppKit)

GitRunner/
  main.swift                           exec transition to /usr/bin/git
  GitRunnerProcessProfile.swift        FD hygiene, CLOEXEC, allowlisted inheritance

GitEvidenceService/
  main.swift                           XPC listener
  GitEvidenceServiceDelegate.swift
  GitSyntheticAdminView.swift          service-authored GIT_DIR layout
  GitOperationSupervisor.swift         spawn runner, drain pipes, timeout/kill
  GitOutputParser.swift                NUL-framed path/OID validation

GitFeasibilityHarness/
  HarnessApp.swift                     launches scenarios, writes evidence bundle
  Scenarios/
    DescriptorTransferScenario.swift
    SandboxDenialScenario.swift
    GitTransitionScenario.swift
    CleanupScenario.swift

Pearcleaner/Logic/ProjectScanner/
  GitFeasibilityRegistry.swift         archived tuple allowlist consumed at runtime
  GitEvidenceXPCClient.swift           NSXPCConnection adapter
  GitEvidencePlatformAdapter.swift     GitEvidenceExecuting conformance

PearcleanerTests/
  GitEvidenceXPCClientTests.swift

script/
  git_evidence_feasibility_run.sh      build signed harness, run matrix, archive logs
  git_evidence_sandbox_checks.sh       post-harness denial assertions
  fixtures/git_evidence/
    minimal-repo/                      golden Git fixtures
    hostile-repo/                      external gitdir, alternates, includes
  fixtures/secret_detector_corpus/     §21.3 positive/negative holdout inputs
```

Modify:

```text
ProjectScannerCore/Privacy/Fingerprint.swift          secret suppression encoder
ProjectScannerCore/Interfaces/ScannerPlatformServices.swift   GitEvidenceExecuting
script/project_scanner_boundary_checks.sh             allow Git adapter seams only
.github/workflows/build.yml                           harness + slice-2 gates
Pearcleaner.xcodeproj/project.pbxproj                 new targets, XPC embed
Pearcleaner/Resources/Pearcleaner.entitlements        XPC service declaration if required
docs/superpowers/evidence/git-feasibility/            archived signed harness output (generated, not hand-edited)
```

No view, navigation, resource copy, helper, Sentinel, FinderOpen, advisory networking, or lockfile parser changes in this slice.

## Execution prerequisite

Start Task 1 from a worktree with slice 1 merged at `HEAD` (`eb5a627` or later on `main`) and no unrelated tracked modifications. Review the slice-1 diff and dependency graph before coding. Preserve untracked `.superpowers/` and brainstorm material.

Resolve packages once before Task 1:

```bash
xcodebuild \
  -resolvePackageDependencies \
  -project Pearcleaner.xcodeproj \
  -scheme "Pearcleaner Debug" \
  -clonedSourcePackagesDirPath .build/SourcePackages
```

Every later local `xcodebuild` uses `-disableAutomaticPackageResolution` and the same cache path.

---

### Task 1: Build the production-signed Git feasibility harness

**Files:**
- Create: `GitFeasibilityHarness/**`, `GitEvidenceShared/GitEvidenceXPCProtocol.swift` (protocol stubs only)
- Create: `GitRunner/**` (minimal stub that logs and exits until Task 4)
- Create: `GitEvidenceService/**` (minimal XPC echo stub until Task 5)
- Create: `script/git_evidence_feasibility_run.sh`
- Create: `docs/superpowers/evidence/git-feasibility/README.md` (evidence layout contract)
- Modify: `Pearcleaner.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: slice-1 `ProjectScannerCore` boundary scripts (must still pass).
- Produces: signed `GitFeasibilityHarness.app` (or equivalent bundle) build scheme; evidence directory schema `docs/superpowers/evidence/git-feasibility/<os-build>-<arch>/manifest.json`.

- [ ] **Step 1: Add Xcode targets and a dedicated scheme**

Create `GitRunner`, `GitEvidenceService` (embedded in harness bundle for now), and `GitFeasibilityHarness` targets with Release signing identities matching Pearcleaner's distribution pipeline. Add scheme `GitFeasibilityHarness Release`.

- [ ] **Step 2: Define the evidence manifest schema**

`manifest.json` records: Pearcleaner/harness version, runner version, Apple Git version (`/usr/bin/git --version`), OS build family, architecture, test timestamp, pass/fail per scenario, paths to sandbox logs and filesystem snapshots.

- [ ] **Step 3: Implement placeholder scenarios that fail until later tasks**

Each scenario writes structured JSON results and a non-zero exit code until implemented: descriptor transfer preservation, sandbox denials (working-tree canary, sibling user data, Pearcleaner private state, metadata write, project executable launch, network), `/usr/bin/git` transition FD preservation, descriptor/`RLIMIT_NOFILE` budget partial behavior, cleanup after success/failure/SIGKILL.

- [ ] **Step 4: Add `script/git_evidence_feasibility_run.sh`**

Build Release-signed harness, run all scenarios on the current machine, copy logs/snapshots into `docs/superpowers/evidence/git-feasibility/`, and fail if signing is ad-hoc or unsigned.

- [ ] **Step 5: Verify harness builds signed locally**

```bash
xcodebuild -quiet \
  -project Pearcleaner.xcodeproj \
  -scheme "GitFeasibilityHarness Release" \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath .build/GitFeasibilityDerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution \
  build
codesign -dv --verbose=4 .build/GitFeasibilityDerivedData/Build/Products/Release/GitFeasibilityHarness.app
```

Expected: valid Developer ID or development team signature; placeholder scenarios fail with explicit "not implemented" markers.

- [ ] **Step 6: Commit**

```bash
git add GitFeasibilityHarness GitRunner GitEvidenceService GitEvidenceShared \
  script/git_evidence_feasibility_run.sh docs/superpowers/evidence/git-feasibility/README.md \
  Pearcleaner.xcodeproj
git commit -m "Add signed Git feasibility harness scaffolding"
```

---

### Task 2: Implement Git feasibility registry and tuple gating

**Files:**
- Create: `Pearcleaner/Logic/ProjectScanner/GitFeasibilityRegistry.swift`
- Create: `ProjectScannerCore/Git/GitFeasibilitySnapshot.swift`
- Create: `PearcleanerTests/GitFeasibilityRegistryTests.swift`
- Modify: `ProjectScannerCore/Interfaces/ScannerPlatformServices.swift`

**Interfaces:**
- Consumes: archived `manifest.json` from Task 1 evidence directory.
- Produces: `GitFeasibilitySnapshot` (enabled/disabled, tuple metadata, Apple Git version); `GitFeasibilityProviding` protocol injected into `ScanCoordinator`.

- [ ] **Step 1: Write failing registry tests**

```swift
func testMissingManifestDisablesGitEvidence() throws
func testMatchingTupleEnablesGitEvidence() throws
func testStaleRunnerVersionDisablesGitEvidence() throws
```

- [ ] **Step 2: Implement manifest loader and strict tuple match**

Compare OS build family, architecture, harness Pearcleaner version, runner version, and Apple Git version exactly. Any mismatch yields `.unavailable(reason: .gitTupleNotAllowlisted)`.

- [ ] **Step 3: Wire protocol into core without XPC imports**

```swift
public protocol GitFeasibilityProviding: Sendable {
    func currentSnapshot() -> GitFeasibilitySnapshot
}
```

- [ ] **Step 4: Run tests and commit**

---

### Task 3: Add Git repository preflight and metadata-only descriptor manifest

**Files:**
- Create: `ProjectScannerCore/Git/GitRepositoryPreflight.swift`
- Create: `ProjectScannerCore/Git/GitMetadataDescriptor.swift`
- Create: `ProjectScannerCore/Git/GitEvidenceModels.swift`
- Create: `ProjectScannerCoreTests/Git/GitRepositoryPreflightTests.swift`
- Create: `script/fixtures/git_evidence/minimal-repo/**`
- Create: `script/fixtures/git_evidence/hostile-repo/**`

**Interfaces:**
- Consumes: `ProjectFileBroker`, `VerifiedRelativePath`, `CoverageReasonCode.gitPreflightRejected`.
- Produces: `GitRepositoryContext` with validated in-root layout; `[GitMetadataDescriptor]` with typed roles (`index`, `sharedIndex`, `looseObject`, `packIndex`, `packData`, etc.), device/inode/size/mtime, hard cap 1,024.

- [ ] **Step 1: Write failing preflight tests**

Cover: normal `.git/` directory; supported `.git` file indirection with in-root gitdir/commondir; reject external gitdir, alternates, replacement refs, partial-clone promisor config, includes/conditional includes, dubious ownership markers, unsupported extensions, oversize config, identity races.

- [ ] **Step 2: Implement bounded config/layout reader**

Parse only as data through `ContentBroker` with limits from spec §10.2. Never invoke Git in the main process.

- [ ] **Step 3: Build descriptor manifest opener**

Open each required metadata file with `O_RDONLY | O_NOFOLLOW | O_CLOEXEC`, verify regular file on selected-root device, record typed role. Reject directory descriptors entirely.

- [ ] **Step 4: Add fixture repos and integration tests through `TemporaryProjectFixture`**

- [ ] **Step 5: Commit**

---

### Task 4: Implement GitRunner with fixed `/usr/bin/git` transition

**Files:**
- Modify: `GitRunner/main.swift`, `GitRunner/GitRunnerProcessProfile.swift`
- Create: `GitRunnerTests/` or harness-embedded tests
- Modify: `GitFeasibilityHarness/Scenarios/GitTransitionScenario.swift`

**Interfaces:**
- Consumes: inherited allowlisted read-only FDs + pipe FDs from supervisor.
- Produces: same-process transition to `/usr/bin/git` only; CLOEXEC hygiene per spec §10.3.

- [ ] **Step 1: Verify Apple signature of `/usr/bin/git` before first transition**

Use Security framework in runner (Security import allowed here, not in core).

- [ ] **Step 2: Implement FD allowlist and `exec`**

Clear `FD_CLOEXEC` only on allowlisted metadata FDs and required pipes immediately before transition. Environment limited to spec §10.3 fixed set.

- [ ] **Step 3: Extend harness scenario to prove FD preservation and denial**

Archive sandbox logs showing metadata read succeeds while direct working-tree read is denied.

- [ ] **Step 4: Commit**

---

### Task 5: Implement GitEvidenceService XPC target, entitlements, and protocol

**Files:**
- Modify: `GitEvidenceService/**`, `GitEvidenceShared/GitEvidenceXPCProtocol.swift`
- Create: `GitEvidenceService/GitEvidenceService.entitlements`
- Create: `Pearcleaner/Logic/ProjectScanner/GitEvidenceXPCClient.swift`
- Modify: `Pearcleaner.xcodeproj/project.pbxproj`, entitlements/plist embed

**Interfaces:**
- Consumes: batched `[GitMetadataDescriptorTransfer]` + `GitEvidenceOperation` enum.
- Produces: `GitEvidenceOperationResult` with bounded stdout/stderr metadata and anonymous pipe endpoint for blob bytes (not XPC-carried).

```swift
@objc protocol GitEvidenceXPCProtocol {
    func perform(
        _ request: GitEvidenceXPCRequest,
        reply: @escaping (GitEvidenceXPCReply?, NSError?) -> Void
    )
}
```

- [ ] **Step 1: Define closed request/reply types in `GitEvidenceShared`**

Codable/XPC-safe metadata only; never embed file paths or project roots.

- [ ] **Step 2: Add restrictive sandbox entitlements**

No network, no user-selected files, no app groups, no inherited FDA.

- [ ] **Step 3: Implement client adapter in app target with NSXPCConnection**

Validate service bundle ID and signature before first use.

- [ ] **Step 4: Harness scenario: batched FD transfer preserves `O_RDONLY` and identity**

- [ ] **Step 5: Commit**

---

### Task 6: Build synthetic administrative view and operation supervisor

**Files:**
- Create: `GitEvidenceService/GitSyntheticAdminView.swift`
- Create: `GitEvidenceService/GitOperationSupervisor.swift`
- Create: `GitEvidenceService/GitOutputParser.swift`
- Modify: harness scenarios for ls-files, ls-tree, cat-file batch

**Interfaces:**
- Consumes: validated descriptors + resolved current `HEAD` OID from request.
- Produces: parsed path lists and bounded blob stream endpoints.

- [ ] **Step 1: Write failing parser tests for NUL-framed records**

Reject empty/`.`/`..` components, out-of-order cat-file responses, malformed OIDs.

- [ ] **Step 2: Implement synthetic view using `/dev/fd/<file-fd>` links only**

No directory FD traversal; no `info/alternates`; destroy view after each operation.

- [ ] **Step 3: Implement supervisor with 30s timeout, 32 MiB output cap, process-group kill**

Drain stdout/stderr concurrently; escalate to `SIGKILL` after 500 ms.

- [ ] **Step 4: Implement three allowlisted operations with fixed Git prelude/flags from spec §10.3–10.4**

- [ ] **Step 5: Run harness scenarios and archive evidence**

- [ ] **Step 6: Commit**

---

### Task 7: Add GitIgnoreClassifier and GitEvidenceProvider with post-operation revalidation

**Files:**
- Create: `ProjectScannerCore/Git/GitIgnoreClassifier.swift`
- Create: `ProjectScannerCore/Git/GitEvidenceProvider.swift`
- Create: `ProjectScannerCoreTests/Git/GitIgnoreClassifierGoldenTests.swift`
- Create: `ProjectScannerCoreTests/Git/GitEvidenceProviderTests.swift`
- Create: `Pearcleaner/Logic/ProjectScanner/GitEvidencePlatformAdapter.swift`

**Interfaces:**
- Consumes: `GitFeasibilityProviding`, `GitEvidenceExecuting`, `ProjectFileBroker`, `CoverageLedger`.
- Produces: `GitPathFacts` (tracked/untracked/staged/ignored/currentHead/index views) feeding correlator; coverage updates with `git_*` reason codes.

- [ ] **Step 1: Implement native ignore classifier with golden fixtures against system Git for supported grammar**

Limits: 1 MiB per ignore file, 16 MiB total, 250,000 patterns.

- [ ] **Step 2: Implement provider orchestration**

Preflight → descriptor manifest → serialize operations per repository → invoke executor → reopen and compare manifest → discard output on identity drift.

- [ ] **Step 3: Stream index/`HEAD` blobs through `ContentBroker` to secret detector path (stub hook until Task 9)**

- [ ] **Step 4: Add tests for partial/unavailable at descriptor budget and timeout**

- [ ] **Step 5: Commit**

---

### Task 8: Implement versioned secret rule pack and streaming SecretDetector

**Files:**
- Create: `ProjectScannerCore/Detectors/SecretRulePack.swift`
- Create: `ProjectScannerCore/Detectors/SecretDetector.swift`
- Create: `ProjectScannerCore/Detectors/SecretMatchIdentity.swift`
- Create: `ProjectScannerCoreTests/Detectors/SecretRulePackTests.swift`
- Create: `script/fixtures/secret_detector_corpus/**`

**Interfaces:**
- Consumes: `ContentLease`, `PrivacyRedactor`, `CoverageLedger`, `SessionStore`.
- Produces: `SecretMatch` with rule ID/version, confidence, in-memory identity, masked evidence via redactor.

- [ ] **Step 1: Define rule schema**

Each rule: ID, version, structural validator, max match length, confidence class. Initial pack covers high-confidence provider-prefix rules from spec §11.1 (e.g., AWS, GitHub PAT, Slack, Stripe-style patterns) — exact list locked by corpus fixtures.

- [ ] **Step 2: Write failing corpus tests per §21.3**

At least 200 supported positive canaries and 1,000 negatives on holdout paths; entropy-only inputs must produce zero findings.

- [ ] **Step 3: Implement streaming scanner with 64 KiB chunk overlap for boundary matches**

Respect 5 MiB default secret file limit; record `ordinaryFileTooLarge` explicitly.

- [ ] **Step 4: Integrate with `CoverageLedger` secret detector transaction**

- [ ] **Step 5: Commit**

---

### Task 9: Add secret correlation, fingerprint encoding, and privacy gates

**Files:**
- Create: `ProjectScannerCore/Detectors/SecretMatchCorrelator.swift`
- Modify: `ProjectScannerCore/Privacy/Fingerprint.swift`
- Create: `ProjectScannerCoreTests/Detectors/SecretMatchCorrelatorTests.swift`
- Create: `ProjectScannerCoreTests/Privacy/SecretFingerprintTests.swift`

**Interfaces:**
- Consumes: `SecretMatchIdentity`, `GitPathFacts`, `ProjectKeyMaterial`.
- Produces: `SessionFinding` headers with `SourceView` per match; `SuppressionFingerprint` via new typed encoder domain.

- [ ] **Step 1: Add secret-specific fingerprint encoder in `Fingerprint.swift`**

Domain-separated fields: project UUID, finding kind, rule ID/version, relative path identity, exact match identity — never store raw bytes.

- [ ] **Step 2: Implement correlator comparing working tree, index, and current `HEAD` identities**

- [ ] **Step 3: Extend privacy canary tests for secret paths through SessionStore and diagnostics adapter**

- [ ] **Step 4: Commit**

---

### Task 10: Implement minimal ScanCoordinator (headless pipeline)

**Files:**
- Create: `ProjectScannerCore/Orchestration/ScanCoordinator.swift`
- Create: `ProjectScannerCoreTests/Orchestration/ScanCoordinatorIntegrationTests.swift`
- Modify: `ProjectScannerCore/Interfaces/ScannerPlatformServices.swift`

**Interfaces:**
- Consumes: `RootCapability`, `GitFeasibilityProviding`, `GitEvidenceExecuting`, platform services from slice 1.
- Produces: terminal `ScanCoverageSnapshot`, session findings in `SessionStore`, optional persistence via existing `ProjectStateStore` when keyed state allows.

- [ ] **Step 1: Write failing integration test on `minimal-repo` fixture**

Expect secret findings in working tree; when feasibility manifest present and Git enabled, expect index/`HEAD` correlation facts.

- [ ] **Step 2: Implement coordinator pipeline stages from spec §9 steps 1–9 (no UI, no advisory/lifecycle/lockfile detectors)**

Stages: authorize → enumerate → prioritize → read → secret detect → Git evidence (if enabled) → correlate → finalize coverage.

- [ ] **Step 3: Enforce budgets, cancellation (<500 ms), and single active scan**

- [ ] **Step 4: Verify partial Git never replaces last complete summary**

- [ ] **Step 5: Commit**

---

### Task 11: Complete signed feasibility matrix and enable tuple registry

**Files:**
- Modify: all `GitFeasibilityHarness/Scenarios/**`
- Modify: `script/git_evidence_feasibility_run.sh`, `script/git_evidence_sandbox_checks.sh`
- Modify: `Pearcleaner/Logic/ProjectScanner/GitFeasibilityRegistry.swift`
- Create: `docs/superpowers/evidence/git-feasibility/<tuple>/manifest.json` (generated on CI/dev machine)

**Interfaces:**
- Consumes: Tasks 4–6 complete service/runner.
- Produces: archived passing evidence for at least arm64 and x86_64 on the current OS build family used for release.

- [ ] **Step 1: Run full harness matrix locally on both architectures (or CI matrix)**

Document Apple Git version and codesign identities in manifest.

- [ ] **Step 2: Add `script/git_evidence_sandbox_checks.sh` assertions**

Parse sandbox denial logs for required denials; fail on any working-tree read success or network allowance.

- [ ] **Step 3: Point registry at checked-in manifests; disable Git where manifest absent**

- [ ] **Step 4: Commit evidence + scripts (manifests only, no secrets)**

---

### Task 12: Add slice-2 verification gates and boundary enforcement

**Files:**
- Modify: `script/project_scanner_boundary_checks.sh`
- Modify: `.github/workflows/build.yml`
- Create: `script/test_git_evidence_boundaries.sh`
- Modify: `script/security_regression_checks.sh`

- [ ] **Step 1: Extend boundary checks**

- `ProjectScannerCore` still must not import `NSXPCConnection`, `Process`, or `URLSession`.
- Allow `GitEvidenceExecuting` only in `Pearcleaner/Logic/ProjectScanner/**`.
- Reject any `SuppressionIdentityInput`-style generic encoder additions.

- [ ] **Step 2: Add CI jobs**

```yaml
      - name: Test ProjectScannerCore slice-2
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

      - name: Run Git feasibility harness (signed)
        run: ./script/git_evidence_feasibility_run.sh

      - name: Verify Git evidence sandbox checks
        run: ./script/git_evidence_sandbox_checks.sh

      - name: Verify secret detector corpus gates
        run: ./script/test_secret_detector_corpus.sh
```

- [ ] **Step 3: Run full local verification matrix**

```bash
xcodebuild -quiet -project Pearcleaner.xcodeproj -scheme ProjectScannerCore \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/ProjectScannerCoreDerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO test

./script/git_evidence_feasibility_run.sh
./script/git_evidence_sandbox_checks.sh
./script/project_scanner_boundary_checks.sh .build/ProjectScannerCoreDerivedData/Build/Products/Debug
./script/security_regression_checks.sh

xcodebuild -quiet -project Pearcleaner.xcodeproj -scheme "Pearcleaner Release" \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath .build/Slice2ReleaseArmDerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=NO ARCHS=arm64 build

xcodebuild -quiet -project Pearcleaner.xcodeproj -scheme "Pearcleaner Release" \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath .build/Slice2ReleaseIntelDerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=NO ARCHS=x86_64 build
```

Expected: all tests pass; secret corpus meets §21.3 thresholds; feasibility evidence archived; both Release architectures build with embedded XPC service; no UI files changed.

- [ ] **Step 4: Inspect diff scope**

```bash
git diff --name-status HEAD~12
```

Expected: only slice-2 files; no views, advisory code, lockfile parsers, or navigation.

- [ ] **Step 5: Commit**

```bash
git commit -m "Add slice-2 Git evidence and secret detector verification gates"
```

---

## Slice completion contract

Slice 2 is complete only when all twelve task commits are present and the Task 12 verification matrix passes, including:

1. **Signed feasibility evidence** archived for every enabled OS/arch tuple.
2. **Sandbox denials** observed for working-tree reads, external user data, Pearcleaner private state, metadata writes, project executable launch, and network access.
3. **Secret detector quality gates** from spec §21.3 met on the holdout corpus.
4. **Headless ScanCoordinator** can scan a fixture repo for secrets and attach Git exposure facts when the tuple is allowlisted; Git remains unavailable elsewhere.
5. **No product UI** and no weakening of slice-1 invariants.

Begin the separately reviewed slice-3 plan (advisory updater, OSV index, Node lockfile parsers) only after reviewing the actual slice-2 diff, signed harness evidence, sandbox logs, and dependency graph.

## Deferred to later slices (explicit)

| Capability | Slice |
| --- | --- |
| OSV advisory updater and SQLite index | 3 |
| npm/pnpm/Yarn lockfile parsers and advisory matching | 3 |
| Lifecycle manifest inspection | 4 |
| Manual scan UI, progress, cancellation UX, FSEvents opt-in, accessibility | 5 |
| Frozen quality corpus, performance baselines, final release integration | 6 |
| Product naming, Project Workspace navigation, rebrand | Separate approval |
