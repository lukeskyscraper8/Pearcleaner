#!/bin/bash
#
# Removes what Pearcleaner development builds leave behind on this Mac:
# stray app copies, background items, the Finder extension registration,
# settings, caches, keychain items and privacy permissions.
#
# Dry run by default: it only lists what it would do. Pass --apply to act.
# See docs/DEVELOPMENT.md for when to use it.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: script/dev_reset.sh [--apply] [--include-installed] [--include-upstream] [--reset-btm]

  --apply              Actually do it. Without this flag nothing is changed.
  --include-installed  Also remove copies in /Applications and ~/Applications.
                       By default installed copies are kept and only reported.
  --include-upstream   Also clean up the original Pearcleaner (com.alienator88.*),
                       including its legacy privileged helper.
  --reset-btm          Last resort: reset macOS's Background Task Management
                       database. This clears stale Login Items entries, but it
                       resets them for EVERY app, needs your password and a
                       restart afterwards.
EOF
}

APPLY=0
INCLUDE_INSTALLED=0
INCLUDE_UPSTREAM=0
RESET_BTM=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply) APPLY=1 ;;
        --include-installed) INCLUDE_INSTALLED=1 ;;
        --include-upstream) INCLUDE_UPSTREAM=1 ;;
        --reset-btm) RESET_BTM=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 64 ;;
    esac
    shift
done

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "dev_reset.sh only runs on macOS." >&2
    exit 69
fi

if [[ "$(id -u)" -eq 0 ]]; then
    echo "Run this as yourself, not with sudo. It asks for your password when it needs it." >&2
    exit 77
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
USER_UID="$(id -u)"

# Bundle identifier prefixes this script owns. Everything it touches must match one.
PREFIXES=("com.lukerow.Pearcleaner")
if [[ "$INCLUDE_UPSTREAM" -eq 1 ]]; then
    PREFIXES+=("com.alienator88.Pearcleaner")
fi

HELPER_LABELS=("com.lukerow.Pearcleaner.PearcleanerHelper")
AGENT_LABELS=("com.lukerow.PearcleanerSentinel")
KEYCHAIN_SERVICES=(
    "com.lukerow.Pearcleaner.project-scanner.hmac"
    "com.lukerow.Pearcleaner.SudoPassword"
)
TCC_IDS=(
    "com.lukerow.Pearcleaner"
    "com.lukerow.PearcleanerSentinel"
    "com.lukerow.Pearcleaner.GitFeasibilityHarness"
)
LEGACY_HELPER_FILES=()
if [[ "$INCLUDE_UPSTREAM" -eq 1 ]]; then
    HELPER_LABELS+=("com.alienator88.Pearcleaner.PearcleanerHelper")
    AGENT_LABELS+=("com.alienator88.PearcleanerSentinel")
    KEYCHAIN_SERVICES+=("com.alienator88.Pearcleaner.SudoPassword")
    TCC_IDS+=("com.alienator88.Pearcleaner" "com.alienator88.PearcleanerSentinel")
    LEGACY_HELPER_FILES=(
        "/Library/PrivilegedHelperTools/com.alienator88.Pearcleaner.PearcleanerHelper"
        "/Library/LaunchDaemons/com.alienator88.Pearcleaner.PearcleanerHelper.plist"
    )
fi

ACTIONS=0
FAILURES=0

section() {
    printf '\n== %s\n' "$1"
}

note() {
    printf '   %s\n' "$1"
}

ignore_failure() {
    "$@" || true
}

# Runs a command in --apply mode, or prints it in a dry run. Failures are
# reported and counted but never stop the script, because most items are
# optional and may already be gone.
act() {
    local description="$1"
    shift
    ACTIONS=$((ACTIONS + 1))
    if [[ "$APPLY" -eq 1 ]]; then
        printf ' - %s\n' "$description"
        if ! "$@" >/dev/null 2>&1; then
            FAILURES=$((FAILURES + 1))
            printf '   failed: %s\n' "$*"
        fi
    else
        printf ' - would %s\n' "$description"
    fi
}

matches_prefix() {
    local candidate="$1" prefix
    for prefix in "${PREFIXES[@]}"; do
        if [[ "$candidate" == "$prefix"* ]]; then
            return 0
        fi
    done
    return 1
}

bundle_identifier() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true
}

