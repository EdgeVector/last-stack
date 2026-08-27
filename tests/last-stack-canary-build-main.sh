#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
CLI="$ROOT/bin/last-stack-canary-build-main"
chmod +x "$CLI"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Hermetic fold "mirror" with one commit on main
mirror="$tmp/fold.git"
git init --bare "$mirror" >/dev/null
work="$tmp/fold-src"
git clone "$mirror" "$work" >/dev/null 2>&1
(
  cd "$work"
  git checkout -b main >/dev/null 2>&1
  echo 'fn main() {}' > noop.rs
  git add noop.rs
  git -c user.email=t@example.com -c user.name=t commit -m 'main tip' >/dev/null
  git push origin main >/dev/null 2>&1
)
MAIN_OID="$(git -C "$mirror" rev-parse refs/heads/main)"

builds="$tmp/canary-builds"
workdir="$tmp/wt"
export LAST_STACK_CANARY_FOLD_MIRROR="$mirror"
export LAST_STACK_CANARY_BUILDS_DIR="$builds"
export LAST_STACK_CANARY_BUILD_WORKDIR="$workdir"
export LAST_STACK_CANARY_FETCH_MAIN=0
export LAST_STACK_CANARY_MAIN_OID="$MAIN_OID"
export LAST_STACK_CANARY_BUILD_KEEP=3

# --- dry-run: would_build when nothing staged ---
out="$(
  "$CLI" --dry-run --json
)"
[ "$(printf '%s\n' "$out" | jq -r '.status')" = "would_build" ]
[ "$(printf '%s\n' "$out" | jq -r '.source_git_oid')" = "$MAIN_OID" ]
[ "$(printf '%s\n' "$out" | jq -r '.dry_run')" = "true" ]
[ ! -d "$builds/$MAIN_OID" ]

# --- skip-build with stub binaries ---
stub_bin="$tmp/bins"
mkdir -p "$stub_bin"
cat >"$stub_bin/lastdb" <<BIN
#!/usr/bin/env bash
printf 'lastdb 0.99.0-1-g${MAIN_OID:0:9}\n'
BIN
cat >"$stub_bin/lastdbd" <<BIN
#!/usr/bin/env bash
printf 'lastdbd 0.99.0-1-g${MAIN_OID:0:9}\n'
BIN

# A historical lastdb+lastdbd pair is not a complete restore-probe stage.
chmod +x "$stub_bin/lastdb" "$stub_bin/lastdbd"
set +e
incomplete_out="$(
  LAST_STACK_CANARY_BUILD_BIN_DIR="$stub_bin" \
  "$CLI" --skip-build --json 2>&1
)"
incomplete_rc=$?
set -e
[ "$incomplete_rc" -ne 0 ]
printf '%s\n' "$incomplete_out" | grep -q 'lastdb_restore_probe'

cat >"$stub_bin/lastdb_restore_probe" <<'BIN'
#!/usr/bin/env bash
exit 0
BIN
chmod +x "$stub_bin/lastdb" "$stub_bin/lastdbd" "$stub_bin/lastdb_restore_probe"

out="$(
  LAST_STACK_CANARY_BUILD_BIN_DIR="$stub_bin" \
  "$CLI" --skip-build --json
)"
[ "$(printf '%s\n' "$out" | jq -r '.status')" = "built" ]
[ "$(printf '%s\n' "$out" | jq -r '.rebuilt')" = "true" ]
[ -x "$builds/$MAIN_OID/lastdbd" ]
[ -x "$builds/$MAIN_OID/lastdb" ]
[ -x "$builds/$MAIN_OID/lastdb_restore_probe" ]
[ -f "$builds/$MAIN_OID/manifest.json" ]
man_oid="$(jq -r .source_git_oid "$builds/$MAIN_OID/manifest.json")"
[ "$man_oid" = "$MAIN_OID" ]

# --- second run: already_staged (no force) ---
out="$(
  LAST_STACK_CANARY_BUILD_BIN_DIR="$stub_bin" \
  "$CLI" --skip-build --json
)"
[ "$(printf '%s\n' "$out" | jq -r '.status')" = "already_staged" ]
[ "$(printf '%s\n' "$out" | jq -r '.rebuilt')" = "false" ]

# --- force rebuild ---
out="$(
  LAST_STACK_CANARY_BUILD_BIN_DIR="$stub_bin" \
  "$CLI" --skip-build --force --json
)"
[ "$(printf '%s\n' "$out" | jq -r '.status')" = "built" ]
[ "$(printf '%s\n' "$out" | jq -r '.rebuilt')" = "true" ]

# --- dogfood resolves the staged binary as forge-main ---
DOG="$ROOT/bin/last-stack-lastdb-canary-dogfood"
LEDGER="$ROOT/bin/last-stack-canary-pipeline"
chmod +x "$DOG" "$LEDGER"
out="$(
  env -u LAST_STACK_CANARY_LOCAL_FALLBACK_BIN \
  LAST_STACK_CANARY_MAIN_OID="$MAIN_OID" \
  LAST_STACK_CANARY_FOLD_MIRROR="$mirror" \
  LAST_STACK_CANARY_BUILDS_DIR="$builds" \
  LAST_STACK_CANARY_FETCH_MAIN=0 \
  "$DOG" --state-dir "$tmp/dog-state" --dry-run --json
)"
[ "$(printf '%s\n' "$out" | jq -r '.source')" = "forge-main" ]
[ "$(printf '%s\n' "$out" | jq -r '.safe_upgrade_args[0]')" = "--candidate" ]
staged_path="$(printf '%s\n' "$out" | jq -r '.safe_upgrade_args[1]')"
[ "$staged_path" = "$builds/$MAIN_OID/lastdbd" ]
[ "$(printf '%s\n' "$out" | jq -r '.state')" = "dogfood_green" ]

# --- registry + routine present ---
grep -q '^id = "lastdb-canary-build-main"$' "$ROOT/config/routines-registry/lastdb-canary-build-main.toml"
grep -q '^status = "active"$' "$ROOT/config/routines-registry/lastdb-canary-build-main.toml"
grep -q 'last-stack-canary-build-main' "$ROOT/routines/lastdb-canary-build-main.md"
grep -q 'Forge' "$ROOT/routines/lastdb-canary-build-main.md"

# The nightly no longer stages a build by hand in its prompt — BUILD is the
# state machine's first state, and it is the machine that pins the candidate.
# Assert the handoff still exists, in its new home.
grep -q 'BUILD' "$ROOT/routines/lastdb-canary-dogfood.md"
grep -q 'context.candidate' "$ROOT/routines/lastdb-canary-dogfood.md"

echo "ok last-stack-canary-build-main"
