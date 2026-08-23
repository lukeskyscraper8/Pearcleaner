# Developer Exposure Inspector: Scanner Boundary Design

**Date:** 2026-08-23
**Status:** Scanner design approved; Git sandbox amendment requires spec review; implementation is not approved
**Scope:** The first security-scanning workstream inside Pearcleaner
**Working label:** “Developer Exposure Inspector” identifies this document; it is not approved product or UI naming

## 1. Decision

Pearcleaner will gain an in-process, native Swift scanner that inspects a user-selected development-project root for three classes of developer exposure:

1. likely secrets in bounded text content;
2. known vulnerable or malicious npm packages represented by supported Node lockfiles; and
3. risky lifecycle-script declarations in first-party and installed package manifests.

The scanner will also collect narrowly defined Git evidence so it can distinguish a match found only in the working tree from the same match present in the index or current `HEAD` snapshot. The scanner remains in the main process, but untrusted Git formats are handled through one narrowly scoped, independently sandboxed XPC service and one minimal signed runner. They receive only pinned read-only file descriptors for validated in-root Git metadata files, never a project path, directory capability, bookmark, or project-source handle, and do not inherit Pearcleaner's unrestricted filesystem access.

The feature is an inspector, not an autonomous remediator. It explains findings and can generate safely quoted commands for the user to copy. It never executes remediation, edits the selected project, installs packages, invokes package managers, follows repository instructions, or calls Pearcleaner's privileged helper.

This is the scanner-boundary design only. Product naming, application-wide navigation, the broader rebrand, licensing, pricing, Git-history scanning, and additional package ecosystems remain separate decisions.

## 2. Outcome

The useful outcome is a result a developer can interpret without being misled:

- which detectors completed;
- exactly what each detector did and did not inspect;
- what evidence supports each finding;
- whether matching secret material also appears in the Git index or current `HEAD` snapshot;
- whether advisory data is present and fresh enough to use; and
- whether the overall run is complete, partial, cancelled, failed, or unavailable.

The scanner must say **“no findings in scanned coverage”**, never “safe”, “clean”, or an equivalent whole-project guarantee.

There is no opaque composite risk score. Findings, confidence, severity, Git state, advisory provenance, cache freshness, and coverage remain separate dimensions.

## 3. Goals

- Treat every selected repository and installed dependency as potentially hostile input.
- Keep all project analysis local. Project paths, package names, versions, source content, and matches are not sent to a service.
- Include hidden, ignored, untracked, staged, and tracked files when they are inside the selected root and within budget.
- Support npm, pnpm, Yarn Classic, and Yarn Berry lockfiles at explicitly recognized format revisions.
- Inspect installed dependencies without evaluating package source or lifecycle code.
- Make incomplete coverage visible at detector and whole-run level.
- Persist only enough state to identify a selected project, show the last complete summary, show the last attempt state, and apply exact local suppressions.
- Keep raw secret material out of presentation, persistence, logs, diagnostics, remediation commands, and crash context.
- Bound CPU, memory, disk, archive, output, and wall-clock consumption.
- Preserve all existing Pearcleaner behavior and security boundaries.

## 4. Non-goals

Version one will not:

- execute project code, shell commands, package managers, Git hooks, clean/smudge filters, text conversion, build tools, interpreters, or lifecycle scripts;
- inspect prior commits, reflogs, remotes, hosting providers, pull requests, or determine whether content was ever pushed or made public;
- claim that a tracked, staged, or committed secret is compromised;
- mutate repository files, Git metadata, ignore files, lockfiles, manifests, extended attributes, or package-manager state;
- quarantine, delete, rotate, revoke, upgrade, install, or uninstall anything;
- reveal, copy, persist, or transmit a detected secret;
- validate secrets against provider APIs;
- use standalone entropy as a finding;
- support Bun, Deno, Python, Ruby, Go, Rust, Java, PHP, or other dependency ecosystems;
- parse Yarn Plug'n'Play executable state such as `.pnp.cjs`;
- follow a symlink, Finder alias, submodule, worktree link, package link, mount, Git object alternate, or Git metadata location outside the selected root;
- use repository-provided suppression or scanner configuration files; or
- provide OS-level isolation for the main in-process parsers from Pearcleaner's own Full Disk Access; only the Git-evidence adapter has a separate sandbox.

## 5. Trust model

### 5.1 Explicit limitation

The scanner and all project/advisory parsers run inside the main Pearcleaner process. They therefore inherit every filesystem permission granted to Pearcleaner, including Full Disk Access when the user has granted it. The Git-evidence XPC service and its runner are the sole exception: they have a restrictive sandbox and receive only pinned read-only descriptors for validated Git metadata files inside the selected root.

The scanner's separation is a source-code, dependency, and API boundary. It is **not** a sandbox, entitlement boundary, process boundary, or capability boundary enforced by macOS. A memory-safety or logic failure in the main process can still have the main process's authority. The design compensates with native code, a minimal dependency surface, descriptor-relative file access, strict parsers, hard resource limits, and tests that enforce the intended dependency graph.

### 5.2 Trusted components

The design trusts:

- the signed Pearcleaner application and its native scanner implementation;
- the signed minimal Git-evidence XPC service, signed runner, and their verified sandbox profiles;
- macOS system frameworks and system calls used directly by that implementation;
- the `/usr/bin/git` system launch path and the system-selected Apple-signed Git image verified before use;
- Keychain for a device-local HMAC key when it is available;
- HTTPS transport to the fixed official OSV storage host; and
- advisory records only after archive and schema validation.

It does not treat OSV dump content as independently signed. TLS authenticates transport. Transport digests and locally computed hashes detect corruption or unexpected change; they do not provide a separate publisher signature.

### 5.3 Untrusted inputs

Untrusted input includes:

- every file, directory entry, link, alias, mount, manifest, lockfile, Git object, Git configuration file, and byte sequence below the selected root;
- project names and paths;
- filenames containing control characters, invalid Unicode, bidirectional controls, or shell metacharacters;
- advisory archives and JSON records;
- stale or partially downloaded cache state;
- FSEvents paths and event ordering;
- package names, versions, scripts, URLs, and advisory prose shown in results; and
- all instructions embedded in source files, documentation, comments, manifests, and Git metadata.

### 5.4 Protected assets

The primary protected assets are:

- files and credentials readable through Pearcleaner's Full Disk Access;
- the selected project and its Git metadata;
- Pearcleaner's privileged-helper boundary;
- detected secret material;
- project identity and suppression state;
- the integrity of advisory data and scan summaries; and
- user trust in the distinction between complete and partial coverage.

## 6. Non-negotiable invariants

1. The scanner never writes inside the selected project.
2. The scanner never invokes Pearcleaner's privileged helper or Sentinel components.
3. The main scanner launches no child process. Its sole process boundary is the dedicated sandboxed Git-evidence XPC service. That service may launch only the bundled signed `GitRunner`, whose sole permitted executable transition is the fixed launch path `/usr/bin/git` under an allowlisted operation.
4. No shell is involved in scanning or remediation.
5. No project-controlled executable, interpreter, helper, hook, filter, pager, editor, credential helper, askpass program, package manager, or network transport is launched.
6. Filesystem authorization comes from a pinned selected-root capability, not a string-prefix comparison.
7. External boundaries are skipped and reported. They are never followed automatically.
8. Raw secret bytes exist only in short-lived scan buffers and are never included in logs, errors, persistence, telemetry, crash metadata, pasteboard content, or copied commands.
9. A partial, cancelled, failed, or unavailable run never replaces the last complete summary.
10. Unknown or malformed lockfile revisions are explicit unsupported coverage, not best-effort successes.