is_installed_location() {
    case "$1" in
        /Applications/*|"$HOME"/Applications/*) return 0 ;;
        *) return 1 ;;
    esac
}

# Lists every .app LaunchServices knows about whose identifier matches, even
# ones whose folder has since been deleted.
launchservices_apps() {
    "$LSREGISTER" -dump 2>/dev/null | awk -v prefixes="${PREFIXES[*]}" '
        BEGIN { n = split(prefixes, wanted, " ") }
        function flush(   i) {
            if (path ~ /\.app$/ && id != "") {
                for (i = 1; i <= n; i++) {
                    if (index(id, wanted[i]) == 1) { print path; break }
                }
            }
            path = ""; id = ""
        }
        /^-----/ { flush(); next }
        /^path:/ {
            sub(/^path:[ \t]+/, ""); sub(/ \(0x[0-9a-fA-F]+\)$/, ""); path = $0; next
        }
        /^identifier:/ {
            sub(/^identifier:[ \t]+/, ""); sub(/ \(0x[0-9a-fA-F]+\)$/, ""); id = $0; next
        }
        END { flush() }
    '
}

# Build folders where Xcode, the repo scripts and agent worktrees put copies.
filesystem_apps() {
    local search_root depth
    shopt -s nullglob
    for search_root in \
        "$HOME/Library/Developer/Xcode/DerivedData/Pearcleaner-"* \
        "$ROOT/.build" "$ROOT/build" "$ROOT/Builds" "$ROOT/.worktrees" \
        "$HOME/.Trash" "/Applications" "$HOME/Applications"; do
        [[ -d "$search_root" ]] || continue
        case "$search_root" in
            /Applications|"$HOME/Applications"|"$HOME/.Trash") depth=2 ;;
            *) depth=10 ;;
        esac
        find "$search_root" -maxdepth "$depth" -type d -name '*.app' -prune -print 2>/dev/null || true
    done
    shopt -u nullglob
}

spotlight_apps() {
    local prefix
    for prefix in "${PREFIXES[@]}"; do
        mdfind "kMDItemCFBundleIdentifier == '${prefix}*'" 2>/dev/null || true
    done
}

if [[ "$APPLY" -eq 1 ]]; then
    echo "Resetting Pearcleaner development state."
else
    echo "Dry run: nothing will be changed. Re-run with --apply to do this."
fi

section "Running processes"
found_process=0
for process_name in Pearcleaner PearcleanerSentinel GitEvidenceService GitRunner GitFeasibilityHarness; do
    if pgrep -x "$process_name" >/dev/null 2>&1; then
        found_process=1
        act "quit $process_name" pkill -x "$process_name"
    fi
done
[[ "$found_process" -eq 1 ]] || note "none running"

section "Background items"
found_background=0
for label in "${AGENT_LABELS[@]}"; do
    if launchctl print "gui/$USER_UID/$label" >/dev/null 2>&1; then
        found_background=1
        act "stop the $label login agent" launchctl bootout "gui/$USER_UID/$label"
    fi
done
for label in "${HELPER_LABELS[@]}"; do
    if launchctl print "system/$label" >/dev/null 2>&1; then
        found_background=1
        act "stop the $label privileged helper (needs your password)" sudo launchctl bootout "system/$label"
    fi
done
for legacy_file in ${LEGACY_HELPER_FILES[@]+"${LEGACY_HELPER_FILES[@]}"}; do
    if [[ -e "$legacy_file" ]]; then
        found_background=1
        act "delete legacy helper file $legacy_file (needs your password)" sudo rm -f "$legacy_file"
    fi
done
[[ "$found_background" -eq 1 ]] || note "none loaded"
note "Stale entries can stay listed in System Settings > General > Login Items."
note "Removing the app copies below usually clears them; --reset-btm is the last resort."

section "App copies"
candidates="$( { launchservices_apps; filesystem_apps; spotlight_apps; } | sort -u )"
kept=0
removed=0
while IFS= read -r app_path; do
    [[ -n "$app_path" && "$app_path" == *.app ]] || continue

    if [[ -d "$app_path" ]]; then
        identifier="$(bundle_identifier "$app_path")"
        matches_prefix "$identifier" || continue
    else
        # Only LaunchServices still remembers this copy; drop the record.
        act "forget missing copy $app_path" ignore_failure "$LSREGISTER" -u "$app_path"
        continue
    fi

    if is_installed_location "$app_path" && [[ "$INCLUDE_INSTALLED" -eq 0 ]]; then
        kept=$((kept + 1))
        note "keeping installed copy $app_path ($identifier)"
        continue
    fi

    removed=$((removed + 1))
    finder_extension="$app_path/Contents/PlugIns/FinderOpen.appex"
    if [[ -d "$finder_extension" ]]; then
        act "unregister the Finder extension inside $app_path" pluginkit -r "$finder_extension"
    fi
    act "unregister $app_path from LaunchServices" "$LSREGISTER" -u "$app_path"
    act "delete $app_path ($identifier)" rm -rf "$app_path"
done <<< "$candidates"
if [[ "$removed" -eq 0 && "$kept" -eq 0 ]]; then
    note "no copies found"
fi

section "Finder extension registrations"
found_extension=0
for prefix in "${PREFIXES[@]}"; do
    while IFS= read -r appex_path; do
        [[ "$appex_path" == *.appex ]] || continue
        containing_app="${appex_path%/Contents/PlugIns/*}"
        if is_installed_location "$containing_app" && [[ "$INCLUDE_INSTALLED" -eq 0 ]]; then
            continue
        fi
        found_extension=1
        act "unregister Finder extension $appex_path" ignore_failure pluginkit -r "$appex_path"
    done < <(pluginkit -m -A -v -i "$prefix.FinderOpen" 2>/dev/null | awk -F'\t' '{ print $NF }')
done
[[ "$found_extension" -eq 1 ]] || note "none left outside installed copies"

section "Settings, caches and data"
shopt -s nullglob nocaseglob
found_data=0
for prefix in "${PREFIXES[@]}"; do
    vendor="${prefix%.Pearcleaner}"
    for preferences_file in "$HOME/Library/Preferences/$prefix"*.plist; do
        domain="$(basename "$preferences_file" .plist)"
        found_data=1
        act "delete settings for $domain" defaults delete "$domain"
    done
    for data_path in \
        "$HOME/Library/Group Containers/group.$vendor.pearcleaner"* \
        "$HOME/Library/Containers/$prefix"* \
        "$HOME/Library/Caches/$prefix"* \
        "$HOME/Library/HTTPStorages/$prefix"* \
        "$HOME/Library/WebKit/$prefix"* \
        "$HOME/Library/Saved Application State/$prefix"*; do
        found_data=1
        act "delete $data_path" rm -rf "$data_path"
    done
done
if [[ -d "$HOME/Library/Application Support/Pearcleaner" ]]; then
    found_data=1
    act "delete $HOME/Library/Application Support/Pearcleaner" rm -rf "$HOME/Library/Application Support/Pearcleaner"
fi
shopt -u nullglob nocaseglob
[[ "$found_data" -eq 1 ]] || note "none found"
note "macOS may block deleting other apps' containers from Terminal."
note "If a delete fails, give Terminal Full Disk Access or delete it in Finder."

section "Keychain items"
found_keychain=0
for service in "${KEYCHAIN_SERVICES[@]}"; do
    if security find-generic-password -s "$service" >/dev/null 2>&1; then
        found_keychain=1
        act "delete keychain item $service" security delete-generic-password -s "$service"
    fi
done
[[ "$found_keychain" -eq 1 ]] || note "none found"

section "Privacy permissions (Full Disk Access and similar)"
for tcc_id in "${TCC_IDS[@]}"; do
    act "reset privacy permissions for $tcc_id" ignore_failure tccutil reset All "$tcc_id"
done

if [[ "$RESET_BTM" -eq 1 ]]; then
    section "Background Task Management database"
    note "This resets Login Items approvals for every app on this Mac."
    act "reset the Background Task Management database (needs your password)" sudo sfltool resetbtm
    note "Restart your Mac afterwards."
fi

section "Summary"
if [[ "$APPLY" -eq 1 ]]; then
    echo "   Done: $ACTIONS actions, $FAILURES failed."
    if [[ "$kept" -gt 0 ]]; then
        echo "   Kept $kept installed copy/copies. Use --include-installed to remove them too."
    fi
else
    echo "   $ACTIONS actions planned. Nothing was changed."
    echo "   Run: script/dev_reset.sh --apply"
fi
