#!/bin/bash
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
if [[ -n "$1" ]]; then
    exec "$SCRIPT_DIR/../MacOS/Pearcleaner" ask-password --message "$1"
fi
exec "$SCRIPT_DIR/../MacOS/Pearcleaner" ask-password
