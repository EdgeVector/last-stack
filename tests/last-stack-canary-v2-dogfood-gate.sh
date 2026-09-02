#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
GATE="$ROOT/bin/last-stack-canary-v2-dogfood-gate"
PIPELINE="$ROOT/bin/last-stack-canary-pipeline"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-canary-v2-dogfood.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

dogfood="$tmp/dogfood"
calls="$tmp/calls"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\\n" "$*" >>"${DOGFOOD_CALLS:?}"' \
  'case " $* " in' \
  "  *\" --dry-run \"*) printf '%s\\n' '{\"version\":\"vnext\",\"state\":\"dogfood_green\"}' ;;" \
  "  *\" --cutover \"*) printf '%s\\n' '{\"safe_upgrade\":\"loom-cutover-green\",\"state\":\"dogfood_green\"}' ;;" \
  '  *) exit 2 ;;' \
  'esac' >"$dogfood"
chmod 755 "$dogfood"

run_gate() {
  DOGFOOD_CALLS="$calls" \
  LAST_STACK_CANARY_V2_DOGFOOD="$dogfood" \
  LAST_STACK_CANARY_V2_PIPELINE="$PIPELINE" \
  LAST_STACK_CANARY_V2_PRIMARY_IDENTITY_CMD="printf '%s\\n' 'pid=800 process_start_ts=1 build=vcurrent'" \
    "$GATE"
}

: >"$calls"
allow_out="$(run_gate)"
printf '%s\n' "$allow_out" | grep -q 'CANARY_V2_DOGFOOD result=ok candidate=vnext cutover=loom-cutover-green'
printf '%s\n' "$allow_out" | grep -q 'ROUTINE_RESULT outcome=ok detail=cutover=loom-cutover-green candidate=vnext'
test "$(wc -l <"$calls" | tr -d ' ')" -eq 2
grep -q -- '--cutover --json' "$calls"

# A current canary near the quiet-window end holds a normal newer cutover.
hold_dir="$tmp/hold"
"$PIPELINE" --state-dir "$hold_dir" record-boot --candidate vcurrent --pid 801 \
  --start-ts '2026-09-02T00:00:00Z' --build vcurrent >/dev/null
"$PIPELINE" --state-dir "$hold_dir" reconcile --candidate vcurrent \
  --window-seconds 86400 --at '2026-09-02T00:30:00Z' >/dev/null
: >"$calls"
hold_out="$(DOGFOOD_CALLS="$calls" \
  LAST_STACK_CANARY_PIPELINE_DIR="$hold_dir" \
  LAST_STACK_CANARY_V2_PRIMARY_IDENTITY_CMD="printf '%s\\n' 'pid=801 process_start_ts=1 build=vcurrent'" \
  LAST_STACK_CANARY_V2_AT='2026-09-02T00:30:00Z' \
  LAST_STACK_CANARY_V2_CUTOVER_HOLD_HOURS=24 \
  LAST_STACK_CANARY_V2_DOGFOOD="$dogfood" \
  LAST_STACK_CANARY_V2_PIPELINE="$PIPELINE" \
  "$GATE")"
printf '%s\n' "$hold_out" | grep -q 'result=noop candidate=vnext primary=vcurrent evidence=quiet_window_near_complete'
printf '%s\n' "$hold_out" | grep -q 'ROUTINE_RESULT outcome=noop detail=cutover_hold=quiet_window_near_complete'
test "$(wc -l <"$calls" | tr -d ' ')" -eq 1
grep -q -- '--dry-run --json' "$calls"

# An absent primary identity stops the line and writes durable observer evidence.
: >"$calls"
missing_out="$(DOGFOOD_CALLS="$calls" \
  LAST_STACK_CANARY_PIPELINE_DIR="$tmp/missing-identity" \
  LAST_STACK_CANARY_V2_DOGFOOD="$dogfood" \
  LAST_STACK_CANARY_V2_PIPELINE="$PIPELINE" \
  LAST_STACK_CANARY_V2_PRIMARY_IDENTITY_CMD='exit 9' \
  "$GATE")"
