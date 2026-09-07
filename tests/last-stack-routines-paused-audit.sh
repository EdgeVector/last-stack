#!/usr/bin/env bash
# A paused routine must say who owns the pause.
#
# The fleet view reports `lastOutcome: noop` for a paused routine and for an
# idle one. On 2026-09-07 that hid two facts for two days: the canary promote
# pair was paused for a migration that finished on 2026-09-05, and
# lastdb-canary-soak-watch was paused only in the LIVE registry while the
# shipped source said active.
#
# The metadata cannot be a TOML key. `routines list --json` answers
# `unknown key "paused_reason"` and drops the whole entry, so the auditor reads
# structured comments the registry parser ignores.
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-routines-paused-audit"
fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-paused-audit.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
live="$tmp/registry"
src="$tmp/source"
mkdir -p "$live" "$src"

write_entry() {  # dir id status [extra comment lines...]
  local dir="$1" id="$2" status="$3"; shift 3
  {
    for line in "$@"; do printf '%s\n' "$line"; done
    printf 'id = "%s"\n' "$id"
    printf 'status = "%s"\n' "$status"
    printf 'rrule = "FREQ=HOURLY;INTERVAL=1"\n'
  } >"$dir/$id.toml"
}

run_audit() {  # -> stdout; sets AUDIT_RC
  set +e
  AUDIT_OUT="$("$BIN" --registry-dir "$live" --source-dir "$src" --at "$1" 2>&1)"
  AUDIT_RC=$?
  set -e
  printf '%s\n' "$AUDIT_OUT"
}

verdict_for() {  # id -> verdict word
  printf '%s\n' "$AUDIT_OUT" | awk -v id="id=$1" '$0 ~ id {print $2; exit}'
}

# --- 1) No paused routine: exit 0 and say so ---
write_entry "$live" alpha active
run_audit 2026-09-07T16:00:00Z >/dev/null
[ "$AUDIT_RC" -eq 0 ] || fail "clean registry must exit 0 (got $AUDIT_RC)"
printf '%s\n' "$AUDIT_OUT" | grep -q 'paused=0' || fail "clean registry must report paused=0"

# --- 2) Paused with no metadata is `silent` and fails ---
write_entry "$live" beta paused
run_audit 2026-09-07T16:00:00Z >/dev/null
[ "$(verdict_for beta)" = "silent" ] || fail "bare pause must be silent (got '$(verdict_for beta)')"
[ "$AUDIT_RC" -eq 1 ] || fail "a silent pause must exit 1 (got $AUDIT_RC)"

# --- 3) Reason + unexpired expiry is `owned` ---
write_entry "$live" gamma paused \
  '# PAUSED-REASON: waiting on the forge runner rebuild' \
  '# PAUSED-UNTIL: 2026-12-01T00:00:00Z'
run_audit 2026-09-07T16:00:00Z >/dev/null
[ "$(verdict_for gamma)" = "owned" ] || fail "reason+future expiry must be owned (got '$(verdict_for gamma)')"

# --- 4) The same expiry in the past is `expired` ---
run_audit 2027-01-01T00:00:00Z >/dev/null
[ "$(verdict_for gamma)" = "expired" ] || fail "past expiry must be expired (got '$(verdict_for gamma)')"
[ "$AUDIT_RC" -eq 1 ] || fail "an expired pause must exit 1"

# --- 5) Reason + owning card is `owned` ---
write_entry "$live" delta paused \
  '# PAUSED-REASON: held until the canary channel proof lands' \
  '# PAUSED-UNTIL: card' \
  '# PAUSED-CARD: some-owning-card-20260907'
run_audit 2026-09-07T16:00:00Z >/dev/null
[ "$(verdict_for delta)" = "owned" ] || fail "reason+card must be owned (got '$(verdict_for delta)')"

# --- 6) `never` is a permanent hold by design, but still needs a reason ---
write_entry "$live" epsilon paused \
  '# PAUSED-REASON: a launchd healer already covers this' \
  '# PAUSED-UNTIL: never'
write_entry "$live" zeta paused '# PAUSED-UNTIL: never'
run_audit 2026-09-07T16:00:00Z >/dev/null
[ "$(verdict_for epsilon)" = "owned" ] || fail "reason+never must be owned (got '$(verdict_for epsilon)')"
[ "$(verdict_for zeta)" = "silent" ] || fail "never without a reason must be silent (got '$(verdict_for zeta)')"

# --- 7) Live paused while the shipped source says active is `drift` ---
# This is the lastdb-canary-soak-watch shape: the pause exists only on the host,
# so no reviewed file records it and no reader can find out why.
write_entry "$live" eta paused
write_entry "$src"  eta active
run_audit 2026-09-07T16:00:00Z >/dev/null
[ "$(verdict_for eta)" = "drift" ] || fail "live-paused vs source-active must be drift (got '$(verdict_for eta)')"
printf '%s\n' "$AUDIT_OUT" | grep -q 'source=active' || fail "drift line must name the source status"

# A documented local pause is not drift — it is judged on its own metadata.
write_entry "$live" theta paused \
  '# PAUSED-REASON: parked on this host while the runner is down' \
  '# PAUSED-UNTIL: 2026-12-01T00:00:00Z'
write_entry "$src"  theta active
run_audit 2026-09-07T16:00:00Z >/dev/null
[ "$(verdict_for theta)" = "owned" ] || fail "documented local pause must be owned (got '$(verdict_for theta)')"

# --- 8) A malformed expiry must not read as owned ---
write_entry "$live" iota paused \
  '# PAUSED-REASON: something' \
  '# PAUSED-UNTIL: soon'
run_audit 2026-09-07T16:00:00Z >/dev/null
[ "$(verdict_for iota)" = "silent" ] || fail "malformed expiry must be silent (got '$(verdict_for iota)')"

# --- 9) JSON mode is parseable and agrees with the text mode ---
set +e
json_out="$("$BIN" --registry-dir "$live" --source-dir "$src" --at 2026-09-07T16:00:00Z --json)"
json_rc=$?
set -e
[ "$json_rc" -eq 1 ] || fail "json mode must keep the same exit status (got $json_rc)"
printf '%s' "$json_out" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["kind"]=="routines-paused-audit" and d["paused"]>0 and d["unowned"]>0 else 1)' \
  || fail "json mode did not produce the expected document"

# --- 10) The shipped registry source carries no undocumented pause ---
# Every paused entry this repo SHIPS must name a reason. A host-local pause is
# out of scope here; this guards the reviewed files.
for entry in "$ROOT"/config/routines-registry/*.toml; do
  [ -f "$entry" ] || continue
  grep -q '^status = "paused"' "$entry" || continue
  grep -qi '^# PAUSED-REASON:' "$entry" \
    || fail "$(basename "$entry") ships status=paused with no '# PAUSED-REASON:' line"
done

echo "PASS last-stack-routines-paused-audit"
