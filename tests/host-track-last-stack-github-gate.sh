#!/usr/bin/env bash
# last-stack (artifact `last-stack`, the control plane itself) moved to GitHub on
# 2026-09-30. The host-track registry must gate on the GitHub repo and follow
# green main through the GitHub puller. The LastGit artifact-release watcher is
# retired, so `track_gate_main:false` (producer owns promotion) must be gone.
# Brain: design-github-artifact-publish-path, sop-github-artifact-app-migration
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
reg="$ROOT/config/host-track/apps.json"
fail() { echo "FAIL: $*" >&2; exit 1; }

jq -e '
  .apps[] | select(.app == "last-stack")
  | .gate == "github"
    and .gate_main == "https://github.com/EdgeVector/last-stack.git#main"
    and .gate_remote == "https://github.com/EdgeVector/last-stack.git"
    and .gate_ref == "refs/heads/main"
    and .install_mode == "artifact"
    and .artifact_app == "last-stack"
    and .artifact_channel == "stable"
    and (has("track_gate_main") | not)
    and (.safe_upgrade.probes | length) > 0
' "$reg" >/dev/null || fail "last-stack registry entry is not the GitHub gate"

if jq -e '.apps[] | select(.app == "last-stack") | (.gate_main // "") | test("localhost:3300|lastdb:///")' "$reg" >/dev/null; then
  fail "last-stack still gates on Forgejo or LastGit"
fi

# The bundle is a GitHub-built source pack: it declares its platform and no
# LastGit-only context, or last-stack-github-artifact-build drops the entry.
jq -e '.artifacts[] | select(.app == "last-stack") | .platform == "darwin-arm64" and (has("context") | not)' \
  "$ROOT/.lastgit/artifacts.json" >/dev/null || fail "last-stack artifacts.json needs platform darwin-arm64 and no context"

HOST_TRACK_REGISTRY="$reg" "$ROOT/bin/host-track" validate-registry >/dev/null \
  || fail "validate-registry rejects the registry"
echo "ok host-track-last-stack-github-gate"
