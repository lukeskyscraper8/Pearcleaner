#!/bin/zsh

# Validate the filesystem shape of a Pearcleaner release ZIP before and after
# extraction. This deliberately checks names and structure, not signatures.

set -euo pipefail
export LC_ALL=C

script_root="${0:A:h}"
summary_validator="$script_root/validate_release_archive_summary.sh"

fail() {
    print -u2 "release archive payload check failed: $1"
    exit 1
}

archive_path="${1:-}"
extraction_root="${2:-}"

if [[ -z "$archive_path" ]]; then
    print -u2 "Usage: $0 ARCHIVE [EXTRACTION_ROOT]"
    exit 64
fi

if [[ ! -f "$archive_path" ]]; then
    fail "archive not found: $archive_path"
fi

if [[ ! -x "$summary_validator" ]]; then
    fail "archive summary validator is missing or not executable"
fi

archive_path="${archive_path:A}"
listing_path="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/Pearcleaner-Archive-List.XXXXXX")"
trap '/bin/rm -f "$listing_path"' EXIT

if ! archive_summary="$(/usr/bin/zipinfo -t "$archive_path")"; then
    fail "ZIP size summary could not be read"
fi
if ! archive_metrics="$("$summary_validator" "$archive_summary")"; then
    fail "ZIP size summary was invalid or exceeded release limits"
fi
summary_entry_count="${archive_metrics%% *}"

if ! /usr/bin/zipinfo -1 "$archive_path" > "$listing_path"; then
    fail "ZIP central directory could not be read"
fi

if [[ ! -s "$listing_path" ]]; then
    fail "archive is empty"
fi

entry_count=0
while IFS= read -r entry || [[ -n "$entry" ]]; do
    (( entry_count += 1 ))

    if [[ -z "$entry" || "$entry" == *[[:cntrl:]]* ]]; then
        fail "archive contains an empty or control-character entry name"
    fi

    if [[ "$entry" == /* || "$entry" == *\\* || "$entry" == *:* || "$entry" == *//* ]]; then
        fail "archive contains an ambiguous or absolute entry name: $entry"
    fi

    if [[ "$entry" != "Pearcleaner.app" \
        && "$entry" != "Pearcleaner.app/" \
        && "$entry" != "Pearcleaner.app/"* ]]; then
        fail "archive contains an entry outside Pearcleaner.app: $entry"
    fi

    if [[ "$entry" =~ '(^|/)\.\.?(/|$)' ]]; then
        fail "archive contains a traversal entry: $entry"
    fi
done < "$listing_path"

if (( entry_count == 0 )); then
    fail "archive is empty"
fi

if (( entry_count != summary_entry_count )); then
    fail "ZIP entry listing count does not match its summary"
fi

if [[ -z "$extraction_root" ]]; then
    exit 0
fi

if [[ ! -d "$extraction_root" || -L "$extraction_root" ]]; then
    fail "extraction root is missing, is not a directory, or is a symbolic link"
fi

extraction_root="${extraction_root:A}"
typeset -a top_level_entries
while IFS= read -r -d '' candidate; do
    top_level_entries+=("$candidate")
done < <(/usr/bin/find "$extraction_root" -mindepth 1 -maxdepth 1 -print0)

if (( ${#top_level_entries[@]} != 1 )); then
    fail "expected exactly one top-level entry; found ${#top_level_entries[@]}"
fi

app_path="$extraction_root/Pearcleaner.app"
if [[ "${top_level_entries[1]}" != "$app_path" || ! -d "$app_path" || -L "$app_path" ]]; then
    fail "the sole top-level entry must be a real Pearcleaner.app directory"
fi

resolved_app_path="${app_path:A}"
if [[ "${resolved_app_path:h}" != "$extraction_root" ]]; then
    fail "Pearcleaner.app resolves outside the extraction root"
fi
