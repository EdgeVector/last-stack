#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
CLI="$ROOT/bin/last-stack-canary-resolve-lastdbd"
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
  echo tip > README
  git add README
  git -c user.email=t@example.com -c user.name=t commit -m 'main tip' >/dev/null
  git push origin main >/dev/null 2>&1
)
MAIN_OID="$(git -C "$mirror" rev-parse refs/heads/main)"
SHORT="${MAIN_OID:0:9}"

builds="$tmp/canary-builds"
staged="$tmp/smoke-staged"
current_dir="$tmp/current"
mkdir -p "$builds" "$staged" "$current_dir"

export LAST_STACK_CANARY_FOLD_MIRROR="$mirror"
export LAST_STACK_CANARY_BUILDS_DIR="$builds"
export LAST_STACK_SMOKE_STAGED_DIR="$staged"
export LAST_STACK_CANARY_FETCH_MAIN=0
export LAST_STACK_CANARY_MAIN_OID="$MAIN_OID"
export LASTDB_CURRENT_BIN="$current_dir/lastdbd"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# A stage's restore-probe script. The resolver checks contents, not just the
# path, so a stage cannot be declared complete with a script that could not run
# the probe.
write_probe_script() {
  local dir="$1"
  mkdir -p "$dir/scripts"
  cat >"$dir/scripts/run-lastdb-restore-probe.sh" <<'PROBE'
#!/usr/bin/env bash
"$PROBE" --prove-corrupt-restore "$REPORT_DIR/red-path.json"
PROBE
  chmod +x "$dir/scripts/run-lastdb-restore-probe.sh"
}

# --- no binaries: need_build ---
set +e
out="$("$CLI" --json 2>/dev/null)"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "empty resolve rc=$rc out=$out"
[ "$(printf '%s\n' "$out" | jq -r .status)" = "need_build" ] || fail "empty status: $out"
[ "$(printf '%s\n' "$out" | jq -r .wanted_oid)" = "$MAIN_OID" ] || fail "wanted oid: $out"

# --- exact canary-builds stage ---
mkdir -p "$builds/$MAIN_OID"
printf '#!/bin/sh\necho lastdbd staged\n' >"$builds/$MAIN_OID/lastdbd"
printf '#!/bin/sh\necho lastdb staged\n' >"$builds/$MAIN_OID/lastdb"
printf '#!/bin/sh\necho restore probe staged\n' >"$builds/$MAIN_OID/lastdb_restore_probe"
chmod +x "$builds/$MAIN_OID/lastdbd" "$builds/$MAIN_OID/lastdb" "$builds/$MAIN_OID/lastdb_restore_probe"

# --- three binaries and no script is NOT a complete stage --------------------
# Stage 5af30c0a...-retry3.3VXp00 was exactly this shape and the resolver called
# it newest/complete, so the backup-restore-probe routine hand-pinned an OID
# instead (card lastdb-restore-probe-stage-script-missing-20260906).
set +e
out="$("$CLI" --json 2>/dev/null)"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "a stage without the probe script must need_build: $out"
[ "$(printf '%s\n' "$out" | jq -r .status)" = "need_build" ] || fail "no-script status: $out"

# --- a script that could not run the probe is not a script -------------------
mkdir -p "$builds/$MAIN_OID/scripts"
printf '#!/bin/sh\necho unrelated\n' >"$builds/$MAIN_OID/scripts/run-lastdb-restore-probe.sh"
chmod +x "$builds/$MAIN_OID/scripts/run-lastdb-restore-probe.sh"
set +e
out="$("$CLI" --json 2>/dev/null)"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "a script without --prove-corrupt-restore must need_build: $out"

# --- a caller that does not run the probe opts out explicitly ---------------
# last-stack-lastdb-dev wants a binary, not a probe. The opt-out is a visible
# flag so the strict default keeps holding for the restore probe itself.
out="$("$CLI" --json --allow-no-restore-script)"
[ "$(printf '%s\n' "$out" | jq -r .status)" = "ok" ] || fail "opt-out must resolve a script-less stage: $out"
[ "$(printf '%s\n' "$out" | jq -r .source)" = "canary-builds" ] || fail "opt-out source: $out"

write_probe_script "$builds/$MAIN_OID"