printf '%s\n' "$missing_out" | grep -q 'result=error subject=observer evidence=primary_identity_absent'
"$PIPELINE" --state-dir "$tmp/missing-identity" --json line-status \
  | jq -e '.state == "line-stopped" and .subject == "observer"' >/dev/null
test ! -s "$calls"

# A 404 boot-identity fallback is not a line-stop. Dry-run must not cut over.
: >"$calls"
fallback_dir="$tmp/status-fallback"
"$PIPELINE" --state-dir "$fallback_dir" record-boot --candidate vcurrent --pid 802 \
  --start-ts '2026-09-02T00:00:00Z' --build vcurrent >/dev/null
"$PIPELINE" --state-dir "$fallback_dir" reconcile --candidate vcurrent \
  --window-seconds 86400 --at '2026-09-02T00:30:00Z' >/dev/null
fallback_out="$(DOGFOOD_CALLS="$calls" \
  LAST_STACK_CANARY_PIPELINE_DIR="$fallback_dir" \
  LAST_STACK_CANARY_V2_DOGFOOD="$dogfood" \
  LAST_STACK_CANARY_V2_PIPELINE="$PIPELINE" \
  LAST_STACK_CANARY_V2_PRIMARY_IDENTITY_CMD="printf '%s\\n' 'pid=802 process_start_ts=1 build=vcurrent identity_source=status_fallback'" \
  LAST_STACK_CANARY_V2_AT='2026-09-02T00:30:00Z' \
  LAST_STACK_CANARY_V2_CUTOVER_HOLD_HOURS=24 \
  "$GATE")"
printf '%s\n' "$fallback_out" | grep -q 'primary_identity_absent' \
  && { echo '404 fallback must not line-stop as primary_identity_absent' >&2; exit 1; }
printf '%s\n' "$fallback_out" | grep -q 'result=noop candidate=vnext primary=vcurrent evidence=quiet_window_near_complete'
"$PIPELINE" --state-dir "$fallback_dir" --json line-status \
  | jq -e '.state == "clear"' >/dev/null
grep -q 'identity_source=status_fallback' "$fallback_dir/ledger.jsonl" \
  || { echo 'observer line missing identity_source=status_fallback' >&2; exit 1; }
test "$(wc -l <"$calls" | tr -d ' ')" -eq 1
grep -q -- '--dry-run --json' "$calls"
grep -q -- '--cutover' "$calls" && { echo 'dry-run 404 fallback started a cutover' >&2; exit 1; }

# Wire the real memory-guard: 404 + status token is not primary_identity_absent.
guard_home="$tmp/guard-home"
mkdir -p "$guard_home/.lastdb/data" "$tmp/guard-bin"
cat >"$tmp/guard-bin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-Ao pid=,comm=") printf '4242 /opt/lastdb/bin/lastdbd\n' ;;
  *"-o args="*) printf '/opt/lastdb/bin/lastdbd\n' ;;
  "eww -p "*) printf 'PID TTY TIME CMD LASTDB_HOME=%s\n' "${LASTDBD_PRIMARY_HOME}" ;;
  *) exit 0 ;;
esac
SH
cat >"$tmp/guard-bin/curl" <<'SH'
#!/usr/bin/env bash
want_code=0
for arg in "$@"; do
  case "$arg" in
    *%{http_code}*) want_code=1 ;;
  esac
done
emit() { printf '%s' "$1"; [ "$want_code" = 1 ] && printf '\n%s' "$2"; }
case "$*" in
  *"/api/system/boot-identity"*) emit "Not Found" "404"; exit 0 ;;
