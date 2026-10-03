#!/usr/bin/env bash
# Class H: a green published artifact cannot reach this host because the registry
# proof frontier stopped advancing while apps merged past it.
#
# From 2026-10-01T22:10Z the six `next`-pinned apps shared one proof frontier and
# brain and routines had both merged past it. EdgeVector/routines PR 9 and PR 11 —
# both fixes to the only out-of-fleet fleet-freeze watchdog — could not install.
# `host-track` had computed every field needed to say so and was its own only
# reader, so the condition was found by hand, twice, by two papercut-resolver
# passes.
#
# The cases pin BOTH fields the verdict depends on, one at a time: a stale
# frontier with nothing waiting is not a stoppage, and an app waiting behind a
# FRESH frontier is an ordinary prover wait. Checking only one of them reports a
# healthy host as frozen or a frozen host as healthy.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="$ROOT/bin/last-stack-why-stopped"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

chmod +x "$bin"
bash -n "$bin"

mkdir -p "$tmp/bin"
hb="$tmp/heartbeats.log"
rows="$tmp/rows.json"

cat >"$tmp/bin/heal" <<'SH'
#!/usr/bin/env bash
printf 'LAST_STACK_CLASS_A_HEAL result=ok detail=already-healthy reason=why-stopped\n'
exit 0
SH

# Answers BOTH shapes `last-stack-why-stopped` asks for: the Class A probe calls
# `status --json last-stack` and wants ONE object; Class H calls `status --json`
# with no app and wants the whole array. A fake that serves only one of them
# makes the other class silent for the wrong reason.
cat >"$tmp/bin/host-track" <<'SH'
#!/usr/bin/env bash
want_app=""
for a in "$@"; do
  case "$a" in
    status|--json) ;;
    *) want_app="$a" ;;
  esac
done
if [ -n "$want_app" ]; then
  jq -n '{app:"last-stack",install_mode:"artifact",stale:false,freshness:"fresh",artifact_problem:null}'
else
  cat "$CLASS_H_ROWS"
fi
SH

cat >"$tmp/bin/kanban" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"ready":0,"counts":{},"cards":[]}'
SH
chmod +x "$tmp/bin/heal" "$tmp/bin/host-track" "$tmp/bin/kanban"

# A punctual routinesd dispatch, so Class G stays silent and only H is in play.
ts_now="$(python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"))')"
printf '%s last-stack-why-stopped ok harness=codex model=gpt-test exit=0 dur=1.0s run=/tmp/r\n' "$ts_now" > "$hb"

run_why() {
  CLASS_H_ROWS="$rows" \
  LASTSTACK_CLASS_A_HEAL_BIN="$tmp/bin/heal" \
  LASTSTACK_WHY_STOPPED_HOST_TRACK_BIN="$tmp/bin/host-track" \
  LASTSTACK_WHY_STOPPED_KANBAN_BIN="$tmp/bin/kanban" \
  LASTSTACK_WHY_STOPPED_NO_HEARTBEAT=1 \
  LAST_STACK_HEARTBEATS_PATH="$hb" \
    "$bin" --json --quiet
}
classes_of() { printf '%s\n' "$1" | awk '/^\{/{print; exit}' | jq -r '.classes'; }
has_class_h() {
  case "+$(classes_of "$1")+" in
    *+H+*) return 0 ;;
  esac
  return 1
}

# Case 1 — the measured incident, verbatim field values.
cat > "$rows" <<'JSON'
[
 {"app":"brain","registry_pin_state":"pinned","pin_behind_oid":"cbc3e5ae880c4fd4716f01f8d0956f67e1b10ce8","registry_pin_proof_age_secs":113122,"registry_pin_proof_run":"llms-smoke-20261001T221045Z"},
 {"app":"routines","registry_pin_state":"pinned","pin_behind_oid":"82f14a1ff2a5","registry_pin_proof_age_secs":113125,"registry_pin_proof_run":"llms-smoke-20261001T221045Z"},
 {"app":"situations","registry_pin_state":"pinned","pin_behind_oid":null,"registry_pin_proof_age_secs":113123,"registry_pin_proof_run":"llms-smoke-20261001T221045Z"},
 {"app":"last-stack","registry_pin_state":"not-on-index","pin_behind_oid":null}
]
JSON
out="$(run_why)"
has_class_h "$out" || fail "a 31h frontier with two apps merged past it must be Class H, got: $out"
printf '%s\n' "$out" | grep -q 'delivery frozen' \
  || fail "Class H must name the condition in detail, got: $out"
