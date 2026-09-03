#!/usr/bin/env bash
# Hermetic fixtures for last-stack-portfolio-auto-refill.
# Cases: fires only after two matching drained passes (not one); a second
# apply against the same pass pair does not double-bump; a Tom edit between
# passes resets the trigger counter; a drained portfolio with no paused
# candidate reports no-candidate and writes nothing.
# decision-2026-09-03-portfolio-auto-refill-from-ranking
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="$ROOT/bin/last-stack-portfolio-auto-refill"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ -x "$bin" ] || chmod +x "$bin"
slug="preference-feature-delivery-portfolio-admission"

write_admission() {
  local dir="$1"
  mkdir -p "$dir/get"
  cat >"$dir/get/$slug.txt"
}

base_record() {
  cat <<REC
[preference] preference-feature-delivery-portfolio-admission
title:      Feature delivery portfolio admission
status:     active
tags:       feature-delivery, portfolio, admission, north-star
---

# Feature delivery portfolio admission

Policy-Version: ${1:-1}
Primary: north-star-feature-delivery-effective-flow
Secondary: north-star-lastdb-no-scan-access
Paused: north-star-a, north-star-b, all-other-feature-north-stars
Updated-At: ${2:-2026-09-01T00:00:00Z}
Updated-By: ${3:-owner}
Reason: ${4:-initial}.

## Contract

Contract text that must survive every rewrite.
REC
}

drained_pass() {
  # drained_pass <ts> <updated_at> [secondary=north-star-lastdb-no-scan-access]
  printf '{"ts":"%s","primary":"north-star-feature-delivery-effective-flow","secondary":"%s","primary_idle_promoteable":0,"primary_idle_empty":0,"secondary_idle_promoteable":0,"secondary_idle_empty":0,"admission_updated_at":"%s","admission_updated_by":"owner"}\n' \
    "$1" "${3:-north-star-lastdb-no-scan-access}" "$2"
}

busy_pass() {
  # busy_pass <ts> <updated_at> — has real work, must not count as drained
  printf '{"ts":"%s","primary":"north-star-feature-delivery-effective-flow","secondary":"north-star-lastdb-no-scan-access","primary_idle_promoteable":0,"primary_idle_empty":2,"secondary_idle_promoteable":0,"secondary_idle_empty":0,"admission_updated_at":"%s","admission_updated_by":"owner"}\n' "$1" "$2"
}

# --------------------------------------------------- one pass is not enough
live="$tmp/one-pass"
write_admission "$live" < <(base_record)
passes="$tmp/one-pass.jsonl"
drained_pass 2026-09-03T18:00:00Z 2026-09-01T00:00:00Z >"$passes"

out="$("$bin" --fixture-dir "$live" --passes-file "$passes" --json)"
printf '%s' "$out" | jq -e '.verdict == "no-trigger-insufficient-passes" and .refilled == false' >/dev/null \
  || fail "one drained pass must not trigger: $out"

# A pass with real work in between resets the matching tail.
{ drained_pass 2026-09-03T17:00:00Z 2026-09-01T00:00:00Z
  busy_pass 2026-09-03T18:00:00Z 2026-09-01T00:00:00Z
} >"$passes"
out="$("$bin" --fixture-dir "$live" --passes-file "$passes" --json)"
printf '%s' "$out" | jq -e '.verdict == "no-trigger-supply-not-drained"' >/dev/null \
  || fail "a busy most-recent pass must block the trigger: $out"

# ------------------------------------------------- two matching passes fire
live2="$tmp/two-pass"
write_admission "$live2" < <(base_record)
passes2="$tmp/two-pass.jsonl"
{ drained_pass 2026-09-03T18:00:00Z 2026-09-01T00:00:00Z
  drained_pass 2026-09-03T19:00:00Z 2026-09-01T00:00:00Z
} >"$passes2"

out="$("$bin" --fixture-dir "$live2" --passes-file "$passes2" --json)"
printf '%s' "$out" | jq -e '.verdict == "would-refill" and .candidate == "north-star-a" and .refilled == false' >/dev/null \
  || fail "two drained passes should be a would-refill dry run: $out"