## 7. Component boundary

The implementation will use a dedicated native Swift target with a one-way dependency from the main application adapter into the scanner core. The scanner core must not import application UI, privileged-helper clients, Sentinel clients, Sparkle, package-manager libraries, shell wrappers, or third-party parsers.

Permitted foundations are Swift, Foundation, CryptoKit, Compression, SQLite3, FSEvents, and Darwin/POSIX filesystem and process APIs. Adding another scanner dependency requires its own security review and design amendment.

Conceptual components are:

- **ScanCoordinator:** owns one scan session, cancellation, worker scheduling, detector lifecycle, and terminal state.
- **RootCapability:** holds the selected root descriptor and immutable identity used for containment checks.
- **FileBroker:** is the only scanner-core API that enumerates or opens project content.
- **ContentBroker:** performs bounded, chunked reads and shares immutable buffers between detectors.
- **GitIgnoreClassifier:** natively applies bounded in-root `.gitignore` and `.git/info/exclude` data to verified paths; it never uses global excludes.
- **GitEvidenceProvider:** opens validated Git metadata files read-only through the FileBroker and transfers their descriptors, typed roles, expected identities, and an operation enum to the Git-evidence XPC service.
- **GitEvidenceService:** is a separately signed, independently sandboxed supervisor with no broad user-file, Full Disk Access, app-group, or network entitlement. It validates Git metadata, builds a synthetic administrative view, supervises one runner, and revalidates the source metadata.
- **GitRunner:** is a minimal signed inherited-sandbox helper. It receives only allowlisted inherited read-only descriptors, applies the fixed process profile, and transitions only to `/usr/bin/git`.
- **SecretDetector:** finds supported structured credentials and returns masked evidence plus in-memory match identities.
- **NodeLockfileDetector:** parses recognized lockfile revisions into exact registry-backed npm coordinates and dependency relationships.
- **LifecycleDetector:** reads only selected fields from recognized `package.json` manifests.
- **AdvisoryStore:** atomically updates and queries the validated public advisory index.
- **CoverageLedger:** records planned, completed, skipped, unsupported, and failed work for every detector.
- **SessionStore:** holds detailed findings, paths, package identities, already-masked evidence, and non-reversible identities only in memory. It never receives raw matches, raw snippets, decoded source buffers, or redaction inputs.
- **ProjectStateStore:** persists the minimal summary and exact keyed suppressions in the main app's private Application Support container.
- **PresentationAdapter:** routes every source-derived display field through one centralized secret redactor, then creates UI models and fixed copy-only remediation templates.

The scanner target exposes typed operations. It does not accept arbitrary commands, executables, environment variables, glob programs, parser plugins, callbacks sourced from the repository, or write-capable file handles.

## 8. Selected-root containment

### 8.1 Root acquisition

The user chooses one directory using a system open panel. The selected root itself must open as a directory without following a symbolic link or Finder alias; otherwise the user must select the resolved directory explicitly. The app records a descriptor plus its device and inode identity. Enumeration and file access remain relative to that descriptor.

A security-scoped bookmark may be retained for later user-authorized scans. On reuse, the bookmark is resolved, the root is reopened, and identity and containment state are established afresh. A moved root with the same filesystem identity can continue; a replacement identity requires explicit reauthorization. A bookmark or cached path never authorizes a scan by itself.

### 8.2 Descriptor-relative traversal

The FileBroker walks directory descriptors and opens children relative to their verified parent. It does not authorize access through `hasPrefix`, textual canonicalization, a previously observed absolute path, or an FSEvents path.

For each directory entry it:

1. reads metadata without following the entry;
2. classifies regular file, directory, symbolic link, or unsupported special type;
3. opens the child with no-follow semantics;
4. compares the opened identity with the inspected identity;
5. rejects device changes, mount crossings, special files, sockets, FIFOs, and identity races;
6. rechecks file identity and size after reading; and
7. records changed-during-read input as skipped rather than trusting unstable evidence.

Absolute symbolic links are always external. Relative symbolic links are resolved component by component from the containing directory, with a maximum of 16 link hops. `..` is allowed only while the logical component stack remains at or below the selected root. Every resolved component is reopened with no-follow and identity checks. A relative link that cannot be proved to terminate inside the pinned root is skipped as an external boundary.

Finder aliases are ordinary files for scanning purposes and are never resolved. Hard-linked regular files are authorized by the directory entry inside the selected root and are read as files; their existence elsewhere does not expand traversal. A device change is an external mount and is skipped even when mounted beneath the root.

Relative display paths are derived from the verified traversal stack. Invalid Unicode and control characters are escaped for presentation. Paths do not become shell tokens automatically.

### 8.3 Nested repositories and package links

Nested repositories are not an exception to containment. Each path is associated with its nearest validated in-root repository for Git evidence. A `.git` file or directory that resolves outside the selected root, an external common directory, an object alternate, a submodule worktree outside the root, or an external package link is skipped and reported.

The scanner never expands the authorized root to make Git, a submodule, a worktree, or a package-manager layout work. The user must separately select any external tree they want inspected.

## 9. Scan pipeline

Each scan uses an immutable session identifier unrelated to the project identity.

1. **Authorize:** resolve and pin the selected root; initialize budgets and cancellation.
2. **Snapshot advisory state:** select one previously activated advisory database generation and record its age and provenance for the entire session.
3. **Enumerate:** traverse the selected root natively, classifying entries before reading content.
4. **Prioritize:** schedule top-level source, first-party manifests, and lockfiles before installed-dependency manifests and other `node_modules` content.
5. **Read:** obtain bounded immutable buffers through the ContentBroker. Parser-specific passes reuse a buffer where possible.
6. **Detect:** run secret, lockfile, advisory, and lifecycle detectors independently while updating per-detector coverage transactions.
7. **Collect Git evidence:** for each validated in-root repository, pass only pinned read-only descriptors for the exact Git metadata files required by an allowlisted operation to the sandboxed Git-evidence service, collect path/index/current-`HEAD` facts without working-tree filters, and stream admitted index/`HEAD` blob views through the same bounded secret-detector path.
8. **Correlate:** compare in-memory secret match identities across working tree, index, and current `HEAD` views.
9. **Finalize coverage:** close every detector transaction as complete, partial, cancelled, failed, or unavailable with machine-readable reasons.
10. **Present:** render findings and coverage together, with no raw secret material.
11. **Persist minimally:** only a complete overall run can replace `lastCompleteSummary`; every terminal run may update a sanitized `lastAttempt` record.

Advisory-cache updating is a separate task. A project scan performs no network requests and never uses project contents to construct an update request.

### 9.1 Text classification

Hidden status, filename extension, Git status, and ignore status do not decide whether a regular file is inspectable text. The ContentBroker accepts strict UTF-8 with an optional BOM and UTF-16 little- or big-endian only with the corresponding BOM. Invalid encoding, an embedded NUL inconsistent with valid UTF-16, or an unsupported encoding is reported as binary/unsupported text coverage.

Text decoding and secret matching are streaming and preserve enough bounded overlap to detect a supported token across chunk boundaries. A file above the configured secret-detector limit, 5 MiB by default, is skipped in full by that detector; it is not silently sampled. A separately recognized lockfile or manifest may still be admitted to its own parser under that parser's larger or smaller limit.

