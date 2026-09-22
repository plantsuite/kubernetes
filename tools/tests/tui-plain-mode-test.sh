#!/usr/bin/env bash
set -euo pipefail

tui_file="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common/tui.sh"

TUI_PLAIN=1 bash -c 'source "$1"; [[ "$TUI_PLAIN" == "1" ]]' _ "$tui_file"
env -u TUI_PLAIN bash -c 'source "$1"; [[ "$TUI_PLAIN" == "0" ]]' _ "$tui_file"

printf 'tui plain mode tests passed\n'