out="$("$CLI" --json)"
[ "$(printf '%s\n' "$out" | jq -r .status)" = "ok" ] || fail "exact stage: $out"
[ "$(printf '%s\n' "$out" | jq -r .source)" = "canary-builds" ] || fail "exact source: $out"
[ "$(printf '%s\n' "$out" | jq -r .lastdbd)" = "$builds/$MAIN_OID/lastdbd" ] || fail "exact lastdbd: $out"
[ "$(printf '%s\n' "$out" | jq -r .lastdb)" = "$builds/$MAIN_OID/lastdb" ] || fail "exact lastdb: $out"
[ "$(printf '%s\n' "$out" | jq -r .lastdb_restore_probe)" = "$builds/$MAIN_OID/lastdb_restore_probe" ] || fail "exact probe: $out"
[ "$(printf '%s\n' "$out" | jq -r .sha_drift)" = "false" ] || fail "exact drift: $out"
[ "$(printf '%s\n' "$out" | jq -r .restore_probe_script)" = "$builds/$MAIN_OID/scripts/run-lastdb-restore-probe.sh" ] \
  || fail "exact stage must publish the probe script path: $out"

# --- smoke-staged wins over canary-builds ---
printf '#!/bin/sh\necho lastdbd smoke\n' >"$staged/lastdbd-smoke-staged-$SHORT"
chmod +x "$staged/lastdbd-smoke-staged-$SHORT"
out="$("$CLI" --json)"
[ "$(printf '%s\n' "$out" | jq -r .source)" = "canary-builds" ] || fail "strict resolve accepted daemon-only smoke stage: $out"
out="$("$CLI" --json --allow-daemon-only)"
[ "$(printf '%s\n' "$out" | jq -r .source)" = "smoke-staged" ] || fail "smoke-staged win: $out"
[ "$(printf '%s\n' "$out" | jq -r .lastdbd)" = "$staged/lastdbd-smoke-staged-$SHORT" ] || fail "smoke path: $out"

# --- newest fallback when exact SHA missing ---
rm -f "$staged/lastdbd-smoke-staged-$SHORT"
rm -rf "$builds/$MAIN_OID"
other="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
mkdir -p "$builds/$other"
printf '#!/bin/sh\necho lastdbd old\n' >"$builds/$other/lastdbd"
chmod +x "$builds/$other/lastdbd"

set +e
out="$("$CLI" --json 2>/dev/null)"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "no-fallback should need_build: $out"

out="$("$CLI" --json --allow-newest --allow-daemon-only)"
[ "$(printf '%s\n' "$out" | jq -r .status)" = "ok" ] || fail "newest status: $out"
[ "$(printf '%s\n' "$out" | jq -r .source)" = "canary-builds-newest" ] || fail "newest source: $out"
[ "$(printf '%s\n' "$out" | jq -r .sha_drift)" = "true" ] || fail "newest drift: $out"
[ "$(printf '%s\n' "$out" | jq -r .lastdbd)" = "$builds/$other/lastdbd" ] || fail "newest path: $out"
[ "$(printf '%s\n' "$out" | jq -r .resolved_oid)" = "$other" ] || fail "newest resolved_oid: $out"

# --- resolved_oid stays a real OID when a suffixed copy is newest ---
# Other tooling copies a stage next to it as "<oid>-retryN.XXXXXX"; those
# copies win `ls -1t` and used to be published verbatim as resolved_oid
# (observed: 5af30c0a...-retry3.3VXp00 in the 2026-09-06 smoke outcome).
retry_copy="$builds/$other-retry3.3VXp00"
mkdir -p "$retry_copy"
printf '#!/bin/sh\necho lastdbd retry copy\n' >"$retry_copy/lastdbd"
chmod +x "$retry_copy/lastdbd"
touch "$retry_copy"

out="$("$CLI" --json --allow-newest --allow-daemon-only)"
[ "$(printf '%s\n' "$out" | jq -r .lastdbd)" = "$retry_copy/lastdbd" ] || fail "retry copy path: $out"
[ "$(printf '%s\n' "$out" | jq -r .resolved_oid)" = "$other" ] || fail "retry copy resolved_oid must be the bare OID: $out"