## 10. Git evidence boundary

### 10.1 Meaning of Git evidence

Git state is a set of facts, not a severity shortcut:

- **working tree:** the inspected bytes came from the selected filesystem entry;
- **index:** matching bytes are present in the repository's current index blob;
- **current HEAD:** matching bytes are present in the currently resolved `HEAD` tree snapshot;
- **tracked:** the path has an entry in the current index;
- **staged change:** the path or index object differs from the same path in current `HEAD`;
- **untracked:** the path is absent from the index;
- **ignored:** the path matches the explicitly bounded repository ignore inputs used by the scanner; and
- **Git unavailable:** evidence could not be collected safely or within budget.

“Tracked” does not mean committed. “Staged” does not mean committed. “Current HEAD” does not mean pushed, public, reachable from a remote, or exposed to another person. Version one does not inspect history.

Index stages 1 through 3 are scanned as separate in-memory views during a merge conflict and reported as ambiguous index state. They are never collapsed into a normal stage-0 claim.

### 10.2 Repository preflight

The FileBroker validates the in-root `.git` layout and reads bounded configuration as data. A normal in-root `.git` directory is supported. A `.git` indirection is supported only when its resolved gitdir and optional common directory both remain inside the pinned selected root and every required metadata file can be separately validated and opened read-only. Git evidence is unavailable when preflight finds:

- external `gitdir` or `commondir` resolution;
- object alternates, replacement references, or external object directories;
- partial-clone or promisor configuration that could trigger lazy object fetching;
- configuration includes or conditional includes;
- unsafe ownership rejected by system Git;
- unsupported repository format extensions;
- malformed or oversized configuration; or
- a path or identity that changed during preflight.

The scanner does not bypass Git's dubious-ownership protection with `safe.directory=*` or an equivalent override.

System Git does not classify working-tree membership or ignored paths. The main process derives tracked/untracked membership by comparing FileBroker paths with validated index output. `GitIgnoreClassifier` reads only bounded in-root `.gitignore` files and the validated in-root `.git/info/exclude`, applies a versioned Git-compatible pattern grammar, and never excludes a file from scanning. It accepts at most 1 MiB per ignore file, 16 MiB total ignore data, and 250,000 patterns. Unsupported grammar or a limit makes only ignored-status coverage unavailable. Golden fixtures compare the native classifier with the supported system Git behavior.

The main process resolves `HEAD`, its bounded ref chain, the repository/object format, and the exact index/object-store file manifest through the FileBroker. It opens every file supplied to Git with `O_RDONLY | O_NOFOLLOW | O_CLOEXEC`, verifies that it is a regular file on the selected-root device, and records its typed role, device, inode, size, and modification metadata. It passes no directory descriptor.

The index-membership operation needs only the index and, when declared by a supported index extension, its exact shared-index file. Object operations receive validated pack, index, reverse-index, and loose-object files. Only names matching the repository hash grammar and fixed pack-file grammar are eligible. Configuration, hooks, attributes, excludes, refs, alternates, replacement refs, commit graphs, credentials, remotes, and arbitrary administrative files are never passed to Git.

Project metadata descriptors have a hard cap of 1,024 per operation. The service preserves a reserve of 128 descriptors below its current soft `RLIMIT_NOFILE`; it may raise its own soft limit only up to the lower of its existing hard limit and 1,152. Transfers are acknowledged in batches of at most 32. Operations are serialized per repository, and every project descriptor is closed before the next operation begins. If all required object files do not fit, index membership may still complete with its smaller descriptor set, while index/`HEAD` blob inspection is unavailable with `git_descriptor_budget`. The scanner never copies object bytes or asks the repository to repack.

On receipt, the service verifies every descriptor is still read-only and matches its declared regular-file identity. It creates an empty synthetic administrative view in its private temporary container containing:

- a service-authored minimal configuration with only the validated repository version and object format;
- an empty private worktree;
- an `index` link to the exact inherited index file descriptor plus an allowlisted shared-index link when required;
- the already resolved full current-`HEAD` object ID; and
- an object directory whose validated loose-object and pack/index names link one-to-one to individual inherited file descriptors through `/dev/fd/<file-fd>`.

Darwin `/dev/fd/<directory-fd>` traversal is not used. Every synthetic link names one inherited regular-file descriptor, so Git cannot enumerate or open a project path. The view contains no `info/alternates`, replacement refs, commit graphs, hooks, user configuration, source bytes, bookmark, or absolute project path. Its names are generated from fixed grammars, and it is destroyed after the operation.

After an operation, the main FileBroker reopens the source entries and compares the recorded manifest. A changed identity, size, modification state, ref, index, or object-store directory generation discards all output and marks the relevant Git evidence partial or unavailable.

### 10.3 Sandboxed Git-evidence service

The main process sends bounded batches of read-only regular-file descriptors, typed descriptor roles, expected identities, and one operation enum to a separately signed XPC service. The service has its own App Sandbox with no user-selected-file, bookmark, user-selected-executable, Full Disk Access, network, automation, app-group, or privileged-helper entitlement. It exposes no arbitrary path, directory descriptor, command, argument, environment, URL, or write API.

The service may spawn only the bundled signed `GitRunner`. The runner is signed with the App Sandbox and sandbox-inheritance entitlements required by Apple and no additional capability entitlement. The supervisor explicitly duplicates only the allowlisted read-only metadata descriptors and output/error pipes into the runner, then the runner replaces its own process image with the fixed launch path `/usr/bin/git`. This same-process transition is the only permitted path from runner to Git.

The sandbox allowlist is described honestly. Git can read Apple-signed loader/framework/runtime files, the verified system developer-tool image, `/dev/null` and inherited pipes/descriptors, the otherwise empty private service/runner container and temporary directory, the service-authored administrative view, and the exact regular files represented by inherited read-only descriptors. It has no project path, directory capability, bookmark, project-source handle, or access to other user-document locations. A repository value cannot select a system, container, or temporary file because all Git administrative paths and object-view entries are service-authored from fixed grammars.

The implementation must prove for each enabled OS/architecture tuple that the transitioned Git image can read the inherited metadata files but cannot directly read an untracked canary working-tree file, a sibling user-data canary, or Pearcleaner's private state; cannot write through the source descriptors; cannot execute a project-controlled file; and has no network access even when the main app has Full Disk Access. Current index and `HEAD` blob bytes reached through those validated Git files remain intentional input. If this confinement cannot be verified, Git evidence remains unavailable. There is no direct-from-main, unsandboxed, live-config, bookmark, or weaker fallback.

The inherited environment is discarded. The complete child environment is limited to service-owned `HOME` and `TMPDIR` paths plus `PATH=/usr/bin:/bin`, `LANG=C`, `LC_ALL=C`; service-authored `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE`, and `GIT_OBJECT_DIRECTORY` values that point only to the empty worktree, synthetic administrative view, or inherited metadata descriptors; and `GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_SYSTEM=/dev/null`, `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_OPTIONAL_LOCKS=0`, `GIT_NO_LAZY_FETCH=1`, `GIT_NO_REPLACE_OBJECTS=1`, `GIT_LITERAL_PATHSPECS=1`, and `GIT_TERMINAL_PROMPT=0`. No other `GIT_*`, `DYLD_*`, tracing, pager, editor, askpass, credential, `DEVELOPER_DIR`, `TOOLCHAINS`, SSH, proxy, or locale variable is present.

