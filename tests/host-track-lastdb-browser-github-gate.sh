#!/usr/bin/env bash
# lastdb-browser (artifact `lastdb-browser`) moved to GitHub on 2026-09-30. The host-track registry
# must gate on the GitHub repo and follow green main through the GitHub puller.
# A Forgejo gate_main would freeze at the archived copy; `track_gate_main:false`
# would leave stable on a hand-promoted pointer.
# Brain: design-github-artifact-publish-path, sop-github-artifact-app-migration
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
reg="$ROOT/config/host-track/apps.json"
fail() { echo "FAIL: $*" >&2; exit 1; }

jq -e '
  .apps[] | select(.app == "lastdb-browser")
  | .gate == "github"
    and .gate_main == "https://github.com/EdgeVector/lastdb-browser.git#main"
    and .gate_remote == "https://github.com/EdgeVector/lastdb-browser.git"
    and .gate_ref == "refs/heads/main"
    and .install_mode == "artifact"
    and .artifact_channel == "stable"
    and (has("track_gate_main") | not)
    and (.post_install | length) > 0
' "$reg" >/dev/null || fail "lastdb-browser registry entry is not the GitHub gate"

if jq -e '.apps[] | select(.app == "lastdb-browser") | (.gate_main // "") | test("localhost:3300|lastdb:///")' "$reg" >/dev/null; then
  fail "lastdb-browser still gates on Forgejo or LastGit"
fi

HOST_TRACK_REGISTRY="$reg" "$ROOT/bin/host-track" validate-registry >/dev/null \
  || fail "validate-registry rejects the registry"
echo "ok host-track-lastdb-browser-github-gate"
