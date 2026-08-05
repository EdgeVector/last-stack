#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
CLI="$ROOT/bin/last-stack-lastdb-canary-dogfood"
LEDGER="$ROOT/bin/last-stack-canary-pipeline"
chmod +x "$CLI" "$LEDGER"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

state_dir="$tmp/state"
# Hermetic main tip — must not match host-built describe binaries accidentally.
MAIN_OID="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
# Isolate canary-builds + fold mirror so host state cannot pollute resolution.
export LAST_STACK_CANARY_MAIN_OID="$MAIN_OID"
export LAST_STACK_CANARY_FOLD_MIRROR="$tmp/no-fold-mirror"
export LAST_STACK_CANARY_BUILDS_DIR="$tmp/canary-builds"
export LAST_STACK_CANARY_FETCH_MAIN=0
mkdir -p "$LAST_STACK_CANARY_BUILDS_DIR"

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

# --- default path: forge-main local binary (trusted override) ---
fallback_bin="$tmp/lastdbd"
cat >"$fallback_bin" <<'BIN'
#!/usr/bin/env bash
printf 'lastdbd 0.25.0-local-main\n'
BIN
chmod +x "$fallback_bin"

out="$(
  LAST_STACK_CANARY_LOCAL_FALLBACK_BIN="$fallback_bin" \
  LAST_STACK_CANARY_SAFE_UPGRADE="$stub" \
  SAFE_UPGRADE_STUB_LOG="$tmp/safe-upgrade.log" \
  "$CLI" --state-dir "$tmp/fallback-state" --dry-run --json
)"
[ "$(printf '%s\n' "$out" | jq -r '.source')" = "forge-main" ]
[ "$(printf '%s\n' "$out" | jq -r '.safe_upgrade_args[0]')" = "--candidate" ]
[ "$(printf '%s\n' "$out" | jq -r '.state')" = "dogfood_green" ]

# --- without a local binary: fail closed (no GH by default) ---
out="$(
  env -u LAST_STACK_CANARY_LOCAL_FALLBACK_BIN \
  LAST_STACK_CANARY_SAFE_UPGRADE="$stub" \
  "$CLI" --state-dir "$tmp/missing-state" --dry-run --json
)" || true
[ "$(printf '%s\n' "$out" | jq -r '.source')" = "forge-main-missing" ]
[ "$(printf '%s\n' "$out" | jq -r '.state')" = "dogfood_red" ]
[ "$(printf '%s\n' "$out" | jq -r '.safe_upgrade')" = "not-run-no-candidate" ]

# --- stale GH prerelease without source_git_oid matching main: refused ---
stale_json='[
  {
    "tag_name": "v0.23.3-canary.20260801",
    "name": "stale canary",
    "prerelease": true,
    "draft": false,
    "assets": [{"name": "lastdb-aarch64-apple-darwin.tar.gz"}]
  }
]'
out="$(
  env -u LAST_STACK_CANARY_LOCAL_FALLBACK_BIN \
  LAST_STACK_CANARY_RELEASES_JSON="$stale_json" \
  LAST_STACK_CANARY_SAFE_UPGRADE="$stub" \
  "$CLI" --state-dir "$tmp/stale-gh-state" --dry-run --json
)" || true
[ "$(printf '%s\n' "$out" | jq -r '.source')" = "forge-main-missing" ]
[ "$(printf '%s\n' "$out" | jq -r '.state')" = "dogfood_red" ]

# --- GH opt-in only when source_git_oid matches main tip ---
release_json="$(
  MAIN_OID="$MAIN_OID" python3 - <<'PY'
import json, os
print(json.dumps([
  {
    "tag_name": "v0.24.0-canary.1",
    "name": "LastDB canary",
    "prerelease": True,
    "draft": False,
    "source_git_oid": os.environ["MAIN_OID"],
    "assets": [{"name": "lastdb-aarch64-apple-darwin.tar.gz"}],
  }
]))
PY
)"

out="$(
  env -u LAST_STACK_CANARY_LOCAL_FALLBACK_BIN \
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
  env -u LAST_STACK_CANARY_LOCAL_FALLBACK_BIN \
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
  env -u LAST_STACK_CANARY_LOCAL_FALLBACK_BIN \
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

# --- local preferred over GH even when GH is allowed ---
out="$(
  LAST_STACK_CANARY_LOCAL_FALLBACK_BIN="$fallback_bin" \
  LAST_STACK_CANARY_RELEASES_JSON="$release_json" \
  LAST_STACK_CANARY_SAFE_UPGRADE="$stub" \
  "$CLI" --state-dir "$tmp/prefer-local-state" --dry-run --json
)"
[ "$(printf '%s\n' "$out" | jq -r '.source')" = "forge-main" ]
[ "$(printf '%s\n' "$out" | jq -r '.safe_upgrade_args[0]')" = "--candidate" ]

# --- staged canary-builds/<oid>/lastdbd with matching describe shortsha ---
stage="$LAST_STACK_CANARY_BUILDS_DIR/$MAIN_OID"
mkdir -p "$stage"
staged="$stage/lastdbd"
cat >"$staged" <<BIN
#!/usr/bin/env bash
printf 'lastdbd 0.26.0-1-g${MAIN_OID:0:9}\n'
BIN
chmod +x "$staged"
# write manifest too
printf '{"source_git_oid":"%s"}\n' "$MAIN_OID" >"$stage/manifest.json"

out="$(
  env -u LAST_STACK_CANARY_LOCAL_FALLBACK_BIN \
  LAST_STACK_CANARY_SAFE_UPGRADE="$stub" \
  "$CLI" --state-dir "$tmp/staged-state" --dry-run --json
)"
[ "$(printf '%s\n' "$out" | jq -r '.source')" = "forge-main" ]
[ "$(printf '%s\n' "$out" | jq -r '.safe_upgrade_args[1]')" = "$staged" ]
[ "$(printf '%s\n' "$out" | jq -r '.state')" = "dogfood_green" ]

grep -q '^id = "lastdb-canary-dogfood"$' "$ROOT/config/routines-registry/lastdb-canary-dogfood.toml"
grep -q '^status = "active"$' "$ROOT/config/routines-registry/lastdb-canary-dogfood.toml"
grep -q 'lastdb-canary-dogfood.md' "$ROOT/config/routines-registry/lastdb-canary-dogfood.toml"
grep -q 'last-stack-lastdb-canary-dogfood' "$ROOT/routines/lastdb-canary-dogfood.md"
grep -q 'Forge' "$ROOT/routines/lastdb-canary-dogfood.md"
grep -q 'forge-main' "$ROOT/routines/lastdb-canary-dogfood.md"

echo "ok last-stack-lastdb-canary-dogfood"
