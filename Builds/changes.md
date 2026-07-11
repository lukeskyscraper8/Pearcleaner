### Security

- Removed reusable sudo-password caching and cross-process password notifications.
- Restricted the privileged helper to Pearcleaner's exact signed application identity.
- Updated Sparkle to 2.9.4 for current security and reliability fixes.
- Removed the unauthenticated settings-reset deep link.

### Fixes

- Prevented Homebrew subprocesses from deadlocking when stdout and stderr are both busy.
- Corrected updater, repository, release, and issue links for the maintained fork.
- Updated Developer ID export settings and added automated build and security regression checks.