Every invocation uses the complete fixed prelude `--no-pager`, `--no-optional-locks`, and `--no-replace-objects`, plus fixed configuration overrides for `core.fsmonitor=false`, `core.untrackedCache=false`, `core.hooksPath=/dev/null`, `submodule.recurse=false`, `maintenance.auto=false`, `core.attributesFile=/dev/null`, `core.excludesFile=/dev/null`, `color.ui=false`, an empty `credential.helper`, `protocol.allow=never`, and an empty `diff.external`. The feature probe must prove every relied-on flag, environment control, and override. An unsupported required control makes Git evidence unavailable rather than removing that control.

The supervisor uses `POSIX_SPAWN_CLOEXEC_DEFAULT` or an observed equivalent, explicitly closes every unintended descriptor, and starts a new process group. Runner stdin is `/dev/null` except for the `cat-file` batch operation, where it is a bounded service-authored pipe containing only full object IDs already validated for that operation; the write end closes after the fixed request count. Immediately before the same-process Git transition, the runner clears `FD_CLOEXEC` only on the allowlisted metadata descriptors and required pipes; every other descriptor remains closed-on-exec or closed. The supervisor concurrently drains stdout and stderr into bounded buffers. Raw blob output crosses to the main ContentBroker only through a bounded anonymous pipe; it is never encoded into an XPC object, temporary file, log, or error. Each operation has a 30-second timeout and a 32 MiB combined-output cap. Cancellation, timeout, or overflow terminates the process group and escalates to group-wide `SIGKILL` after 500 ms. No output from a truncated, timed-out, signalled, unexpectedly exited, or malformed invocation is accepted.

The scanner does not invoke a developer-tools installation prompt. Before the first launch, the service reads the OS developer-directory selection without executing a probe, resolves the developer-tool image used by `/usr/bin/git`, and verifies both the system launch path and resolved image with Security-framework code-signing APIs. The only permitted Git transition is `/usr/bin/git` to that verified Apple-signed system-selected image. A missing selection, failed Apple signature, unexpected executable transition, or incompatible Git makes evidence unavailable.

### 10.4 Allowed operations

Allowed operations are limited to fixed equivalents of:

- `git ls-files` for NUL-delimited cached/stage entries;
- `git ls-tree -r -z` for the validated current `HEAD` object ID; and
- `git cat-file` batch input using full validated object IDs and NUL-safe output framing.

Every command uses only the synthetic administrative view, descriptor-relative Git metadata, and a full object ID already validated by the service. No command receives the selected worktree path. The implementation must use only options supported by its feature probe. It never uses `--filters`, `--textconv`, `--follow-symlinks`, an arbitrary revision expression, an arbitrary pathspec, a repository-provided command, or a URL. Git reads raw repository blobs only; it never materializes LFS, filter, or text-converted content.

All output is attacker-controlled. Path records must be NUL-framed, relative, free of empty/`.`/`..` components, and correlated only with the FileBroker's verified path set. Object IDs must match the repository's validated hash grammar and an object requested by the fixed operation. An extra, missing, duplicate-conflicting, or out-of-order record rejects the operation rather than being ignored.

Index and current-`HEAD` blobs count toward the same global scan budgets as working-tree content. They pass through the same detector and masking pipeline. Only the current index and current `HEAD` snapshot are in scope; parent commits and history traversal are not.

### 10.5 Signed feasibility gate

The Git slice cannot begin with production code. Its first deliverable is a disposable, production-signed feasibility harness. Git evidence is enabled only for an exact OS-version/architecture tuple that the archived signed harness has passed; every untested, expired, or failed tuple defaults to Git unavailable even when the rest of Pearcleaner supports that tuple. It must demonstrate:

- batched main-process to XPC transfer that preserves `O_RDONLY` and regular-file identity;
- explicit inheritance of only allowlisted file descriptors by `GitRunner`;
- individual `/dev/fd/<file-fd>` synthetic index, loose-object, and pack/index access for every allowed operation;
- correct partial/unavailable behavior at descriptor and `RLIMIT_NOFILE` boundaries;
- preservation of descriptor access across the same-process `/usr/bin/git` transition;
- observed sandbox denial for direct working-tree reads, sibling user data, Pearcleaner private state, Git-metadata writes, project executable launch, and network access;
- the expected narrow baseline access to Apple-signed runtime files and the empty service container; and
- cleanup after success, failure, forced termination, and crash.

The evidence must come from archived signed products, sandbox-denial logs, filesystem snapshots, process-exec observation, descriptor audits, and network-denial tests, not a development-only unsigned binary. The shipped allowlist records the exact OS build family, architecture, Pearcleaner signature/version, runner signature/version, and Apple Git version tested. A change to any member invalidates the tuple until it passes again. The implementation must not substitute direct main-process Git, libgit2, live repository configuration, bookmarks, directory grants, or a broader entitlement.

## 11. Detector design

### 11.1 Secret detector

The initial secret rule pack is versioned and inspectable. A supported rule must have explainable structure such as a provider-specific prefix and format, a checksum, a strongly constrained token grammar, or a defined key-pair relationship. Standalone entropy never creates a finding.

Secret confidence and Git exposure are independent:

- **High confidence:** a supported format passes all structural checks for that rule.
- **Review suggested:** a constrained rule matches an explainable assignment or command construct but lacks a provider-verifiable structural property.
- **Not reported:** entropy or a weak keyword alone.

The scanner performs no online validation and never claims a credential is active.

Source presentation is fully masked. One centralized redactor processes every source-derived presentation field, including secret context and lifecycle scripts, before the SessionStore or UI can receive it. The renderer replaces every detected span in displayed context with the same fixed `[REDACTED]` token, regardless of original length. It masks all matches in the field, escapes controls and bidirectional characters, and limits context to 240 Unicode scalar values. If decoding, overlap, or secondary-match masking is uncertain, the UI shows only relative path, line, rule, and confidence metadata with no source context.

The raw match is used only while its bounded input buffer is alive. Correlation uses a keyed in-memory identity. When the persistent Keychain key is unavailable, the session creates an ephemeral random key so correlation can still work for that run without producing persistent fingerprints.

### 11.2 Node lockfile detector

The detector scans every competing supported lockfile within the bounded root. It groups lockfiles by adjacent project/subproject context and reports ambiguity rather than silently choosing one.

Supported formats are exact:

| Manager | Recognized file | Supported format revisions |
| --- | --- | --- |
| npm | `package-lock.json` | `lockfileVersion` 1, 2, or 3 |
| npm legacy | project-root `npm-shrinkwrap.json` | `lockfileVersion` 1, 2, or 3 |
| pnpm | `pnpm-lock.yaml` and configured `pnpm-lock.<branch>.yaml` | `lockfileVersion` 5.3, 5.4, `6.0`, `6.1`, or `9.0` |
| Yarn Classic | `yarn.lock` | header `# yarn lockfile v1` |
| Yarn Berry | `yarn.lock` | `__metadata.version` 4, 5, 6, 8, 9, or 10 |

Version fields are parsed as strings or semantic versions where appropriate, never floating-point values. pnpm multi-document YAML is parsed document by document and deduplicated. Yarn metadata version 7 and every unlisted, missing, malformed, or future revision are rejected as unsupported.

The detector excludes npm's hidden `node_modules/.package-lock.json` and unversioned pre-npm-5 shrinkwrap data. An `npm-shrinkwrap.json` is recognized only as a project/subproject root lockfile adjacent to a first-party manifest. Branch pnpm lockfiles are recognized only from bounded in-root configuration data; configuration cannot add an external path or executable behavior.

