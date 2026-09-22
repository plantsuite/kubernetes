#!/usr/bin/env bash
set -euo pipefail

tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
git_bash="/mnt/c/Program Files/Git/bin/bash.exe"

run_suite() {
  local interpreter="$1"
  local path_prefix="${2:-}"
  local test_script
  for test_script in "$tests_dir"/*-test.sh; do
    "$interpreter" "${path_prefix}${test_script}"
  done
}

run_suite bash

if [[ -x "$git_bash" ]]; then
  "$git_bash" "//wsl.localhost/Ubuntu${tests_dir}/shell-portability-test.sh"
fi
