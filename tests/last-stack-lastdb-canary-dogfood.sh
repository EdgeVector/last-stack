#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
CLI="$ROOT/bin/last-stack-lastdb-canary-dogfood"
LEDGER="$ROOT/bin/last-stack-canary-pipeline"
chmod +x "$CLI" "$LEDGER"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

state_dir="$tmp/state"
release_json='[
  {
    "tag_name": "v0.24.0-canary.1",
    "name": "LastDB canary",
    "prerelease": true,
    "draft": false,
    "assets": [{"name": "lastdb-aarch64-apple-darwin.tar.gz"}]
  }
]'

stub="$tmp/safe-upgrade-stub"
cat >"$stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${SAFE_UPGRADE_STUB_LOG:?}"
case " $* " in
  *" --probe-only "*) printf 'VERDICT: GREEN_PROBE_ONLY\n' ;;
  *) printf 'VERDICT: GREEN\n' ;;
esac
STUB
chmod +x "$stub"

out="$(
  LAST_STACK_CANARY_RELEASES_JSON="$release_json" \
  LAST_STACK_CANARY_SAFE_UPGRADE="$stub" \
  SAFE_UPGRADE_STUB_LOG="$tmp/safe-upgrade.log" \
  "$CLI" --state-dir "$state_dir" --dry-run --json
)"

[ "$(printf '%s\n' "$out" | jq -r '.candidate')" = "lastdb-0.24.0-canary.1" ]
[ "$(printf '%s\n' "$out" | jq -r '.state')" = "dogfood_green" ]
[ "$(printf '%s\n' "$out" | jq -r '.source')" = "github-prerelease-canary" ]
[ ! -e "$tmp/safe-upgrade.log" ]
[ "$(wc -l <"$state_dir/ledger.jsonl" | tr -d ' ')" = "3" ]

out="$(
  LAST_STACK_CANARY_RELEASES_JSON="$release_json" \
  LAST_STACK_CANARY_SAFE_UPGRADE="$stub" \
  SAFE_UPGRADE_STUB_LOG="$tmp/safe-upgrade.log" \
  "$CLI" --state-dir "$state_dir" --live --json
)"
[ "$(printf '%s\n' "$out" | jq -r '.safe_upgrade')" = "green" ]
grep -q -- '--probe-only --version 0.24.0-canary.1' "$tmp/safe-upgrade.log"

# cutover: probe then --yes
: >"$tmp/safe-upgrade.log"
cut_state="$tmp/cutover-state"
out="$(
  LAST_STACK_CANARY_RELEASES_JSON="$release_json" \
  LAST_STACK_CANARY_SAFE_UPGRADE="$stub" \
  SAFE_UPGRADE_STUB_LOG="$tmp/safe-upgrade.log" \
  LAST_STACK_CANARY_SITUATION_CHECK_CMD=pass \
  LAST_STACK_CANARY_LIVE_VERSION_CMD='echo lastdbd 0.24.0-canary.1' \
  "$CLI" --state-dir "$cut_state" --cutover --skip-situation-preflight --json
)"
[ "$(printf '%s\n' "$out" | jq -r '.mode')" = "cutover" ]
[ "$(printf '%s\n' "$out" | jq -r '.safe_upgrade')" = "cutover-green" ]
[ "$(printf '%s\n' "$out" | jq -r '.primary_mutation')" = "true" ]
grep -q -- '--probe-only --version 0.24.0-canary.1' "$tmp/safe-upgrade.log"
grep -q -- '--yes --version 0.24.0-canary.1' "$tmp/safe-upgrade.log"

fallback_bin="$tmp/lastdbd"
cat >"$fallback_bin" <<'BIN'
#!/usr/bin/env bash
printf 'lastdbd 0.25.0-local-main\n'
BIN
chmod +x "$fallback_bin"

out="$(
  LAST_STACK_CANARY_RELEASES_JSON='[]' \
  LAST_STACK_CANARY_LOCAL_FALLBACK_BIN="$fallback_bin" \
  "$CLI" --state-dir "$tmp/fallback-state" --dry-run --json
)"
[ "$(printf '%s\n' "$out" | jq -r '.source')" = "local-main" ]
[ "$(printf '%s\n' "$out" | jq -r '.safe_upgrade_args[0]')" = "--candidate" ]
[ "$(printf '%s\n' "$out" | jq -r '.state')" = "dogfood_green" ]

grep -q '^id = "lastdb-canary-dogfood"$' "$ROOT/config/routines-registry/lastdb-canary-dogfood.toml"
grep -q '^status = "active"$' "$ROOT/config/routines-registry/lastdb-canary-dogfood.toml"
grep -q 'lastdb-canary-dogfood.md' "$ROOT/config/routines-registry/lastdb-canary-dogfood.toml"
grep -q 'last-stack-lastdb-canary-dogfood' "$ROOT/routines/lastdb-canary-dogfood.md"

echo "ok last-stack-lastdb-canary-dogfood"
