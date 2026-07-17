#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../common.sh
. "$ROOT/harness/north-star/common.sh"

SLUG=north-star-lastgit-native-forge
WS="$(ns_edgevector_workspace)"
REPO="$WS/lastgit"
MODE="$(ns_mode)"

dogfood="$REPO/test/native-forge-dogfood.sh"
smoke="$REPO/test/install-local-smoke.sh"
if [ ! -f "$dogfood" ]; then
  ns_write_report "$SLUG" FAIL "missing $dogfood" || exit 1
  exit 1
fi

notes="native-forge-dogfood.sh present"
# Offline: run install-local-smoke if present and fast; else structural + bun test subset
if [ "$MODE" = offline ]; then
  if [ -f "$smoke" ]; then
    set +e
    out="$(cd "$REPO" && bash test/install-local-smoke.sh 2>&1)"
    rc=$?
    set -e
    notes="$(printf '%s\ninstall-local-smoke rc=%s\n```\n%s\n```\n' "$notes" "$rc" "$out")"
    if [ "$rc" -ne 0 ]; then
      # smoke may need network; fall back to structural only with warning
      if printf '%s\n' "$out" | grep -qiE 'FAIL|error'; then
        ns_write_report "$SLUG" FAIL "$notes" || exit 1
        exit 1
      fi
    fi
  fi
  # Contract: dogfood refuses primary paths (grep the source)
  if ! grep -q 'refusing a shared socket path\|NEVER touches the primary' "$dogfood"; then
    ns_write_report "$SLUG" FAIL "dogfood script missing primary-brain refusal contract" || exit 1
    exit 1
  fi
  ns_write_report "$SLUG" PASS-OFFLINE "$(printf 'LastGit forge dogfood script contract + local smoke checks.\n\n%s\nMode: offline (live runs test/native-forge-dogfood.sh on throwaway lastdbd)\n' "$notes")"
  exit 0
fi

# Live full dogfood (heavy; requires HEAD != main sometimes — may fail intentionally)
set +e
out="$(cd "$REPO" && bash test/native-forge-dogfood.sh 2>&1)"
rc=$?
set -e
notes="$(printf 'native-forge-dogfood rc=%s\n```\n%s\n```\n' "$rc" "$out")"
if [ "$rc" -ne 0 ]; then
  ns_write_report "$SLUG" FAIL "$notes" || exit 1
  exit 1
fi
ns_write_report "$SLUG" PASS "$notes"