out="$("$bin" --fixture-dir "$live2" --passes-file "$passes2" --apply --now 2026-09-03T20:00:00Z --situations "$tmp/no-such-situations-bin" --json)"
printf '%s' "$out" | jq -e '.verdict == "refilled" and .candidate == "north-star-a" and .refilled == true' >/dev/null \
  || fail "apply with two drained passes must refill: $out"

new_rec="$(cat "$live2/get/$slug.txt")"
printf '%s' "$new_rec" | grep -q '^Policy-Version: 2$' || fail "policy version must bump to 2: $new_rec"
printf '%s' "$new_rec" | grep -q '^Secondary: north-star-a$' || fail "secondary must become the candidate: $new_rec"
printf '%s' "$new_rec" | grep -q '^Primary: north-star-feature-delivery-effective-flow$' \
  || fail "primary must never move: $new_rec"
printf '%s' "$new_rec" | grep -q '^Paused: north-star-lastdb-no-scan-access, north-star-b, all-other-feature-north-stars$' \
  || fail "displaced secondary must land back in Paused: $new_rec"
printf '%s' "$new_rec" | grep -q '^Updated-By: last-stack-north-star-driver$' \
  || fail "updated-by must name the driver: $new_rec"
printf '%s' "$new_rec" | grep -q 'Contract text that must survive every rewrite' \
  || fail "unrelated body prose must survive the field rewrite: $new_rec"

# ------------------------------------------------- no double bump (idempotent)
out="$("$bin" --fixture-dir "$live2" --passes-file "$passes2" --apply --now 2026-09-03T21:00:00Z --situations "$tmp/no-such-situations-bin" --json)"
printf '%s' "$out" | jq -e '.verdict == "no-trigger-insufficient-passes" and .refilled == false' >/dev/null \
  || fail "the same pass pair must not refill twice: $out"
still="$(cat "$live2/get/$slug.txt")"
printf '%s' "$still" | grep -q '^Policy-Version: 2$' || fail "policy version must not bump again: $still"

# Two fresh passes under the new (post-refill) config can fire again later.
{ drained_pass 2026-09-03T21:00:00Z 2026-09-03T20:00:00Z north-star-a
  drained_pass 2026-09-03T22:00:00Z 2026-09-03T20:00:00Z north-star-a
} >>"$passes2"
out="$("$bin" --fixture-dir "$live2" --passes-file "$passes2" --apply --now 2026-09-03T23:00:00Z --situations "$tmp/no-such-situations-bin" --json)"
# The first refill displaced north-star-lastdb-no-scan-access back into Paused
# ahead of north-star-b, so it is next in ranking order.
printf '%s' "$out" | jq -e '.verdict == "refilled" and .candidate == "north-star-lastdb-no-scan-access"' >/dev/null \
  || fail "a second genuine drained pair (post-refill) must refill again with the next-ranked candidate: $out"

# ------------------------------------------------------------ Tom edit wins
live3="$tmp/tom-edit"
write_admission "$live3" < <(base_record 1 2026-09-01T00:00:00Z owner initial)
passes3="$tmp/tom-edit.jsonl"
drained_pass 2026-09-03T10:00:00Z 2026-09-01T00:00:00Z >"$passes3"
# Tom edits the record (vetoes / acknowledges) without changing Primary/Secondary —
# only Updated-At moves. This must invalidate the one drained pass recorded
# before the edit.
write_admission "$live3" < <(base_record 1 2026-09-03T12:00:00Z owner "Tom reviewed, no change")
drained_pass 2026-09-03T13:00:00Z 2026-09-03T12:00:00Z >>"$passes3"

out="$("$bin" --fixture-dir "$live3" --passes-file "$passes3" --json)"
printf '%s' "$out" | jq -e '.verdict == "no-trigger-insufficient-passes" and .matched_pass_count == 1' >/dev/null \
  || fail "a Tom edit must reset the trigger counter to the passes recorded after it: $out"