Parsers emit exact registry-backed npm coordinates, source lockfile, importer/subproject, and direct/transitive relationship where the supported format proves that relationship. Workspace, link, file, Git, tarball, patch, alias, plugin-defined, missing-version, and otherwise non-exact locators are counted as unsupported coordinates. They are not guessed into registry packages.

An exact parser fixture must define the expected dependency graph for every supported revision. A parser terminates normally only when every recognized record is classified as an exact coordinate or an explicit unsupported coordinate. Any unsupported advisory-relevant coordinate keeps dependency coverage partial even though supported coordinates can still produce findings.

### 11.3 Advisory matching

Advisory matching is local and exact. A package finding requires:

- exact npm package name and version from a supported lockfile coordinate;
- a validated OSV record whose affected package is the same npm coordinate;
- the exact installed version in the record's enumerated `affected.versions` data; and
- a record that is not withdrawn in the active cache generation.

Version one does not infer vulnerable ranges when an applicable record lacks exact enumerated versions. Such records contribute to an unsupported-advisory coverage count.

A vulnerability finding displays package and version, lockfile and subproject, dependency relationship, advisory identifier and source, affected/fixed information when supplied, source-provided severity data, and advisory-cache age. The scanner does not invent CVSS values or convert absence of source severity into its own severity.

Malicious-package records remain a distinct finding class with their source provenance. Heuristic lifecycle findings are never labelled malware or malicious packages.

### 11.4 Lifecycle detector

The detector parses JSON as data and reads only top-level package identity plus the complete top-level `scripts` object. It never resolves imports, loads JavaScript, evaluates package-manager state, or scans arbitrary dependency source for behavior.

First-party manifests are bounded in-root `package.json` files outside installed-dependency layouts. Installed manifests are only `package.json` files at a recognized package root immediately below a `node_modules` directory, including scoped-package shapes and equivalent bounded pnpm/Yarn-unplugged physical layouts. Yarn Plug'n'Play executable maps are not loaded; installed-manifest coverage is unavailable when no safe physical layout exists.

The UI states **“local manifest declares”**. It does not claim that a local installed manifest is authentic registry metadata or that a script has executed.

Presence of `preinstall`, `install`, `postinstall`, or `prepare` is informational by itself. “Review suggested” requires a versioned, explainable construct such as an interpreter downloading and piping remote content, encoded-command execution, a shell launched with an inline command, writes to sensitive locations, credential-store access, or persistence-oriented system commands.

Every raised construct names the exact rule. Before any declared script reaches the SessionStore or UI, the centralized redactor applies the complete enabled secret-rule set to the whole bounded field. Any redaction uncertainty yields metadata-only lifecycle evidence. A package or script is never called malicious from this heuristic alone.

## 12. Advisory cache

### 12.1 Source and update policy

The npm advisory adapter uses the official OSV bulk-data location at:

`https://storage.googleapis.com/osv-vulnerabilities/npm/`

Initial bootstrap and monthly rebaseline use `all.zip`. Daily update checks use `modified_id.csv` and fetch the referenced per-ID JSON records. A manual update action is also available.

An incremental synchronization is one bounded transaction:

1. Download and validate the complete CSV snapshot with a 32 MiB, 1,000,000-row, 4 KiB row, and 1 KiB field cap.
2. Starting from the last atomically activated source watermark, select every row whose modified time is greater than or equal to `watermark - 48 hours`. Equal timestamps are included.
3. Validate IDs before URL construction, then deduplicate by ID while retaining the greatest modified timestamp.
4. Fetch at most 10,000 records with at most four concurrent requests, 1 GiB aggregate response bytes, and 20 minutes wall time.
5. Apply the validated records to a staging clone, excluding withdrawn records from active matching, then run integrity and query checks.
6. Atomically activate the staging generation and its greatest fully processed watermark together.

The 48-hour inclusive overlap prevents equal-timestamp and fetch-race gaps; reapplying an ID is idempotent. A row arriving after the CSV snapshot is eligible on the next run. Exceeding an incremental bound schedules a full rebaseline instead of advancing the watermark. A candidate whose greatest source timestamp is older than the active watermark is rejected as rollback. A missing, malformed, oversized, or inconsistent incremental record aborts activation and is not interpreted as a deletion. Monthly full rebaseline reconciles the entire index.

Requests use HTTPS, a fixed host allowlist, and no cross-host or downgrade redirects. An incremental ID must be a single ASCII OSV identifier of at most 200 bytes with no slash, percent sign, dot-segment, query, fragment, whitespace, or control character; it is encoded as one URL path component. An invalid ID aborts activation. Project scanning never influences requested host, path, advisory ID, or timing. No project package name or version is sent.

### 12.2 Archive and schema hardening

Downloads enter a staging directory owned by the main app. Before activation the updater enforces:

- 512 MiB maximum compressed payload;
- 4 GiB maximum expanded archive content;
- 500,000 maximum records;
- 10 MiB maximum individual record;
- 256-byte maximum archive path component and 4,096-byte maximum relative path;
- 64 maximum JSON nesting depth and 1 MiB maximum scalar;
- 8 GiB maximum built index;
- no absolute paths, `..` traversal, duplicate destinations, links, special files, encrypted entries, or nested archives; and
- strict OSV schema, npm ecosystem, identifier, package-name, version, timestamp, withdrawn-state, and source-field validation.

The updater builds a new SQLite generation, runs integrity and query checks, computes and records local hashes, then atomically swaps a generation pointer. Before staging, it prunes any generation older than the active one; after activation, the old active generation is the sole previous known-good generation. Failed validation leaves the active generation untouched.

Combined download, expansion, staging, and generation storage has a non-overridable 22 GiB ceiling. Before each stage, the updater verifies enough free space for the declared remaining bounded output plus 2 GiB headroom; unknown or insufficient headroom aborts safely. Allocation and disk accounting occur while streaming, not only after completion.

A full update has a 60-minute wall-time ceiling. Cache networking and parsing use at most four concurrent workers and stop promptly on cancellation. These cache limits are independent of project-scan budgets and cannot be raised from project settings.

The advisory cache contains public upstream data and is separate from private project state. It lives in the main app's private Application Support directory, uses a mode-0700 directory and mode-0600 files, is excluded from iCloud/document synchronization and backups, and is never exposed through an app group or extension.

### 12.3 Freshness and failure

- up to 7 days since a successful full or incremental validation: current;
- over 7 days since successful validation: stale warning;
- over 30 days since successful validation: very stale warning; and
- no valid generation: vulnerability and malicious-package matching unavailable.

The cache records `lastSuccessfulCheckAt`, `lastActivatedAt`, and the upstream source watermark separately. A valid check with no changed records updates only `lastSuccessfulCheckAt`; it does not invent a new generation or data timestamp. All three values and the generation ID are shown in detector coverage, while every advisory result shows the bound generation and freshness. The watermark and success timestamp advance only when their whole transaction validates. A cache failure does not block secret or lifecycle inspection. The scanner never silently falls back to a corrupt, half-built, or unvalidated generation.

## 13. Findings and evidence

Every finding has a stable typed model with:

- finding kind and versioned rule identifier;
- confidence or upstream severity, whichever is applicable;
- source view: working tree, index, or current `HEAD`;
- session-only relative location and masked evidence;
- detector-specific provenance;
- suppression eligibility and exact suppression state; and
- links to its detector coverage record.

