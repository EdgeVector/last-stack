#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

export HOME="$tmp/home"
export HOST_TRACK_STAMP_DIR="$tmp/stamps"
mkdir -p "$HOME/.local/bin" "$tmp/stamps"

good_registry="$tmp/good.json"
bad_registry="$tmp/bad.json"

cat > "$good_registry" <<'EOF'
{
  "defaults": { "install_mode": "artifact" },
  "apps": [
    {
      "app": "demo",
      "kind": "artifact-bundle",
      "command": "demo",
      "install_mode": "artifact",
      "install_root": "$HOME/apps/demo",
      "links": [{"source": "bin/demo", "target": "$HOME/.local/bin/demo"}],
      "notes": "artifact fixture"
    },
    {
      "app": "lastgit",
      "kind": "checkout-shim",
      "command": "lastgit",
      "install_mode": "checkout",
      "host_track": "$HOME/lastgit",
      "artifact_exemption": {
        "kind": "bootstrap-recovery",
        "owner": "platform",
        "rationale": "bootstrap forge stays checkout-backed"
      },
      "notes": "exempt fixture"
    },
    {
      "app": "lastdb",
      "kind": "safe-upgrade-managed binary",
      "command": "lastdb",
      "install_mode": "checkout",
      "artifact_exemption": {
        "kind": "deployment-only",
        "owner": "platform",
        "rationale": "lastdb-safe-upgrade only"
      },
      "notes": "exempt fixture"
    }
  ]
}
EOF

# Inject non-exempt non-artifact (local-safe without exemption) → must fail closed
jq '.apps += [{
  "app": "rogue",
  "kind": "local-safe cli",
  "command": "rogue",
  "install_mode": "local-safe",
  "install_root": "$HOME/apps/rogue",
  "links": [{"source": "bin/rogue", "target": "$HOME/.local/bin/rogue"}],
  "notes": "fake non-exempt non-artifact"
}]' "$good_registry" > "$bad_registry"

# Also a bare checkout without exemption
jq '.apps += [{
  "app": "bare-checkout",
  "kind": "checkout-shim",
  "command": "bare",
  "install_mode": "checkout",
  "host_track": "$HOME/bare",
  "notes": "checkout without exemption"
}]' "$bad_registry" > "$tmp/bad2.json"
mv "$tmp/bad2.json" "$bad_registry"

# Good registry: validate-registry exits 0
if ! HOST_TRACK_REGISTRY="$good_registry" "$ROOT/bin/host-track" validate-registry --json >"$tmp/good.out"; then
  cat "$tmp/good.out" >&2
  fail "good registry should pass validate-registry"
fi
jq -e '.ok == true and .non_compliant == 0 and .policy == "artifact_or_exempt"' "$tmp/good.out" >/dev/null \
  || fail "good report shape wrong: $(cat "$tmp/good.out")"
jq -e 'any(.apps[]; .app == "lastgit" and .registry_compliance == "exempt" and .artifact_exemption.kind == "bootstrap-recovery")' \
  "$tmp/good.out" >/dev/null || fail "lastgit not exempt in good report"
jq -e 'any(.apps[]; .app == "demo" and .registry_compliance == "artifact")' \
  "$tmp/good.out" >/dev/null || fail "demo not artifact in good report"
jq -e 'any(.apps[]; .app == "lastdb" and .registry_compliance == "exempt")' \
  "$tmp/good.out" >/dev/null || fail "lastdb not exempt in good report"

# Bad registry: fail closed
if HOST_TRACK_REGISTRY="$bad_registry" "$ROOT/bin/host-track" validate-registry --json >"$tmp/bad.out" 2>"$tmp/bad.err"; then
  cat "$tmp/bad.out" "$tmp/bad.err" >&2
  fail "bad registry (injected non-exempt non-artifact) should fail closed"
fi
jq -e '.ok == false and .non_compliant >= 2' "$tmp/bad.out" >/dev/null \
  || fail "bad report should mark non_compliant: $(cat "$tmp/bad.out")"
jq -e 'any(.apps[]; .app == "rogue" and .registry_compliance == "non_compliant")' \
  "$tmp/bad.out" >/dev/null || fail "rogue should be non_compliant"
jq -e 'any(.apps[]; .app == "bare-checkout" and .registry_compliance == "non_compliant")' \
  "$tmp/bad.out" >/dev/null || fail "bare-checkout should be non_compliant"

# status --json surfaces compliance + exemption (no live install required)
status="$(HOST_TRACK_REGISTRY="$good_registry" "$ROOT/bin/host-track" status --json lastgit)"
printf '%s\n' "$status" | jq -e '
  .registry_compliance == "exempt"
  and .artifact_exemption.kind == "bootstrap-recovery"
  and (.artifact_exemption.owner | length) > 0
' >/dev/null || fail "status lastgit missing compliance/exemption: $status"

status_demo="$(HOST_TRACK_REGISTRY="$good_registry" "$ROOT/bin/host-track" status --json demo)"
printf '%s\n' "$status_demo" | jq -e '
  .registry_compliance == "artifact"
  and .artifact_exemption == null
' >/dev/null || fail "status demo missing artifact compliance: $status_demo"

status_rogue="$(HOST_TRACK_REGISTRY="$bad_registry" "$ROOT/bin/host-track" status --json rogue)"
printf '%s\n' "$status_rogue" | jq -e '.registry_compliance == "non_compliant"' >/dev/null \
  || fail "status rogue should be non_compliant: $status_rogue"

# Default registry seeds: lastgit/lastdb exempt; agent CLIs + last-stack/remote artifact.
default_report="$(HOST_TRACK_REGISTRY="$ROOT/config/host-track/apps.json" \
  "$ROOT/bin/host-track" validate-registry --json || true)"
printf '%s\n' "$default_report" | jq -e '
  .ok == true and .non_compliant == 0
  and any(.apps[]; .app == "lastgit" and .registry_compliance == "exempt")
  and any(.apps[]; .app == "lastdb" and .registry_compliance == "exempt")
  and any(.apps[]; .app == "lastdbd" and .registry_compliance == "exempt")
  and any(.apps[]; .app == "last-stack" and .registry_compliance == "artifact")
  and any(.apps[]; .app == "remote" and .registry_compliance == "artifact")
  and any(.apps[]; .app == "brain" and .registry_compliance == "artifact")
  and any(.apps[]; .app == "routines" and .registry_compliance == "artifact")
  and any(.apps[]; .app == "lastsecrets" and .registry_compliance == "artifact")
  and any(.apps[]; .app == "configurations" and .registry_compliance == "artifact")
  and any(.apps[]; .app == "search" and .registry_compliance == "artifact")
' >/dev/null || fail "default registry compliance map wrong: $default_report"

printf 'ok: host-track registry compliance\n'
