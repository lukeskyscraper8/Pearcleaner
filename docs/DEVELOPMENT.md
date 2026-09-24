# Developing on your Mac

Pearcleaner installs more than an app. A signed build also registers a
privileged helper, the Sentinel login agent and a Finder extension, and it
collects privacy permissions such as Full Disk Access. macOS registers each of
these against the app copy that asked, and dragging the app to the Bin does
not undo any of it.

Every Debug build lands in a new place: Xcode's DerivedData, `.build/` from the
repo scripts, and a separate folder for every agent worktree in `.worktrees/`.
All of them share the bundle identifier `com.lukerow.Pearcleaner`. The helper
only trusts that exact identifier and team (see
`script/security_regression_checks.sh`), so debug builds can't simply use a
different one without changing that trust check. The result is several copies
fighting over one helper, one login agent and one set of settings.

Two scripts keep this to one copy.

## Build and install one copy

```sh
script/dev_build.sh
```

This builds the `Pearcleaner Debug` scheme into `.build/DevDerivedData`,
replaces `/Applications/Pearcleaner.app` with it, tells macOS to forget the
build output and opens the installed app. Run it again after every change. The
helper, Sentinel and Finder extension always point at the same path this way.

Pressing Run in Xcode still works for debugging, but it launches a copy from
DerivedData. Run `script/dev_reset.sh` afterwards if things start behaving
oddly.

## Reset everything

```sh
script/dev_reset.sh            # dry run: lists what it would remove
script/dev_reset.sh --apply    # does it
```

It quits Pearcleaner's processes, stops the helper and Sentinel, removes every
build copy outside `/Applications`, unregisters stray Finder extensions, and
deletes Pearcleaner's settings, caches, containers, keychain items and privacy
permissions. It asks for your password only to stop the privileged helper.

Options:

- `--include-installed` also removes `/Applications/Pearcleaner.app`, for a
  completely clean Mac.
- `--include-upstream` also cleans up the original Pearcleaner
  (`com.alienator88.*`) and its old helper.
- `--reset-btm` is the last resort for stale entries in System Settings >
  General > Login Items. It resets Login Items for every app on the Mac, so
  you'll need to re-allow other apps' background items, and you need to
  restart afterwards.

If a delete fails with "Operation not permitted", macOS is protecting another
app's container. Give Terminal Full Disk Access in System Settings > Privacy &
Security, or delete that folder in Finder.

## A routine that stays clean

1. Build and test only from the main checkout with `script/dev_build.sh`.
2. Before trying a branch an agent built in a worktree, run
   `script/dev_reset.sh --apply` first.
3. If the helper says it's installed but nothing works, run
   `script/dev_reset.sh --apply`, then `script/dev_build.sh`, then turn the
   helper on again in Pearcleaner's settings.