Secret findings use fully masked evidence. Dependency findings can show package identity and advisory detail during the session but do not persist those details. Lifecycle findings show a declared script during the session only after centralized all-secret masking, control/bidirectional escaping, and length limits; uncertainty produces metadata-only evidence. The script never becomes executable UI.

Remediation is explanation plus copy only. Copyable commands come from fixed templates. Every dynamic package name, exact version, and path is grammar-validated, POSIX single-quoted, rejected if it contains newline/control/bidirectional characters, and preceded by `--` where the target CLI supports an option terminator. Advisory prose and lifecycle script text never enter a command. Secret values never enter a command. Pearcleaner never launches the copied command or a terminal.

## 14. Coverage model

Coverage is a first-class result adjacent to findings. Each detector owns a transaction that records:

- candidate, scanned, skipped, unsupported, and failed file counts;
- candidate, scanned, and skipped byte counts;
- normalized reason-code counts;
- external-root, link, mount, special-file, race, unreadable, binary, oversized, and budget skips;
- Git preflight and operation status by repository;
- supported and unsupported lockfile formats and coordinates;
- installed-manifest availability and competing-lockfile ambiguity;
- advisory generation, provenance, age, and validation state; and
- detector terminal state.

Coverage transactions close independently. An exception or budget exhaustion in one detector cannot cause another detector's work to be reported complete by association.

Whole-run states are:

- **Complete:** every enabled detector completed within its declared scope and no global coverage-limiting condition occurred.
- **Partial:** usable results exist, but at least one enabled detector or global boundary stopped short of declared scope.
- **Cancelled:** user cancellation stopped the run; session results may remain visible as partial evidence.
- **Failed:** a session-level error prevented reliable usable results.
- **Unavailable:** no detector could start because the selected root could not be safely authorized.

Detector states use complete, partial, cancelled, failed, unavailable, and disabled. “Disabled” is only a user-selected configuration state, not a synonym for missing data.

Reason codes are fixed and localizable, for example `external_boundary`, `mount_boundary`, `identity_changed`, `unreadable`, `binary`, `ordinary_file_too_large`, `lockfile_too_large`, `manifest_too_large`, `unsupported_lock_revision`, `unsupported_coordinate`, `git_preflight_rejected`, `git_ignore_unsupported`, `git_descriptor_budget`, `git_timeout`, `advisory_cache_missing`, `global_byte_budget`, and `wall_time_budget`.

## 15. Resource limits and scheduling

Version-one defaults and non-overridable ceilings are fixed:

| Limit | Default | Hard ceiling |
| --- | ---: | ---: |
| General files presented to general detectors | 100,000 | 500,000 |
| General file size for secret inspection | 5 MiB | 50 MiB |
| Lockfile parser size | 50 MiB | 100 MiB |
| Package-manifest parser size | 2 MiB | 4 MiB |
| Installed manifests | 50,000 | 100,000 |
| Directory count | 50,000 | 200,000 |
| Total directory entries | 250,000 | 1,000,000 |
| Traversal depth | 128 components | 128 components |
| Relative path length | 4,096 bytes | 4,096 bytes |
| JSON/YAML nesting | 128 levels | 128 levels |
| Parsed scalar | 1 MiB | 1 MiB |
| Dependency nodes | 250,000 per lockfile; 500,000 per session | 1,000,000 per lockfile; 2,000,000 per session |
| Findings | 2,000 per file; 10,000 per session | same |
| Input bytes admitted across working tree, index, and HEAD | 2 GiB | 8 GiB |
| Scan wall time | 5 minutes | 30 minutes |
| Active worker concurrency | 4 globally | same |
| Active project scans | 1 | same |
| Git metadata descriptors per operation | 1,024 with a 128-descriptor reserve | same |
| Git operation | 30 seconds and 32 MiB combined output | same |
| Retained scanner input buffers | 256 MiB | same |
| Parser arenas | 256 MiB | same |
| Finding/session models | 128 MiB | same |
| Scanner RSS above pre-scan baseline | stop scheduling at 512 MiB | fail closed at 1 GiB |

A parser-specific file allowance does not raise another detector's allowance. For example, a 20 MiB lockfile may be parsed as a lockfile but is skipped in full by the 5 MiB secret detector, with explicit secret coverage. A logical file or blob view is charged when admitted. Detector passes sharing that immutable buffer do not charge it twice, while separate paths, hardlink entries, index stages, and current-`HEAD` views remain separate charged inputs even when bytes happen to match.

Global limits take precedence over detector limits. Within the remaining global budget, top-level source, first-party manifests, and lockfiles take precedence over installed manifests and other `node_modules` content. Parsers stream, reject input-derived preallocation, and charge retained buffers, arenas, dependency nodes, strings, and finding models before allocation. Crossing the RSS soft guard stops new work and releases caches; reaching the hard guard cancels the scan as failed/partial before accepting more input. A detector-specific exhaustion makes that detector partial. A global byte, entry, memory, or wall-time exhaustion makes the whole run partial.

The scan stops at a limit. It does not silently sample. The user may deliberately raise a tunable per-project default only up to its listed hard ceiling. No control can disable containment, archive, cache-storage, parser-depth, path, Git-output, finding, concurrency, allocation, memory, or cancellation safety caps.

Native reads are chunked and check cancellation often enough to stop scheduling and reading within 500 ms. The coordinator coalesces progress delivery to no more than once every 250 ms.

## 16. Rescans and FSEvents

Manual scan is the default. A user may opt a project into watching while Pearcleaner is running.

FSEvents is only a dirty hint. Event paths never authorize file access, extend the selected root, enter logs, or persist. Every rescan restarts descriptor-relative bounded enumeration.

Watch behavior is fixed:

- 2-second debounce after an event burst;
- at most one new scan per minute during a sustained storm;
- if a scan is active, set one dirty bit rather than enqueueing scans; and
- after the active scan completes, run at most one coalesced rescan when dirty.

Watch state is per project and defaults off. A stale bookmark or changed root identity disables the watch until explicit reauthorization. Watch-triggered partial, cancelled, or failed runs follow the same persistence rules as manual runs.

## 17. Persistence, suppressions, and logging

### 17.1 Private project state

Private state lives only in the main app's private Application Support directory with mode-0700 directories and mode-0600 files, excluded from synchronization and backup. It is not stored in the selected project, user defaults shared with extensions, or an app group.

Persisted project state is limited to:

- random project UUID;
- optional user-assigned project label;
- the security-scoped bookmark, which is the sole path-bearing persistent artifact;
- non-secret Keychain key-generation UUID;
- scan and attempt timestamps;
- advisory/cache and scanner schema versions;
- detector counts, coverage totals/reason counts, freshness, and terminal state;
- per-project budget overrides and watch opt-in; and
- exact keyed suppression fingerprints with rule ID/version and creation time.

Persistent state never contains canonical or relative paths, package names, versions, advisory evidence, source snippets, lifecycle commands, raw secret bytes, partial secret prefixes/suffixes, or unkeyed content hashes.

`lastCompleteSummary` and `lastAttempt` are separate records. Only a complete whole-run transaction atomically replaces `lastCompleteSummary`. Any terminal attempt may atomically replace the sanitized `lastAttempt` status and reason counts. A partial run remains available in the live session but cannot masquerade as the last complete run after relaunch.

### 17.2 Keyed fingerprints

