#!/usr/bin/env bash
# search (artifact `search`) moved to GitHub on 2026-09-30. The host-track registry
# must gate on the GitHub repo and follow green main through the GitHub puller.
# A Forgejo gate_main would freeze at the archived copy; `track_gate_main:false`
# would leave stable on a hand-promoted pointer.
# Brain: design-github-artifact-publish-path, sop-github-artifact-app-migration
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
reg="$ROOT/config/host-track/apps.json"
fail() { echo "FAIL: $*" >&2; exit 1; }

jq -e '
  .apps[] | select(.app == "search")
  | .gate == "github"
    and .gate_main == "https://github.com/EdgeVector/search.git#main"
    and .gate_remote == "https://github.com/EdgeVector/search.git"
    and .gate_ref == "refs/heads/main"
    and .install_mode == "artifact"
    and .artifact_channel == "stable"
    and (has("track_gate_main") | not)
    and (.safe_upgrade.probes | length) >= 2
' "$reg" >/dev/null || fail "search registry entry is not the GitHub gate"

if jq -e '.apps[] | select(.app == "search") | (.gate_main // "") | test("localhost:3300|lastdb:///")' "$reg" >/dev/null; then
  fail "search still gates on Forgejo or LastGit"
fi

HOST_TRACK_REGISTRY="$reg" "$ROOT/bin/host-track" validate-registry >/dev/null \
  || fail "validate-registry rejects the registry"
echo "ok host-track-search-github-gate"
