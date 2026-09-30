#!/usr/bin/env bash
# north-star-slug: north-star-forge-build-release-parity
# Prove the checked-in Forge build and release routing contract.
# Offline mode uses source files and isolated runner fixtures only. It does not
# open a LastDB home, call the Forge API, or publish an artifact.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../common.sh
. "$ROOT/harness/north-star/common.sh"

SLUG=north-star-forge-build-release-parity
MODE="$(ns_mode)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/forge-build-release-parity.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

notes=()
failures=()

pass() { notes+=("- PASS: $1"); }
fail() { failures+=("- FAIL: $1"); }

require_file() {
  local path="$1" label="$2"
  if [ -f "$path" ]; then
    pass "$label is present."
  else
    fail "$label is absent: $path"
  fi
}

require_text() {
  local path="$1" label="$2" marker="$3"
  if [ ! -f "$path" ]; then
    fail "$label is absent: $path"
  elif grep -Fq -- "$marker" "$path"; then
    pass "$label contains $marker."
  else
    fail "$label lacks $marker."
  fi
}

case "$MODE" in
  offline|live) ;;
  *)
    ns_write_report "$SLUG" FAIL "Unsupported proof mode: $MODE." || true
    exit 1
    ;;
esac

CONFIG="$ROOT/config/forge-runner-lanes.json"
WORKFLOW="$ROOT/.forgejo/workflows/ci.yml"
ARTIFACTS="$ROOT/.lastgit/artifacts.json"
RELEASE_PUBLISH="$ROOT/bin/last-stack-release-publish"
PROMOTE_RESOLVER="$ROOT/lib/fold_promote_script.py"

# The lane policy is the source of truth for build/release separation. These
# checks keep the important fields visible in the durable proof report.
require_file "$CONFIG" "Forge runner lane policy"
if [ -f "$CONFIG" ]; then
  if python3 - "$CONFIG" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
merge = data["merge_gate"]
heavy = data["heavy"]

assert "macos-arm64" in merge["labels"]
assert "heavy" in merge["forbidden_on_lane"]
assert "heavy" in heavy["labels"]
assert "macos" in heavy["labels"]
assert "heavy" in heavy["required_labels_any"]
routing = heavy["workflow_routing"]
assert set(("heavy", "macos")).issubset(routing["runs_on"])
assert "ci-required" in routing["do_not_require_status"]
PY
  then
    pass "lane policy separates merge-gate labels from heavy release/deploy labels."
  else
    fail "lane policy does not contain the required merge-gate and heavy-lane contract."
  fi
fi

# The checked-in workflow must keep required CI before the stable artifact
# publication step. The macos-arm64 publish lane is intentional: this repo's
# local artifact CAS lives on that host, as the workflow documents.
require_text "$WORKFLOW" "Forge workflow" "jobs:"
require_text "$WORKFLOW" "required CI job" "ci-required:"
require_text "$WORKFLOW" "required CI lane" "runs-on: macos-arm64"
require_text "$WORKFLOW" "stable publication dependency" "needs: ci-required"
require_text "$WORKFLOW" "stable publication lane" "runs-on: macos-arm64"
require_text "$WORKFLOW" "stable artifact publish command" "lastgit artifact publish"
require_text "$WORKFLOW" "stable artifact promotion command" "lastgit artifact promote --gate forgejo"
require_text "$WORKFLOW" "main-only publication guard" "github.event_name == 'push' && github.ref == 'refs/heads/main'"

# The artifact manifest must carry the harness and the release-supporting
# product surfaces. This catches an apparently green build that cannot ship
# the proof runner or its release helpers.
require_text "$ARTIFACTS" "artifact manifest" '"app": "last-stack"'
require_text "$ARTIFACTS" "artifact manifest" '"harness"'
require_text "$ARTIFACTS" "artifact manifest" '"bin"'
require_text "$ARTIFACTS" "artifact manifest" '"lib"'

