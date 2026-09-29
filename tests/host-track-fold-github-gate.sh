#!/usr/bin/env bash
# lastdb and lastdbd track EdgeVector/fold. Since 2026-09-29 fold is canonical
# on GitHub and the Forgejo copy is archived, so the registry gate must be the
# GitHub remote. A Forgejo gate_head would freeze at the archived main.
# Brain: decision-2026-09-29-fold-venue-back-to-github
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
reg="$ROOT/config/host-track/apps.json"
fail() { echo "FAIL: $*" >&2; exit 1; }

for app in lastdb lastdbd; do
  jq -e --arg app "$app" '
    .apps[] | select(.app == $app)
    | .gate == "github"
      and .gate_main == "https://github.com/EdgeVector/fold.git#main"
      and .gate_remote == "https://github.com/EdgeVector/fold.git"
      and .gate_ref == "refs/heads/main"
  ' "$reg" >/dev/null || fail "$app registry gate is not the GitHub fold remote"
done

if jq -e '.apps[] | select((.gate_remote // "") | test("localhost:3300/EdgeVector/fold(\\.git)?$"))' "$reg" >/dev/null; then
  fail "an app still gates on the archived Forgejo fold copy"
fi

HOST_TRACK_REGISTRY="$reg" "$ROOT/bin/host-track" validate-registry >/dev/null \
  || fail "validate-registry rejects the registry"
echo "ok host-track-fold-github-gate"
