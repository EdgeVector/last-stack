#!/usr/bin/env bash
# routines (artifact `routines`) moved to GitHub on 2026-09-30. The host-track registry
# must gate on the GitHub repo and follow green main through the GitHub puller.
# A Forgejo gate_main would freeze at the archived copy; `track_gate_main:false`
# would leave stable on a hand-promoted pointer.
# The entry also keeps the post_install LaunchAgent reload and the literal links[]
# enumeration of dist/probes/*.sh (host-track does not glob).
# Brain: design-github-artifact-publish-path, sop-github-artifact-app-migration
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
reg="$ROOT/config/host-track/apps.json"
fail() { echo "FAIL: $*" >&2; exit 1; }

jq -e '
  .apps[] | select(.app == "routines")
  | .gate == "github"
    and .gate_main == "https://github.com/EdgeVector/routines.git#main"
    and .gate_remote == "https://github.com/EdgeVector/routines.git"
    and .gate_ref == "refs/heads/main"
    and .install_mode == "artifact"
    and .artifact_channel == "stable"
    and (has("track_gate_main") | not)
    and .post_install == "$HOME/.local/state/last-stack/artifacts/current/bin/last-stack-routines-host-track-post-install"
    and .safe_upgrade.post_install_phase == "after-cutover"
    and (.safe_upgrade.probes | length) == 2
    and any(.links[]; .source == "dist/routines" and .target == "$HOME/.local/bin/routines")
    and ([.links[] | select(.source | startswith("dist/probes/"))] | length) == 4
' "$reg" >/dev/null || fail "routines registry entry is not the GitHub gate"

if jq -e '.apps[] | select(.app == "routines") | (.gate_main // "") | test("localhost:3300|lastdb:///")' "$reg" >/dev/null; then
  fail "routines still gates on Forgejo or LastGit"
fi
if jq -e '.apps[] | select(.app == "routines") | (.notes // "") | test("Gate of record is Forgejo|--gate forgejo")' "$reg" >/dev/null; then
  fail "routines notes still describe the Forgejo gate"
fi

HOST_TRACK_REGISTRY="$reg" "$ROOT/bin/host-track" validate-registry >/dev/null \
  || fail "validate-registry rejects the registry"
echo "ok host-track-routines-github-gate"
