### Security

- Replaced the privileged helper's open root shell with an allowlisted operation API and pinned the helper identity on the app-side XPC connection.
- Required confirmation for `pear://` settings changes and uninstall staging, and rejected `/` and `/System` as scan roots.
- Stopped Homebrew cask install/adopt from disabling Gatekeeper quarantine.
- Moved the Homebrew auto-update log out of `/tmp` and stopped Sentinel from accepting unauthenticated start/stop notifications.
- Restricted settings import to a known key list and refused cask `early_script` / `script` execution through the helper.
- Removed reusable sudo-password caching and cross-process password notifications.
- Restricted the privileged helper to Pearcleaner's exact signed application identity.
- Updated Sparkle to 2.9.4 for current security and reliability fixes.
- Removed the unauthenticated settings-reset deep link.

### Fixes

- Prevented Homebrew subprocesses from deadlocking when stdout and stderr are both busy.
- Corrected updater, repository, release, and issue links for the maintained fork.
- Updated Developer ID export settings and added automated build and security regression checks.
