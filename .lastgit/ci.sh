#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

for script in setup bin/* hooks/*.sh tests/*.sh .lastgit/ci.sh; do
  [ -f "$script" ] || continue
  first_line="$(sed -n '1p' "$script")"
  case "$first_line" in
    *bash*|*sh*) bash -n "$script" ;;
  esac
done

for test_script in tests/*.sh; do
  bash "$test_script"
done