On first use with no existing keyed state, the app creates a random non-synchronizing HMAC-SHA256 key in Keychain with `WhenUnlockedThisDeviceOnly` accessibility plus a random non-secret key-generation UUID. The generation UUID is stored with private project state and with the Keychain item. Fingerprints use explicit domain separation and length-delimited fields:

`domain || schemaVersion || projectUUID || findingKind || ruleID || ruleVersion || relativePathIdentity || exactMatchIdentity`

Suppression matches require exact project UUID, finding kind, rule ID, rule version, relative-path identity, and exact match identity. A rule-version change invalidates the old suppression. The HMAC inputs are never stored.

The relative-path identity is the length-delimited sequence of raw filesystem component bytes observed through verified traversal, preserving case and without Unicode folding. Secret match identity uses the exact matched bytes plus the rule's versioned structural fields. Lifecycle identity uses the exact decoded JSON scalar sequence without Unicode folding. Dependency identity uses grammar-validated exact package, version, advisory, relationship, and lockfile fields.

No two field boundaries are represented by simple delimiter concatenation.

Dependency/advisory suppressions use the same project-bound scheme over exact package, version, advisory ID, relationship, and lockfile-relative identity. Lifecycle suppressions include the exact manifest-relative identity and normalized declared-script identity.

Each scan applies existing suppressions only after the private-state generation UUID exactly matches the accessible Keychain item. It then captures the key and generation and re-reads the generation immediately before any persistence transaction. A missing, inaccessible, or changed generation makes the run ephemeral and aborts that transaction. When keyed state already exists but the matching Keychain item is absent, the app never auto-creates a replacement. Existing fingerprints are marked unreadable and the UI asks the user to reset local suppression/state explicitly; it never silently treats them as valid.

If Keychain is locked or temporarily unavailable, the scan is ephemeral: no persistent suppression is applied or created, no project summary is updated, and no unkeyed fallback is written.

### 17.3 Logs and diagnostics

Scanner logs may contain only:

- random per-session identifier;
- detector and reason codes;
- counts, byte totals, durations, and resource-limit states; and
- sanitized system error categories.

Logs, signposts, errors, metrics, and crash context must not contain project labels, bookmarks, paths, filenames, package names, versions, advisory IDs tied to a project, evidence, scripts, fingerprints, command text, or source bytes. Version one adds no scanner telemetry.

## 18. Failure rules

| Condition | Required behavior |
| --- | --- |
| Root cannot be pinned or changes identity | Stop; overall unavailable or failed; no scan results persisted |
| External link, mount, Git metadata, alternate, or package path | Skip; record exact boundary reason; continue bounded work |
| File changes during read | Discard that evidence; mark skipped/partial for affected detector |
| Binary, unreadable, or oversized file | Skip for the relevant detector; expose counts and bytes |
| Unknown/malformed lockfile revision | Reject parser input; detector partial; identify format as unsupported |
| Unsupported dependency coordinate | Count it; continue exact supported coordinates; detector partial when material scope remains unmatched |
| Missing/invalid advisory cache | Disable vulnerability and malware matching only; expose unavailable state |
| Stale advisory cache | Continue with prominent age warning; bind findings to that generation |
| Cache download/extraction/schema/index failure | Keep prior good generation; never activate staging data |
| Keychain unavailable | Ephemeral run only; no persistent correlation, suppression, or summary write |
| Git preflight, descriptor transfer/budget, runner/XPC sandbox, timeout, overflow, or malformed output failure | Git evidence partial/unavailable; never retry outside the sandbox or with weaker settings |
| Detector crash or parser error | Close its coverage transaction failed/partial; retain other trustworthy detector results |
| Global budget or wall time reached | Stop remaining work; whole run partial; preserve live evidence |
| User cancellation | Stop promptly; whole run cancelled; do not replace last complete summary |
| Persistence transaction fails | Keep prior good persistent state; report sanitized local-state error |

There is no permissive fallback for a safety check. A rejected fast path becomes explicit missing coverage.

## 19. Attacker stories and required mitigations

### Hostile clone

An attacker prepares a repository with symlink races, external worktrees, object alternates, corrupt Git objects, huge sparse files, terminal-control filenames, malicious `.gitconfig` includes, hooks, filters, package scripts, and lockfiles designed to exhaust parsers.

Required controls are descriptor-relative containment, no-follow and identity checks, external-boundary rejection, pinned read-only Git-metadata descriptors, a service-authored administrative view, independent runner/XPC sandboxing, fixed Git environment, no filters/hooks/package execution, streaming parsers, caps, escaped presentation, independent coverage transactions, and prompt cancellation.

### Advisory archive compromise or corruption

An attacker or upstream fault provides traversal entries, duplicate paths, archive bombs, oversized/deep JSON, malformed versions, withdrawn data, or a half-updated feed.

Required controls are fixed-host HTTPS, strict redirect policy, staged download, archive caps and type rejection, schema validation, exact-version matching, atomic generation activation, retained known-good generations, freshness display, and no claim of independent publisher signature.

### Resource-exhaustion project

A project contains millions of entries, deeply nested data, giant lockfiles, repeated Git objects, or enough findings to make the application unresponsive.

Required controls are global and per-detector budgets, fixed precedence, bounded buffers, one active project, four workers, memory guard, output/finding caps, coalesced progress, FSEvents rate limiting, and explicit partial coverage.

### Upstream or parser error

An OSV record is incomplete, a package manager changes format, a parser misreads dependency relationships, or system Git lacks a required safe option.

Required controls are an exact format matrix, fixture graphs, reject-unknown behavior, unsupported counts, source provenance, no range guessing, feature detection, no weakened Git fallback, and cache-generation rollback.

### Secret disclosure through the inspector

A valid secret is exposed through context, logging, a copied command, persistence, a crash, or a second secret on the same line.

Required controls are all-span fixed masking, metadata-only fallback, short-lived buffers, HMAC identities, fixed command templates, privacy canaries across all sinks, sanitized errors, and no telemetry.

### Privilege-boundary reachability

A parser bug attempts to turn scanner data into a privileged-helper request or another process invocation, or hostile Git data attempts to escape the Git-evidence service.

Required controls are the scanner target's dependency direction, no helper client in the scanner graph, pinned read-only Git-metadata descriptors, an independently signed and tested runner/XPC sandbox, one non-generic Git runner, allowlisted operation enums, process instrumentation tests, and release blocking on any unauthorized reachability.

## 20. Severity calibration

Severity is based on impact and exploitability within Pearcleaner's actual authority.

### Critical

- Hostile scan input causes arbitrary code execution in the Full Disk Access main process.
- Scanner input reaches Pearcleaner's root helper or obtains root-level action.
- The Git-evidence service escapes its sandbox and reaches the main scanner's Full Disk Access or privileged-helper authority.

### High

- Traversal or parsing reads outside the selected root without explicit separate selection.
- The scanner mutates the project, Git metadata, or package state.
- Raw or partially revealed secret material reaches persistence, logs, diagnostics, pasteboard, remediation text, or network output.
- Project input launches an unauthorized process, Git helper, hook, filter, pager, interpreter, package manager, or network request.
- System Git directly reads a working-tree file or external user data, writes Git metadata, executes a project-controlled file, gains network access, or escapes its declared sandbox.
- Advisory extraction escapes its staging directory or activates unvalidated data.

### Medium

- A partial scan is presented or persisted as complete.
- Git state is materially misclassified in a way that overstates or understates exposure.
- Stale advisory data is presented as current.
- A suppression applies across projects, rules, paths, or match identities.
- Hostile bounded input causes a repeatable crash or denial of service within declared limits.

