# Pearcleaner

[![Build](https://github.com/lukeskyscraper8/Pearcleaner/actions/workflows/build.yml/badge.svg)](https://github.com/lukeskyscraper8/Pearcleaner/actions/workflows/build.yml)

> [!IMPORTANT]
> This repository is a modified, independently maintained fork of [alienator88/Pearcleaner](https://github.com/alienator88/Pearcleaner). The original project's website is [itsalin.com](https://itsalin.com). Downloads presented as official upstream releases anywhere else may be unsafe. See the [maintained-fork notice](NOTICE) and the related [community warning](https://www.reddit.com/r/macapps/comments/1ucstzy/psa_pearcleanercom_is_a_fake_site_pushing_macos/).

> [!CAUTION]
> The fork's currently published 5.4.4 ZIP fails strict macOS code-signature verification and should not be installed. Build from source or wait for a corrected signed release.

## Project Status

This fork is actively maintained with a focus on bug fixes, regressions, security, and small reliability improvements. It is not currently accepting new feature requests.

The following notice is quoted from the upstream maintainer and is retained as historical context for why this fork exists:

> As you may have noticed, development on the app has basically stopped since end of 2025, so I wanted to provide some context.
>
> Between a new job, joining a friend who is building a SaaS company, and other life priorities, I no longer have the time needed to actively maintain or continue development on the project.
>
> Another major reason is that I previously relied on my work MacBook for development. After changing jobs, I no longer have access to a Mac device that I can use for personal development work, which means I’m currently unable to build, test, or release updates for the app.
>
> Because of that, issue responses, feature work, PR reviews, and new releases are effectively on hold indefinitely for now.
>
> The project is not abandoned entirely, and I’d still like to return to it someday if circumstances change. For now though, I want to be transparent that active development is no longer possible on my end.
>
> Thank you to everyone who has used the app, reported issues, submitted ideas, or contributed. I genuinely appreciate all of the support the project has received.

<p align="center">
  <img src="https://github.com/user-attachments/assets/62cd5fcb-92d3-4d3a-9664-161a7deabd46" width="160" height="160" alt="Pearcleaner icon" />
  <br />
  <strong>Status: </strong>Independently Maintained Fork
  <br />
  <strong>Version: </strong>5.4.4
  <br />
  <a href="https://github.com/lukeskyscraper8/Pearcleaner/releases"><strong>Releases</strong></a>
  ·
  <a href="https://github.com/lukeskyscraper8/Pearcleaner/commits">Commits</a>
</p>

Pearcleaner is a free, source-available and fair-code licensed Mac app cleaner inspired by [Freemacsoft's AppCleaner](https://freemacsoft.net/appcleaner/) and [Sun Knudsen's app-cleaner guide](https://github.com/sunknudsen/guides/tree/main/archive/how-to-clean-uninstall-macos-apps-using-appcleaner-open-source-alternative). The upstream project began as its original author's exploration of macOS app installation and removal and as a way to gain Swift experience.

### Table of Contents

[Features](#features) | [Screenshots](#screenshots) | [Issues and Support](#issues-and-support) | [Requirements](#requirements) | [Download](#getting-pearcleaner) | [Build](#building-from-source) | [Deep Links](#deep-links) | [Translations](#translations) | [License](#license) | [Thanks](#thanks) | [Upstream](#upstream)

## Features

### Core

- **App Uninstall • Orphaned File Search • Development Environment Manager • File Search • Homebrew Manager • App Lipo • PKG Manager • Plugin Manager • Services Manager • Apps Updater**
- Drag/drop apps, CLI support, and [deep link automation](#deep-links)
- List or Grid view with badges for web/iOS apps
- Finder Extension for right-click uninstall
- Pearcleaner self-uninstall and other options

### Utilities

- Prune unused translations only in verified-unsigned, user-writable app bundles; signed or uninspectable bundles are skipped
- Strip unneeded architectures from verified-unsigned, user-writable universal apps without requiring Xcode's `lipo` tool
- **Sentinel Monitor**: Automatic cleanup when apps hit Trash (~2MB RAM)
- Export app bundles and file lists
- Basic Steam games support

### Customization

- Theme system with custom colors
- Include/exclude directories for searching
- Adjustable search sensitivity

### Liquid Glass

- macOS 26 Tahoe and newer use native Liquid Glass for navigation chrome, toolbar controls, and prominent actions.
- Settings -> Interface keeps the Regular/Clear glass variant setting; macOS 13-15 keep the existing theme and material styling.

## Screenshots

<img src="https://github.com/user-attachments/assets/5095d30c-3665-4b24-bf00-756baac59026" align="left" width="400" />
<img src="https://github.com/user-attachments/assets/e9841914-613e-4206-b0bd-07963bf27507" align="center" width="400" />
<p></p>
<img src="https://github.com/user-attachments/assets/c35258c2-2886-412c-a4c4-3c5e343e7a2c" align="left" width="400" />
<img src="https://github.com/user-attachments/assets/e6253ce4-b1e4-4851-a2c2-46b1f1e128cb" align="center" width="400" />

## Issues and Support

> [!WARNING]
> - Submit reproducible bugs through the fork's [issue chooser](https://github.com/lukeskyscraper8/Pearcleaner/issues/new/choose).
> - Issues with no template will be closed
> - Do not publish vulnerability details in a normal issue. Follow the [security policy](SECURITY.md).
> - This is a personal/hobby app in maintenance mode. New features and opinion-based redesign requests are out of scope.

For general usage, consult this README and the upstream [wiki](https://github.com/alienator88/Pearcleaner/wiki). If the fork behaves incorrectly and you can provide reproduction steps, file a bug here rather than upstream.

## Requirements

> [!NOTE]
> - Full Disk permission to search for files
> - Privileged Helper to perform actions on system folders

| macOS Version | Codename | Supported |
|---------------|----------|-----------|
| 13.x          | Ventura  | ✅        |
| 14.x          | Sonoma   | ✅        |
| 15.x          | Sequoia  | ✅        |
| 26.x          | Tahoe    | ✅        |
| TBD           | Beta     | ❌        |

> Versions prior to macOS 13.0 are not supported due to missing Swift/SwiftUI APIs required by the app.

## Getting Pearcleaner

<details>
  <summary>Releases</summary>

Correctly signed and notarized builds maintained by this fork will be published on its [Releases](https://github.com/lukeskyscraper8/Pearcleaner/releases) page. Do not install the 5.4.4 ZIP covered by the warning above.
</details>

<details>
  <summary>Homebrew (upstream release only)</summary>

> [!CAUTION]
> [Homebrew's `pearcleaner` cask](https://formulae.brew.sh/cask/pearcleaner) currently installs the upstream `alienator88/Pearcleaner` release, not this maintained fork. Download from this fork's Releases page if you intend to install this version.

The upstream cask can be installed with:

```sh
brew install --cask pearcleaner
```
</details>

## Building from Source

The project requires Xcode with the macOS 26 SDK. Open `Pearcleaner.xcodeproj` and use the `Pearcleaner Debug` scheme, or perform an unsigned compile check:

```sh
xcodebuild \
  -project Pearcleaner.xcodeproj \
  -scheme "Pearcleaner Debug" \
  -configuration Debug \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Unsigned builds cannot exercise signing-dependent behavior such as the Finder extension, app-group sharing, or the privileged helper. To run those components, configure your own Apple development team and use internally consistent bundle IDs, app-group IDs, and entitlements. Local source builds are not signed or notarized by this fork's maintainer; only artifacts published on this fork's Releases page and passing the verification below should be treated as its release builds.

Before publishing a release, verify the exact ZIP that will be distributed:

```sh
./script/verify_release_archive.sh \
  /path/to/Pearcleaner-version-notarized.zip \
  version \
  sha256:EXPECTED_GITHUB_DIGEST
```

The check validates the archive digest, bundle identity and version, both supported architectures, the complete code signature, signing team, Gatekeeper assessment, and stapled notarization ticket. The release-verification workflow repeats the same checks against each newly published GitHub asset.

## Deep Links

Pearcleaner registers the `pear` URL scheme. Invoke a link with `open 'pear://…'` on macOS, URL-encode file paths and other query values, and only invoke links from sources you trust.

| Action | URL |
|---|---|
| Open Pearcleaner | `pear://openPearcleaner` |
| Open Settings | `pear://openSettings` |
| Open a Settings tab | `pear://openSettings?name=Interface` |
| Open permissions | `pear://openPermissions` |
| Select an app by path | `pear://uninstallApp?path=%2FApplications%2FExample.app` |
| Select an app by name | `pear://uninstallApp?name=Example&matchType=exact` |
| Open orphaned-file search | `pear://checkOrphanedFiles` |
| Open a development environment | `pear://checkDevEnv?name=Node` |
| Open App Lipo | `pear://appLipo` |
| Check for a Pearcleaner update | `pear://checkUpdates` |
| Add or remove an app search path | `pear://appsPaths?add&path=%2FApplications` or `pear://appsPaths?remove&path=%2FApplications` |
| Add or remove an orphan search path | `pear://orphanedPaths?add&path=%2FLibrary` or `pear://orphanedPaths?remove&path=%2FLibrary` |
| Refresh the app list | `pear://refreshAppsList` |

Name matching for `uninstallApp` supports `matchType=exact` (the default) and `matchType=contains`. The older upstream `resetSettings` action is intentionally not supported by this fork.

## Translations

The inherited translation contribution guidance remains in the upstream [translation discussion](https://github.com/alienator88/Pearcleaner/discussions/137).

## License

> [!IMPORTANT]
> Pearcleaner is licensed under Apache 2.0 with [Commons Clause](https://commonsclause.com/). This means that you can use, modify, contribute to, and redistribute the source subject to the included terms, but the license prohibits selling Pearcleaner or modified versions of it. See the full [license](https://github.com/lukeskyscraper8/Pearcleaner/blob/main/LICENSE.md).

## Thanks

- Much appreciation to [Freemacsoft's AppCleaner](https://freemacsoft.net/appcleaner/) and [Sun Knudsen's app-cleaner script](https://github.com/sunknudsen/guides/tree/main/archive/how-to-clean-uninstall-macos-apps-using-appcleaner-open-source-alternative) for the inspiration
- [DharsanB](https://github.com/dharsanb) for sponsoring the original developer's Apple Developer account

## Upstream

Pearcleaner was created by [alienator88](https://github.com/alienator88). This repository contains modifications maintained independently in the fork. The original attribution and license text are retained; see [NOTICE](NOTICE) and [LICENSE.md](LICENSE.md).
