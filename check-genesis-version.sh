#!/usr/bin/env bash
set -euo pipefail

# Prints the local Domino server's Genesis info.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/domino.sh"

run_domino_command \
    --cmd     "tell genesis info" \
    --until   "Genesis: catalog" \
    --match   "(Genesis: .*)" \
    --verbose