require_file "$RELEASE_PUBLISH" "release publisher"
require_text "$RELEASE_PUBLISH" "release publisher" "--if-needed"
require_text "$RELEASE_PUBLISH" "release publisher" "forge-promote-homebrew-stable.sh"
require_text "$RELEASE_PUBLISH" "release publisher" "registry/stable.json"
require_file "$PROMOTE_RESOLVER" "Forge promotion resolver"
require_text "$PROMOTE_RESOLVER" "Forge promotion resolver" "refs/remotes/origin/main"
require_text "$PROMOTE_RESOLVER" "Forge promotion resolver" "http://localhost:3300/"
require_text "$PROMOTE_RESOLVER" "Forge promotion resolver" "lastdb:///"

# Exercise the real lane checker against throwaway homes. This proves the
# checker and avoids dependence on the shared runner homes in offline mode.
mkdir -p "$TMP/merge" "$TMP/heavy"
cat >"$TMP/merge/.runner" <<'EOF'
{
  "id": 1,
  "name": "fixture-merge-gate",
  "address": "http://fixture.invalid",
  "labels": ["macos-arm64:host"]
}
EOF
cat >"$TMP/merge/config.yml" <<'EOF'
runner:
  capacity: 2
  labels:
    - macos-arm64:host
EOF
cat >"$TMP/heavy/.runner" <<'EOF'
{
  "id": 2,
  "name": "fixture-heavy-release",
  "address": "http://fixture.invalid",
  "labels": ["macos:host", "heavy:host"]
}
EOF
cat >"$TMP/heavy/config.yml" <<'EOF'
runner:
  capacity: 1
  labels:
    - macos:host
    - heavy:host
EOF

LANES_JSON="$TMP/lanes.json"
LANES_ERR="$TMP/lanes.err"
set +e
bash "$ROOT/bin/last-stack-forge-runner-lanes" \
  --json --check --config "$CONFIG" \
  --homes "$TMP/merge:$TMP/heavy" >"$LANES_JSON" 2>"$LANES_ERR"
lanes_rc=$?
set -e
if [ "$lanes_rc" -eq 0 ] && python3 - "$LANES_JSON" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["check_ok"] is True
assert data["heavy_ok_local"] is True
assert data["merge_gate_has_heavy"] is False
assert data["separated_from_merge_gate"] is True
assert data["merge_gate_unchanged"] is True
PY
then
  pass "real Forge lane checker accepts isolated merge-gate and heavy fixtures."
else
  lanes_error="$(tr '\n' ' ' <"$LANES_ERR")"
  fail "real Forge lane checker rejected isolated fixtures (rc=$lanes_rc): ${lanes_error:-invalid JSON output}."
fi

if [ "$MODE" = live ]; then
  # Live mode adds the read-only Forge inventory check. The release proof
  # itself remains a separate signed promotion receipt, because this harness
  # must never publish or mutate a release from a validation command.
  live_json="$TMP/live-lanes.json"
  live_err="$TMP/live-lanes.err"
  set +e
  bash "$ROOT/bin/last-stack-forge-runner-lanes" \
    --json --check --live --config "$CONFIG" >"$live_json" 2>"$live_err"
  live_rc=$?
  set -e
  if [ "$live_rc" -eq 0 ] && python3 - "$live_json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["check_ok"] is True
assert data["live"]["enabled"] is True
PY
  then
    pass "live Forge inventory confirms the separated runner lanes."
  else
    live_error="$(tr '\n' ' ' <"$live_err")"
    fail "live Forge inventory did not confirm the lane contract (rc=$live_rc): ${live_error:-check failed}."
  fi
fi

body="Forge build and release parity terminal proof.

Mode: $MODE
The offline proof reads checked-in source and uses throwaway runner fixtures.
It does not open a LastDB home, call the Forge API, publish an artifact, or
promote a stable release.

Checks:
$(printf '%s\n' "${notes[@]}")"

if [ "${#failures[@]}" -gt 0 ]; then
  body="$body
Failures:
$(printf '%s\n' "${failures[@]}")"
  ns_write_report "$SLUG" FAIL "$body" || true
  exit 1
fi

if [ "$MODE" = live ]; then
  ns_write_report "$SLUG" PASS "$body"
else
  ns_write_report "$SLUG" PASS-OFFLINE "$body"
fi
