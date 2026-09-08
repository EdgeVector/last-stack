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
  mkdir -p scripts
  cat >scripts/run-lastdb-restore-probe.sh <<'PROBE'
#!/usr/bin/env bash
"$PROBE" --prove-corrupt-restore "$REPORT_DIR/red-path.json"
PROBE
  chmod +x scripts/run-lastdb-restore-probe.sh
  git add noop.rs scripts/run-lastdb-restore-probe.sh
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

# The restore probe is a script plus a binary, and only the pair is source-bound.
# The script comes from the mirror at the staged OID, so --skip-build cannot
# publish a stage whose script and binaries disagree.
[ -x "$builds/$MAIN_OID/scripts/run-lastdb-restore-probe.sh" ]
grep -q -- '--prove-corrupt-restore' "$builds/$MAIN_OID/scripts/run-lastdb-restore-probe.sh"
grep -q -- 'red-path.json' "$builds/$MAIN_OID/scripts/run-lastdb-restore-probe.sh"
[ "$(jq -r .restore_probe_script "$builds/$MAIN_OID/manifest.json")" = "scripts/run-lastdb-restore-probe.sh" ]

# --- second run: already_staged (no force) ---
out="$(
  LAST_STACK_CANARY_BUILD_BIN_DIR="$stub_bin" \
  "$CLI" --skip-build --json
)"
[ "$(printf '%s\n' "$out" | jq -r '.status')" = "already_staged" ]
[ "$(printf '%s\n' "$out" | jq -r '.rebuilt')" = "false" ]

# --- a stage that lost its script is not "already staged" ---
# Otherwise the historical script-less stages stay forever, because the second
# run reports already_staged and never repairs them.
mv "$builds/$MAIN_OID/scripts/run-lastdb-restore-probe.sh" "$tmp/parked-probe.sh"
out="$(
  LAST_STACK_CANARY_BUILD_BIN_DIR="$stub_bin" \
  "$CLI" --skip-build --json
)"
[ "$(printf '%s\n' "$out" | jq -r '.status')" = "built" ]
[ -x "$builds/$MAIN_OID/scripts/run-lastdb-restore-probe.sh" ]

# --- a script that could not run the probe fails the build, not the probe run ---
bad_work="$tmp/fold-bad"
git clone "$mirror" "$bad_work" >/dev/null 2>&1
(
  cd "$bad_work"
  git checkout main >/dev/null 2>&1
  printf '#!/usr/bin/env bash\necho unrelated\n' >scripts/run-lastdb-restore-probe.sh
  git add scripts/run-lastdb-restore-probe.sh
  git -c user.email=t@example.com -c user.name=t commit -m 'break the probe script' >/dev/null
  git push origin main >/dev/null 2>&1
)
BAD_OID="$(git -C "$mirror" rev-parse refs/heads/main)"
set +e
bad_out="$(
  LAST_STACK_CANARY_MAIN_OID="$BAD_OID" \
  LAST_STACK_CANARY_BUILD_BIN_DIR="$stub_bin" \
  "$CLI" --skip-build --json 2>&1
)"
bad_rc=$?
set -e
[ "$bad_rc" -ne 0 ]
printf '%s\n' "$bad_out" | grep -q 'prove-corrupt-restore'
[ ! -d "$builds/$BAD_OID" ]

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

# The nightly uses the v2 bounded primary action. The hourly reconciler owns
# candidate evidence and the quiet window after the daemon starts.
grep -q 'last-stack-canary-v2-dogfood-gate' "$ROOT/routines/lastdb-canary-dogfood.md"
grep -q 'bounded safe-upgrade action' "$ROOT/routines/lastdb-canary-dogfood.md"

echo "ok last-stack-canary-build-main"
