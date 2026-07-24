#!/bin/zsh

# Parse the C-locale summary emitted by `zipinfo -t` and enforce conservative
# release limits. Prints "ENTRY_COUNT UNCOMPRESSED_BYTES" on success.

set -euo pipefail
export LC_ALL=C

maximum_entries=100000
maximum_uncompressed_bytes=2147483648
summary="${1:-}"

fail() {
    print -u2 "release archive summary check failed: $1"
    exit 1
}

normalize_decimal() {
    local value="$1"
    while [[ ${#value} -gt 1 && "$value" == 0* ]]; do
        value="${value#0}"
    done
    print -r -- "$value"
}

decimal_exceeds() {
    local value="$1"
    local limit="$2"

    if (( ${#value} > ${#limit} )); then
        return 0
    fi
    if (( ${#value} < ${#limit} )); then
        return 1
    fi
    [[ "$value" > "$limit" ]]
}

if [[ -z "$summary" || "$summary" == *$'\n'* || "$summary" == *$'\r'* ]]; then
    fail "summary is empty or contains multiple lines"
fi

summary_pattern='^([0-9]+) files?, ([0-9]+) bytes uncompressed, ([0-9]+) bytes compressed:  +(-?[0-9]+([.][0-9]+)?|---)%$'
if [[ ! "$summary" =~ "$summary_pattern" ]]; then
    fail "summary format was not recognized"
fi

entry_count="$(normalize_decimal "$match[1]")"
uncompressed_bytes="$(normalize_decimal "$match[2]")"

if [[ "$entry_count" == "0" ]]; then
    fail "archive contains no entries"
fi

if decimal_exceeds "$entry_count" "$maximum_entries"; then
    fail "archive contains $entry_count entries; maximum is $maximum_entries"
fi

if decimal_exceeds "$uncompressed_bytes" "$maximum_uncompressed_bytes"; then
    fail "archive expands to $uncompressed_bytes bytes; maximum is $maximum_uncompressed_bytes"
fi

print -r -- "$entry_count $uncompressed_bytes"