# --- a directory with no OID prefix is not a stage ---
rm -rf "$retry_copy" "$builds/$other"
junk="$builds/not-an-oid"
mkdir -p "$junk"
printf '#!/bin/sh\necho lastdbd junk\n' >"$junk/lastdbd"
chmod +x "$junk/lastdbd"

set +e
out="$("$CLI" --json --allow-newest --allow-daemon-only 2>/dev/null)"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "non-OID directory must not resolve as a stage: $out"
rm -rf "$junk"

mkdir -p "$builds/$other"
printf '#!/bin/sh\necho lastdbd old\n' >"$builds/$other/lastdbd"
chmod +x "$builds/$other/lastdbd"

# --- primary current last resort ---
rm -rf "$builds/$other"
printf '#!/bin/sh\necho lastdbd current\n' >"$current_dir/lastdbd"
chmod +x "$current_dir/lastdbd"

set +e
out="$("$CLI" --json --allow-newest 2>/dev/null)"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "newest-empty should need_build: $out"

out="$("$CLI" --json --allow-newest --allow-current --allow-daemon-only)"
[ "$(printf '%s\n' "$out" | jq -r .source)" = "primary-current" ] || fail "current source: $out"
[ "$(printf '%s\n' "$out" | jq -r .lastdbd)" = "$current_dir/lastdbd" ] || fail "current path: $out"
[ "$(printf '%s\n' "$out" | jq -r .sha_drift)" = "true" ] || fail "current drift: $out"

# --- backup restore contract requires all three current executables ---
set +e
out="$("$CLI" --json --allow-newest --allow-current 2>/dev/null)"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "incomplete current stage must need_build: $out"

printf '#!/bin/sh\necho lastdb current\n' >"$current_dir/lastdb"
printf '#!/bin/sh\necho restore probe current\n' >"$current_dir/lastdb_restore_probe"
chmod +x "$current_dir/lastdb" "$current_dir/lastdb_restore_probe"
out="$("$CLI" --json --allow-newest --allow-current)"
[ "$(printf '%s\n' "$out" | jq -r .source)" = "primary-current" ] || fail "complete current source: $out"
[ "$(printf '%s\n' "$out" | jq -r .lastdb_restore_probe)" = "$current_dir/lastdb_restore_probe" ] || fail "complete current probe: $out"
# The install tree is not a stage. It stays usable as the declared last resort,
# and it reports null so a caller that needs the source-bound pair can see that
# it did not get one.
[ "$(printf '%s\n' "$out" | jq -r .restore_probe_script)" = "null" ] \
  || fail "primary-current must report no stage-bound probe script: $out"

# --- a newest-fallback stage must carry the script too -----------------------
newest_oid="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
mkdir -p "$builds/$newest_oid"
for b in lastdbd lastdb lastdb_restore_probe; do
  printf '#!/bin/sh\necho %s newest\n' "$b" >"$builds/$newest_oid/$b"
  chmod +x "$builds/$newest_oid/$b"
done
set +e
out="$("$CLI" --json --allow-newest 2>/dev/null)"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "newest without the probe script must need_build: $out"

write_probe_script "$builds/$newest_oid"
out="$("$CLI" --json --allow-newest)"
[ "$(printf '%s\n' "$out" | jq -r .source)" = "canary-builds-newest" ] || fail "newest with script: $out"
[ "$(printf '%s\n' "$out" | jq -r .resolved_oid)" = "$newest_oid" ] || fail "newest resolved_oid: $out"
[ "$(printf '%s\n' "$out" | jq -r .restore_probe_script)" = "$builds/$newest_oid/scripts/run-lastdb-restore-probe.sh" ] \
  || fail "newest must publish the probe script path: $out"
rm -rf "$builds/$newest_oid"

# --- the dev node passes the opt-out, the restore probe never does ----------
grep -q -- '--allow-no-restore-script' "$ROOT/bin/last-stack-lastdb-dev" \
  || fail "last-stack-lastdb-dev must opt out explicitly, not resolve strictly by accident"

# --- never cargo: helper has no cargo invocation ---
if grep -n 'cargo ' "$CLI" | grep -v 'Never compiles' >/dev/null; then
  fail "resolver must not invoke cargo"
fi

echo "ok last-stack-canary-resolve-lastdbd"