# Two more passes recorded after the edit complete the trigger.
drained_pass 2026-09-03T14:00:00Z 2026-09-03T12:00:00Z >>"$passes3"
out="$("$bin" --fixture-dir "$live3" --passes-file "$passes3" --json)"
printf '%s' "$out" | jq -e '.verdict == "would-refill" and .matched_pass_count == 2' >/dev/null \
  || fail "two passes recorded after the Tom edit must be enough to trigger: $out"

# ------------------------------------------------------------- no candidate
live4="$tmp/no-candidate"
write_admission "$live4" <<'REC'
[preference] preference-feature-delivery-portfolio-admission
title:      Feature delivery portfolio admission
---
# Feature delivery portfolio admission

Policy-Version: 1
Primary: north-star-feature-delivery-effective-flow
Secondary: north-star-lastdb-no-scan-access
Paused: all-other-feature-north-stars
Updated-At: 2026-09-01T00:00:00Z
Updated-By: owner
Reason: initial.
REC
passes4="$tmp/no-candidate.jsonl"
{ drained_pass 2026-09-03T18:00:00Z 2026-09-01T00:00:00Z
  drained_pass 2026-09-03T19:00:00Z 2026-09-01T00:00:00Z
} >"$passes4"

# A fake situations binary that records whether it was ever invoked.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/situations" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${NOTICE_LOG:-/dev/null}"
exit 0
SH
chmod +x "$tmp/bin/situations"
export NOTICE_LOG="$tmp/notice.log"
: >"$NOTICE_LOG"

rc=0
out="$("$bin" --fixture-dir "$live4" --passes-file "$passes4" --apply --situations "$tmp/bin/situations" --json)" || rc=$?
[ "$rc" -eq 0 ] || fail "no-candidate must exit 0 (nothing to write), got rc=$rc: $out"
printf '%s' "$out" | jq -e '.verdict == "no-candidate" and .refilled == false' >/dev/null \
  || fail "an exhausted Paused list must report no-candidate: $out"
[ -s "$NOTICE_LOG" ] && fail "no-candidate must not post a Situations notice: $(cat "$NOTICE_LOG")"
unchanged="$(cat "$live4/get/$slug.txt")"
printf '%s' "$unchanged" | grep -q '^Policy-Version: 1$' \
  || fail "no-candidate must leave the admission record untouched: $unchanged"

# ------------------------------------------------- notice fires on a real refill
live5="$tmp/notice-fires"
write_admission "$live5" < <(base_record)
passes5="$tmp/notice-fires.jsonl"
{ drained_pass 2026-09-03T18:00:00Z 2026-09-01T00:00:00Z
  drained_pass 2026-09-03T19:00:00Z 2026-09-01T00:00:00Z
} >"$passes5"
: >"$NOTICE_LOG"
out="$("$bin" --fixture-dir "$live5" --passes-file "$passes5" --apply --situations "$tmp/bin/situations" --json)"
printf '%s' "$out" | jq -e '.refilled == true and .notice_posted == true' >/dev/null \
  || fail "a real refill must post a notice: $out"
grep -q 'notice --title' "$NOTICE_LOG" || fail "situations notice was not invoked: $(cat "$NOTICE_LOG")"
grep -q 'north-star-a' "$NOTICE_LOG" || fail "notice must name the admitted North Star: $(cat "$NOTICE_LOG")"

# ----------------------------------------------------- admission fail-closed
missing="$tmp/missing-admission"
mkdir -p "$missing/get"
rc=0
"$bin" --fixture-dir "$missing" --passes-file "$tmp/whatever.jsonl" --json >/dev/null 2>"$tmp/stderr.txt" || rc=$?
[ "$rc" -eq 1 ] || fail "an unreadable admission record must fail closed, got rc=$rc"

# --------------------------------------------------------- wiring is real
grep -q 'last-stack-portfolio-auto-refill' "$ROOT/routines/north-star-driver.md" \
  || fail "north-star-driver does not run the auto-refill trigger"
grep -q 'last-stack-portfolio-pass-record' "$ROOT/routines/milestone-driver.md" \
  || fail "milestone-driver does not record portfolio passes"

printf 'ok last-stack-portfolio-auto-refill\n'