printf '%s\n' "$out" | grep -q 'no Class A' \
  && fail "Class H must replace the healthy wording, got: $out"

# The verdict must carry the INPUTS it used. Two passes that disagree about this
# host are indistinguishable when the row prints only a letter.
printf '%s\n' "$out" | grep -q 'brain' \
  || fail "Class H must name the blocked apps, got: $out"
printf '%s\n' "$out" | grep -q 'routines' \
  || fail "Class H must name every blocked app, not just the first, got: $out"
printf '%s\n' "$out" | grep -q '113122' \
  || fail "Class H must print the frontier age it judged, got: $out"
printf '%s\n' "$out" | grep -q 'llms-smoke-20261001T221045Z' \
  || fail "Class H must print the proof run that set the frontier, got: $out"

# An app that is current with the frontier is not blocked and must not be listed.
printf '%s\n' "$out" | grep -q 'situations' \
  && fail "an app with no pin_behind_oid is current and must not be listed, got: $out"

# Case 2 — PER-FIELD negative on the age. Same apps, same pin_behind_oid, a
# frontier 10 minutes old. This is the ordinary state minutes after any merge:
# the artifact is published and the next prover run will clear it. Firing here
# would make Class H permanent on a healthy fleet.
cat > "$rows" <<'JSON'
[
 {"app":"brain","registry_pin_state":"pinned","pin_behind_oid":"cbc3e5ae880c","registry_pin_proof_age_secs":600,"registry_pin_proof_run":"llms-smoke-fresh"},
 {"app":"routines","registry_pin_state":"pinned","pin_behind_oid":"82f14a1ff2a5","registry_pin_proof_age_secs":600,"registry_pin_proof_run":"llms-smoke-fresh"}
]
JSON
out="$(run_why)"
if has_class_h "$out"; then
  fail "a 10-minute-old frontier is an ordinary prover wait, not a freeze, got: $out"
fi

# Case 3 — PER-FIELD negative on pin_behind_oid. A frontier 31h stale and NOTHING
# merged past it: every pinned app is installed at the newest commit anyone
# proved, so shipping is not stopped. The frontier is worth fixing and is not
# this class.
cat > "$rows" <<'JSON'
[
 {"app":"situations","registry_pin_state":"pinned","pin_behind_oid":null,"registry_pin_proof_age_secs":113123,"registry_pin_proof_run":"llms-smoke-old"},
 {"app":"search","registry_pin_state":"pinned","pin_behind_oid":null,"registry_pin_proof_age_secs":113128,"registry_pin_proof_run":"llms-smoke-old"}
]
JSON
out="$(run_why)"
if has_class_h "$out"; then
  fail "a stale frontier with nothing waiting behind it is not a stoppage, got: $out"
fi

# Case 4 — `unreadable` is "I did not look", never "nothing to see". host-track
# splits it from `no-proved-row` for exactly this reason
# (papercut-host-track-reads-any-registry-resolve-failure-as-no-proved-row-20261002),
# and a classifier that treats an unread index as a measured freeze undoes that
# split. The row carries a pin_behind_oid and a long age to make the state the
# ONLY thing keeping it silent.
cat > "$rows" <<'JSON'
[
 {"app":"brain","registry_pin_state":"unreadable","pin_behind_oid":"cbc3e5ae880c","registry_pin_proof_age_secs":113122,"registry_pin_proof_run":"llms-smoke-old"}
]
JSON
out="$(run_why)"
if has_class_h "$out"; then
  fail "an unreadable registry index must not assert a delivery freeze, got: $out"
fi

# Case 5 — no proof row at all leaves the age absent. Absent is not old.
cat > "$rows" <<'JSON'
[
 {"app":"brain","registry_pin_state":"pinned","pin_behind_oid":"cbc3e5ae880c","registry_pin_proof_age_secs":null,"registry_pin_proof_run":null}
]
JSON
out="$(run_why)"
if has_class_h "$out"; then
  fail "an absent proof age must not assert a delivery freeze, got: $out"
fi

# Case 6 — an empty array is a host with no pinned apps, not a frozen one.
printf '%s\n' '[]' > "$rows"
out="$(run_why)"
if has_class_h "$out"; then
  fail "no pinned apps must not read as a delivery freeze, got: $out"
fi

# Case 7 — host-track printing nothing at all (not installed, or it failed) must
# stay silent for the same reason as Case 4.
: > "$rows"
out="$(run_why)"
if has_class_h "$out"; then
  fail "an empty host-track answer must not assert a delivery freeze, got: $out"
fi

printf 'ok last-stack-why-stopped-class-h-delivery-frozen\n'