### Low

- Recoverable performance or interface degradation within truthful coverage.
- A clearly labelled heuristic false positive.
- A provenance or presentation defect that does not alter a safety decision or leak protected data.

## 21. Verification and release gates

### 21.1 Absolute security gates

A release is blocked by any observed:

- selected-root escape;
- selected-project or Git-metadata write;
- raw/partial secret persistence or disclosure;
- unauthorized child process, helper, hook, filter, package manager, network request, or shell;
- system Git directly reading a working-tree file or external user data, writing Git metadata, executing a project-controlled file, or gaining network access;
- cache extraction escape;
- unvalidated cache activation; or
- partial result represented as complete.

Tests must observe filesystem state, XPC/runner/Git process transitions, signed sandbox state, denial of direct working-tree and external-user canaries, Git-metadata write denial, network denial, persistence bytes, logs, pasteboard models, and coverage output rather than relying only on mocked return values.

### 21.2 Parser and containment verification

- Exact dependency-graph fixtures for every listed npm, pnpm, Yarn Classic, and Yarn Berry revision.
- Reject fixtures for unlisted revisions, malformed data, floats used as versions, multi-document edge cases, unsupported locators, ambiguity, and withdrawn advisories.
- Property and fuzz tests for archive paths, JSON/YAML depth, parser sizes, Unicode/control paths, shell-token rendering, symlink chains, relative `..`, identity races, nested repositories, Git framing, and masking overlap.
- Integration fixtures for in-root and external symlinks, hardlinks, mounts where the test environment permits them, external Git metadata, alternates, includes, partial clones, hooks, filters, ignored/untracked paths, corrupt objects, timeouts, and output floods.
- Before/after project snapshots and write-denying test harnesses proving no project mutation.

### 21.3 Detector quality gates

Secret-rule evaluation uses versioned, deduplicated tuning and holdout corpora. The holdout contains at least 200 supported positive canaries and 1,000 realistic negatives across code, fixtures, documentation, generated files, and minified content.

- High-confidence secret rules must detect 100% of supported positive canaries.
- High-confidence precision must be at least 95% on the holdout, with a Wilson 95% lower confidence bound of at least 90%.
- Standalone entropy must produce zero findings.
- Every displayed context case must prove all detected spans are masked; uncertainty must select metadata-only display.

Lifecycle-rule evaluation uses a separate holdout containing at least 100 positive constructs and 500 realistic benign scripts. Version-one “review suggested” rules must achieve at least 90% recall on supported positive constructs and at least 90% precision, with each result attributable to an exact rule. Script presence alone remains informational.

### 21.4 Privacy and state verification

Canary project paths, package names, advisory details, script bodies, and secrets are injected through every success and failure path. Automated tests then inspect:

- private-state databases and journals;
- advisory-cache metadata separation;
- unified log/signpost test sinks;
- errors and diagnostic export models;
- copied-command and pasteboard models;
- crash-context adapters; and
- state after Keychain lock, key loss, cancelled scans, partial scans, and failed transactions.

The canaries must be absent everywhere the design forbids them. Rule-version, project, path, and match changes must each prevent an old suppression from matching.

### 21.5 Performance, integration, and accessibility

Before beta, the release evidence records exact hardware, OS, repository corpus, scanner version, and at least 30 cold plus 30 warm baseline runs. Subsequent releases must remain within 120% of the recorded P95 wall time and peak memory on that corpus while also respecting the absolute budgets. A release cannot redefine the corpus to hide regression.

The existing arm64 and x86_64 build/test matrix, static analysis, and `script/security_regression_checks.sh` remain required. New scanner checks are additive.

Meaningful scanner UI must be verified in the running app at realistic window sizes with keyboard-only navigation, VoiceOver labels/order, sufficient non-color status cues, Dynamic Type where supported by the existing macOS UI, reduced-motion behavior, long escaped paths, maximum counts, stale-cache warnings, and complete/partial/cancelled/failed states. Visual correctness cannot be claimed from compilation alone.

## 22. Implementation sequence

Implementation will be decomposed into separately reviewed plans and commits. Every slice must ship with the unit, integration, privacy, process, filesystem, and adversarial checks applicable to the boundaries it introduces; absolute security gates are never deferred to a later slice.

1. containment, data model, coverage ledger, persistence, and privacy kernel;
2. signed Git feasibility gate, secret detector, metadata-only Git descriptors, runner/XPC sandbox, and hardened Git evidence provider;
3. advisory updater, exact OSV index, and Node lockfile parsers;
4. first-party/installed lifecycle inspection;
5. manual scan UI, FSEvents opt-in, progress, cancellation, and accessibility;
6. cross-cutting adversarial verification, frozen quality corpus, performance evidence, and final release integration.

The first implementation plan must cover only step 1. Later slices cannot weaken an invariant established by an earlier slice. Product naming, navigation, and broader rebrand work remain outside all six plans until separately approved.

## 23. Rejected alternatives

### Separate full scanner executable

Rejected for version one. Moving all file enumeration and detectors out of process would complicate signing, IPC, distribution, version skew, bookmark transfer, and Full Disk Access behavior. The main scanner therefore uses a strict native target boundary and makes its inherited authority explicit. The narrow Git runner/XPC boundary is required only because system Git must parse hostile Git formats with read-only access to validated in-root metadata but without project-source access, Full Disk Access, write permission, project executable permission, or network access. Expanding that service into a general scanner requires a new threat model.

### Pure Swift Git implementation

Rejected for the first release. Correctly interpreting the index and current object snapshot across supported repository formats would create a substantial parser and compatibility surface.

### Bundled libgit2

Rejected for the first release. It would add a large native attack surface and ongoing security-update duty inside the Full Disk Access process.

### Generic shell or package-manager invocation

Rejected. It violates the no-execution boundary and turns hostile names, paths, manifests, and configuration into command-injection surfaces.

### Remote project analysis

Rejected. Direct local matching avoids disclosing project package names, versions, paths, and source evidence.

### Signed maintainer feed

Deferred. It could give Pearcleaner an independently signed, curated update channel, but would add maintainer infrastructure and a new trust relationship. Version one uses official OSV bulk data with explicit transport and provenance limitations.

### Git-history scanning

Deferred to a separate design. History materially expands object traversal, resource budgets, evidence semantics, and the risk of implying that reachability equals public exposure.

## 24. References informing the boundary

- OSV bulk data and ecosystem exports: <https://google.github.io/osv.dev/data/>
- OSV export and affected-version behavior: <https://google.github.io/osv.dev/faq/>
- npm lockfile format: <https://docs.npmjs.com/cli/v12/configuring-npm/package-lock-json/>
- pnpm lockfile specifications: <https://github.com/pnpm/spec>
- Yarn Classic lockfile format: <https://classic.yarnpkg.com/en/docs/yarn-lock>
- Git environment controls: <https://git-scm.com/docs/git>
- Git path/index enumeration: <https://git-scm.com/docs/git-ls-files>
- Git object batch inspection: <https://git-scm.com/docs/git-cat-file>
- Apple XPC service isolation: <https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html>
- Apple App Sandbox: <https://developer.apple.com/documentation/security/app-sandbox>
- Apple sandbox file and bookmark access: <https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox>
- Apple sandbox inheritance limits: <https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html>

These references inform the initial adapters. The executable behavior and accepted formats remain pinned by repository tests, not by silently following future upstream changes.