esac
emit '{"status":{"rss_bytes":1,"phys_footprint_bytes":1,"phys_footprint_peak_bytes":1,"process_start_ts":9,"build":{"version":"0.23.3-status"}}}' "200"
SH
chmod 755 "$tmp/guard-bin/"*
: >"$calls"
live_fallback_dir="$tmp/live-fallback"
"$PIPELINE" --state-dir "$live_fallback_dir" record-boot --candidate 0.23.3-status --pid 4242 \
  --start-ts '2026-09-02T00:00:00Z' --build 0.23.3-status >/dev/null
"$PIPELINE" --state-dir "$live_fallback_dir" reconcile --candidate 0.23.3-status \
  --window-seconds 86400 --at '2026-09-02T00:30:00Z' >/dev/null
live_fallback_out="$(
  PATH="$tmp/guard-bin:/usr/bin:/bin" \
  HOME="$guard_home" \
  LASTDBD_PRIMARY_HOME="$guard_home/.lastdb" \
  LASTDBD_GUARD_PATH="$tmp/guard-bin:/usr/bin:/bin" \
  DOGFOOD_CALLS="$calls" \
  LAST_STACK_CANARY_PIPELINE_DIR="$live_fallback_dir" \
  LAST_STACK_CANARY_V2_DOGFOOD="$dogfood" \
  LAST_STACK_CANARY_V2_PIPELINE="$PIPELINE" \
  LAST_STACK_CANARY_V2_PRIMARY_IDENTITY_CMD="$ROOT/bin/last-stack-lastdb-memory-guard --identity" \
  LAST_STACK_CANARY_V2_AT='2026-09-02T00:30:00Z' \
  LAST_STACK_CANARY_V2_CUTOVER_HOLD_HOURS=24 \
  "$GATE")"
printf '%s\n' "$live_fallback_out" | grep -q 'primary_identity_absent' \
  && { echo "real guard 404 fallback line-stopped: $live_fallback_out" >&2; exit 1; }
printf '%s\n' "$live_fallback_out" | grep -q 'primary=0.23.3-status'
"$PIPELINE" --state-dir "$live_fallback_dir" --json line-status \
  | jq -e '.state == "clear"' >/dev/null
grep -q 'identity_source=status_fallback' "$live_fallback_dir/ledger.jsonl" \
  || { echo 'live observer line missing identity_source=status_fallback' >&2; exit 1; }
test "$(wc -l <"$calls" | tr -d ' ')" -eq 1
grep -q -- '--dry-run --json' "$calls"
grep -q -- '--cutover' "$calls" && { echo 'real-guard dry-run started a cutover' >&2; exit 1; }

# Negative: down socket still line-stops.
: >"$calls"
down_out="$(
  PATH="$tmp/guard-bin:/usr/bin:/bin" \
  HOME="$guard_home" \
  LASTDBD_PRIMARY_HOME="$guard_home/.lastdb" \
  LASTDBD_GUARD_PATH="$tmp/guard-bin:/usr/bin:/bin" \
  DOGFOOD_CALLS="$calls" \
  LAST_STACK_CANARY_PIPELINE_DIR="$tmp/down-socket" \
  LAST_STACK_CANARY_V2_DOGFOOD="$dogfood" \
  LAST_STACK_CANARY_V2_PIPELINE="$PIPELINE" \
  LAST_STACK_CANARY_V2_PRIMARY_IDENTITY_CMD='exit 7' \
  "$GATE")"
printf '%s\n' "$down_out" | grep -q 'result=error subject=observer evidence=primary_identity_absent'
test ! -s "$calls"

if rg -n 'lastdb-canary-release|SOAK_WAIT|last-stack-canary-loom' "$GATE"; then
  echo 'the v2 dogfood gate starts the retired release graph' >&2
  exit 1
fi
grep -q 'last-stack-canary-v2-dogfood-gate' "$ROOT/config/routines-registry/lastdb-canary-dogfood.toml"
grep -q 'status = "paused"' "$ROOT/config/routines-registry/lastdb-canary-promote-prepare.toml"

echo "ok last-stack-canary-v2-dogfood-gate"
