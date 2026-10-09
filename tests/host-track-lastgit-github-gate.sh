#!/usr/bin/env bash
# lastgit (the checkout-shim app, EdgeVector/lastgit) moved to GitHub on 2026-10-08.
# It was the last repo on the local Forgejo. The host-track registry must gate on the
# GitHub repo: a Forgejo gate_main would freeze at the archived copy and read as a
# permanent stale/unreachable gate the moment Forgejo is stopped.
# The app stays checkout-backed (bootstrap-recovery exemption); only its gate moves.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
reg="$ROOT/config/host-track/apps.json"
fail() { echo "FAIL: $*" >&2; exit 1; }

jq -e '
  .apps[] | select(.app == "lastgit")
  | .gate == "github"
    and .gate_main == "https://github.com/EdgeVector/lastgit.git#main"
    and .gate_remote == "https://github.com/EdgeVector/lastgit.git"
    and .gate_ref == "refs/heads/main"
    and .install_mode == "checkout"
    and .artifact_exemption.kind == "bootstrap-recovery"
' "$reg" >/dev/null || fail "lastgit registry entry is not the GitHub gate"

# No app in the registry may gate on the local Forgejo any more.
if jq -e '[.apps[] | (.gate_main // "", .gate_remote // "") | select(test("localhost:3300|127.0.0.1:3300|lastdb:///"))] | length > 0' "$reg" >/dev/null; then
  fail "an app still gates on Forgejo or LastGit"
fi
if jq -e '[.apps[] | select((.gate // "") == "forgejo")] | length > 0' "$reg" >/dev/null; then
  fail "an app still declares gate=forgejo"
fi

HOST_TRACK_REGISTRY="$reg" "$ROOT/bin/host-track" validate-registry >/dev/null \
  || fail "validate-registry rejects the registry"
echo "ok host-track-lastgit-github-gate"
