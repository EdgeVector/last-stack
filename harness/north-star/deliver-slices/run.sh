#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../common.sh
. "$ROOT/harness/north-star/common.sh"

SLUG=north-star-lastdb-deliver-data-slices
WS="$(ns_edgevector_workspace)"
REPO="$WS/discovery"
MODE="$(ns_mode)"

if [ ! -f "$REPO/scripts/dogfood_one_loop.sh" ] || [ ! -f "$REPO/scripts/dogfood_one_loop.py" ]; then
  ns_write_report "$SLUG" FAIL "missing dogfood_one_loop scripts under $REPO/scripts" || exit 1
  exit 1
fi

notes="dogfood_one_loop.sh + .py present"
# Offline: compile-check modules + run capstone test file as plain python if it has main, else unittest
ns_require_cmd python3
set +e
import_out="$(cd "$REPO" && python3 - <<'PY'
import importlib
mods = [
  "local_match",
  "deliver_request",
  "selection_policy",
  "publish_embedding_slice",
  "relay_embedding_slice",
]
failed = []
for m in mods:
    try:
        importlib.import_module(m)
    except Exception as e:
        failed.append(f"{m}: {e}")
if failed:
    print("IMPORT_FAIL")
    print("\n".join(failed))
    raise SystemExit(1)
print("IMPORT_OK", ",".join(mods))
PY
)"
import_rc=$?
set -e
notes="$(printf '%s\nimport check rc=%s\n```\n%s\n```\n' "$notes" "$import_rc" "$import_out")"
if [ "$import_rc" -ne 0 ]; then
  ns_write_report "$SLUG" FAIL "$notes" || exit 1
  exit 1
fi

# Prefer unittest-style discovery for capstone tests without pytest
if [ -f "$REPO/tests/test_friend_graph_capstone.py" ]; then
  set +e
  ut_out="$(cd "$REPO" && python3 -m unittest tests.test_friend_graph_capstone -q 2>&1)"
  ut_rc=$?
  set -e
  notes="$(printf '%s\nunittest friend_graph_capstone rc=%s\n```\n%s\n```\n' "$notes" "$ut_rc" "$ut_out")"
  if [ "$ut_rc" -ne 0 ]; then
    ns_write_report "$SLUG" FAIL "$notes" || exit 1
    exit 1
  fi
fi

if [ "$MODE" = live ]; then
  set +e
  live_out="$(cd "$REPO" && bash scripts/dogfood_one_loop.sh 2>&1)"
  live_rc=$?
  set -e
  notes="$(printf '%s\nlive dogfood_one_loop rc=%s\n```\n%s\n```\n' "$notes" "$live_rc" "$live_out")"
  if [ "$live_rc" -ne 0 ]; then
    ns_write_report "$SLUG" FAIL "$notes" || exit 1
    exit 1
  fi
  ns_write_report "$SLUG" PASS "$notes"
  exit 0
fi

ns_write_report "$SLUG" PASS-OFFLINE "$(printf 'Discovery deliver-slices offline product proof.\n\n%s\nMode: offline (live runs scripts/dogfood_one_loop.sh on throwaway Mini homes)\n' "$notes")"
