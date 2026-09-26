#!/usr/bin/env bash
# Hermetic fixtures for the jam backfill lane
# (decision-2026-09-26-portfolio-jam-backfill-third-lane).
# Cases: the pass record counts runnable milestones per admitted North Star;
# a Backfill is admitted after two jammed passes and not after one; it is
# cleared after two recovered passes; a second jam never opens a fourth slot;
# the admission gate answers rc=0 for the Backfill North Star; a human edit
# resets the trigger; each change posts a `situations notice --kind config`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
refill="$ROOT/bin/last-stack-portfolio-auto-refill"
record="$ROOT/bin/last-stack-portfolio-pass-record"
admission="$ROOT/bin/last-stack-feature-portfolio-admission"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

slug="preference-feature-delivery-portfolio-admission"
P=north-star-primary
S=north-star-secondary

# A situations CLI that logs its argv, one line per call.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/situations" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SITUATIONS_LOG"
SH
chmod +x "$tmp/bin/situations"
export SITUATIONS_LOG="$tmp/situations.log"
: >"$SITUATIONS_LOG"

base_record() {
  # base_record <dir> [updated_at] [updated_by] [extra lines after Secondary]
  mkdir -p "$1/get"
  cat >"$1/get/$slug.txt" <<REC
[preference] $slug
title:      Feature delivery portfolio admission
status:     active
tags:       feature-delivery, portfolio
---

# Feature delivery portfolio admission

Policy-Version: 5
Primary: $P
Secondary: $S
${4:-}
Paused: north-star-a, north-star-b, all-other-feature-north-stars
Updated-At: ${2:-2026-09-26T00:00:00Z}
Updated-By: ${3:-last-stack-north-star-driver}
Reason: initial.

## Contract

The North Star driver can create milestones only for the primary or secondary value.

The milestone driver can create Kind:pr cards only for the primary or secondary value.

## Auto-refill

Auto-refill prose that must survive every rewrite.
REC
}

pass_line() {
  # pass_line <ts> <updated_at> <primary_runnable> <secondary_runnable> [backfill] [backfill_runnable]
  local bf="${5:-}" bfr="${6:-0}" by
  by="{\"$P\":$3,\"$S\":$4}"
  [ -z "$bf" ] || by="{\"$P\":$3,\"$S\":$4,\"$bf\":$bfr}"
  jq -cn --arg ts "$1" --arg ua "$2" --arg bf "$bf" --argjson pr "$3" --argjson sr "$4" \
    --argjson bfr "$bfr" --argjson by "$by" --arg p "$P" --arg s "$S" '{
      ts:$ts, primary:$p, secondary:$s, backfill:$bf,
      primary_idle_promoteable:0, primary_idle_empty:1,
      secondary_idle_promoteable:0, secondary_idle_empty:1,
      primary_runnable:$pr, secondary_runnable:$sr, backfill_runnable:$bfr,
      runnable_by_admitted:$by,
      jam_reasons_by_admitted:{($p):["ms-stuck:idle_blocked","ms-proof:proof_pending"]},
      idle_by_north_star:{"north-star-a":0,"north-star-b":2,($p):1,($s):1},
      admission_updated_at:$ua, admission_updated_by:"last-stack-north-star-driver"}'
}

run_refill() {
  # run_refill <fixture-dir> <passes-file> [args...]
  local dir="$1" passes="$2"; shift 2
  "$refill" --fixture-dir "$dir" --passes-file "$passes" \
    --situations "$tmp/bin/situations" --json "$@"
}

# ------------------------------------------ pass record: runnable per admitted
rec_dir="$tmp/record"
base_record "$rec_dir" 2026-09-26T00:00:00Z last-stack-north-star-driver \
  "Backfill: north-star-b
Backfill-For: $P
Backfill-Since: 2026-09-26T00:00:00Z"
cat >"$tmp/gap.json" <<JSON
{"milestones":[
 {"slug":"p-stuck","north_star":"$P","status":"idle_blocked","action":"skip"},
 {"slug":"p-proof","north_star":"$P","status":"proof_pending","action":"await_proof"},
 {"slug":"p-done","north_star":"$P","status":"complete","action":"skip"},
 {"slug":"s-live","north_star":"$S","status":"in_flight","action":"skip"},
 {"slug":"s-promo","north_star":"$S","status":"idle_promoteable","action":"promote"},
 {"slug":"b-empty","north_star":"north-star-b","status":"idle_empty","action":"decompose"}
]}
JSON
"$record" --gap-report "$tmp/gap.json" --fixture-dir "$rec_dir" \
  --passes-file "$tmp/record.jsonl" --ts 2026-09-26T01:00:00Z --json >"$tmp/record.out"
jq -e --arg p "$P" --arg s "$S" '.recorded == true
  and .record.primary_runnable == 0 and .record.secondary_runnable == 2
  and .record.backfill == "north-star-b" and .record.backfill_runnable == 0
  and .record.backfill_for == $p
  and .record.runnable_by_admitted[$s] == 2
  and (.record.jam_reasons_by_admitted[$p] == ["p-proof:proof_pending","p-stuck:idle_blocked"])
  and .record.primary_idle_empty == 0 and .record.secondary_idle_promoteable == 1' \
  "$tmp/record.out" >/dev/null || fail "pass record runnable counts: $(cat "$tmp/record.out")"

# ------------------------------------------------ one jammed pass: no backfill
one="$tmp/one"
base_record "$one"
pass_line 2026-09-26T01:00:00Z 2026-09-26T00:00:00Z 0 3 >"$tmp/one.jsonl"
out="$(run_refill "$one" "$tmp/one.jsonl" --apply --now 2026-09-26T02:00:00Z)"
printf '%s' "$out" | jq -e '.verdict == "no-trigger-insufficient-passes"
  and .backfill_verdict == "no-backfill-change-insufficient-passes"' >/dev/null \
  || fail "one jammed pass must not backfill: $out"
grep -q '^Backfill' "$one/get/$slug.txt" && fail "one pass must write nothing"

# A recovered pass between two jammed ones resets the jam.
{ pass_line 2026-09-26T01:00:00Z 2026-09-26T00:00:00Z 0 3
  pass_line 2026-09-26T02:00:00Z 2026-09-26T00:00:00Z 1 3
} >"$tmp/one.jsonl"
out="$(run_refill "$one" "$tmp/one.jsonl")"
printf '%s' "$out" | jq -e '.backfill_verdict == "no-backfill-no-jam"' >/dev/null \
  || fail "a runnable newest pass is no jam: $out"

# ------------------------------------------ two jammed passes: admit backfill
two="$tmp/two"
base_record "$two"
{ pass_line 2026-09-26T01:00:00Z 2026-09-26T00:00:00Z 0 3
  pass_line 2026-09-26T02:00:00Z 2026-09-26T00:00:00Z 0 3
} >"$tmp/two.jsonl"
out="$(run_refill "$two" "$tmp/two.jsonl")"
printf '%s' "$out" | jq -e --arg p "$P" '.verdict == "would-backfill"
  and .new_backfill == "north-star-b" and .backfill_for == $p
  and (.jam_reasons | test("ms-stuck:idle_blocked"))' >/dev/null \
  || fail "two jammed passes must be a would-backfill dry run (north-star-a has no idle milestone): $out"
grep -q '^Backfill' "$two/get/$slug.txt" && fail "a dry run must write nothing"

out="$(run_refill "$two" "$tmp/two.jsonl" --apply --now 2026-09-26T03:00:00Z)"
printf '%s' "$out" | jq -e '.verdict == "backfilled" and .notice_posted == true' >/dev/null \
  || fail "apply must backfill: $out"
rec="$(cat "$two/get/$slug.txt")"
printf '%s\n' "$rec" | grep -q '^Policy-Version: 6$' || fail "policy version must bump: $rec"
printf '%s\n' "$rec" | grep -q '^Backfill: north-star-b$' || fail "Backfill line: $rec"
printf '%s\n' "$rec" | grep -q "^Backfill-For: $P\$" || fail "Backfill-For line: $rec"
printf '%s\n' "$rec" | grep -q '^Backfill-Since: 2026-09-26T03:00:00Z$' || fail "Backfill-Since line: $rec"
printf '%s\n' "$rec" | grep -q "^Primary: $P\$" || fail "Primary must not move: $rec"
printf '%s\n' "$rec" | grep -q "^Secondary: $S\$" || fail "Secondary must not move: $rec"
printf '%s\n' "$rec" | grep -q '^Updated-At: 2026-09-26T03:00:00Z$' || fail "Updated-At: $rec"
printf '%s\n' "$rec" | grep -q '^Updated-By: last-stack-north-star-driver$' || fail "Updated-By: $rec"
printf '%s\n' "$rec" | grep -q '^Reason: Jam backfill: .*ms-stuck:idle_blocked' || fail "Reason must name the jam: $rec"
printf '%s\n' "$rec" | grep -q '^## Jam backfill$' || fail "the tool rewrite must add the Jam backfill section: $rec"
printf '%s\n' "$rec" | grep -q 'primary, secondary, or backfill value' || fail "Contract prose: $rec"
printf '%s\n' "$rec" | grep -q 'Auto-refill prose that must survive every rewrite' || fail "prose lost: $rec"
[ "$(grep -c '^## Jam backfill$' "$two/get/$slug.txt")" = 1 ] || fail "one Jam backfill section"
grep -q -- '--kind config' "$SITUATIONS_LOG" || fail "notice must use --kind config: $(cat "$SITUATIONS_LOG")"
grep -q -- '--summary Jam backfill' "$SITUATIONS_LOG" || fail "notice must carry the reason as --summary"

# The admission gate admits the Backfill North Star (rc=0).
set +e
"$admission" --fixture-dir "$two" --north-star north-star-b --json >"$tmp/adm.json" 2>"$tmp/adm.err"
rc=$?
set -e
[ "$rc" = 0 ] || fail "admission must return rc=0 for Backfill, got $rc: $(cat "$tmp/adm.err")"
jq -e '.verdict == "admitted" and .backfill == "north-star-b"
  and (.admitted_outcomes | length) == 3 and (.reason | test("backfill"))' "$tmp/adm.json" >/dev/null \
  || fail "admission Backfill report: $(cat "$tmp/adm.json")"
set +e
"$admission" --fixture-dir "$two" --north-star north-star-a --json >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = 2 ] || fail "a paused North Star stays paused under a Backfill (rc=$rc)"

# The same pass pair does not fire again (Updated-At moved).
out="$(run_refill "$two" "$tmp/two.jsonl" --apply --now 2026-09-26T04:00:00Z)"
printf '%s' "$out" | jq -e '.verdict == "no-trigger-insufficient-passes"' >/dev/null \
  || fail "the same pass pair must not write twice: $out"

# ----------------------------------------------- never a fourth slot
# Backfill open for Primary; now Secondary also jams. Nothing opens.
UA=2026-09-26T03:00:00Z
{ pass_line 2026-09-26T05:00:00Z "$UA" 0 0 north-star-b 1
  pass_line 2026-09-26T06:00:00Z "$UA" 0 0 north-star-b 1
} >>"$tmp/two.jsonl"
before="$(cat "$two/get/$slug.txt")"
out="$(run_refill "$two" "$tmp/two.jsonl" --apply --now 2026-09-26T07:00:00Z)"
printf '%s' "$out" | jq -e '.backfill_verdict == "no-backfill-change-still-jammed"
  and .verdict != "backfilled"' >/dev/null \
  || fail "a second jam must not open a fourth slot: $out"
[ "$before" = "$(cat "$two/get/$slug.txt")" ] || fail "a still-jammed pass must write nothing"

# The gate refuses a record that names two Backfill lanes.
dup="$tmp/dup"
base_record "$dup" 2026-09-26T00:00:00Z owner "Backfill: north-star-a
Backfill: north-star-b"
set +e
"$admission" --fixture-dir "$dup" --north-star north-star-a --json >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = 1 ] || fail "two Backfill lines must be malformed (rc=$rc)"
same="$tmp/same"
base_record "$same" 2026-09-26T00:00:00Z owner "Backfill: $S"
set +e
"$admission" --fixture-dir "$same" --north-star "$S" --json >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = 1 ] || fail "a Backfill that repeats Secondary must be malformed (rc=$rc)"

# ------------------------------------------------- one recovered pass: hold
{ pass_line 2026-09-26T08:00:00Z "$UA" 0 2 north-star-b 1
  pass_line 2026-09-26T09:00:00Z "$UA" 2 2 north-star-b 1
} >>"$tmp/two.jsonl"
out="$(run_refill "$two" "$tmp/two.jsonl" --apply --now 2026-09-26T09:30:00Z)"
printf '%s' "$out" | jq -e '.backfill_verdict == "no-backfill-change-still-jammed"' >/dev/null \
  || fail "one recovered pass must not clear: $out"

# ------------------------------------------------ two recovered passes: clear
pass_line 2026-09-26T10:00:00Z "$UA" 1 2 north-star-b 1 >>"$tmp/two.jsonl"
: >"$SITUATIONS_LOG"
out="$(run_refill "$two" "$tmp/two.jsonl" --apply --now 2026-09-26T11:00:00Z)"
printf '%s' "$out" | jq -e '.verdict == "backfill-cleared" and .new_policy_version == 7' >/dev/null \
  || fail "two recovered passes must clear the backfill: $out"
rec="$(cat "$two/get/$slug.txt")"
printf '%s\n' "$rec" | grep -q '^Backfill' && fail "Backfill lines must be removed: $rec"
printf '%s\n' "$rec" | grep -q '^Policy-Version: 7$' || fail "clear must bump: $rec"
printf '%s\n' "$rec" | grep -q '^Reason: Jam backfill cleared: ' || fail "clear reason: $rec"
printf '%s\n' "$rec" | grep -q '^Paused: north-star-a, north-star-b, all-other-feature-north-stars$' \
  || fail "Paused ranking must be unchanged: $rec"
[ "$(grep -c '^## Jam backfill$' "$two/get/$slug.txt")" = 1 ] || fail "prose stays once after clear"
grep -q -- '--kind config' "$SITUATIONS_LOG" || fail "clear must post a config notice"
set +e
"$admission" --fixture-dir "$two" --north-star north-star-b --json >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = 2 ] || fail "a cleared Backfill files no new cards (rc=$rc)"

# ---------------------------------------------------- human edit resets
human="$tmp/human"
base_record "$human" 2026-09-26T12:00:00Z owner
{ pass_line 2026-09-26T10:00:00Z 2026-09-26T00:00:00Z 0 3
  pass_line 2026-09-26T11:00:00Z 2026-09-26T00:00:00Z 0 3
} >"$tmp/human.jsonl"
out="$(run_refill "$human" "$tmp/human.jsonl" --apply --now 2026-09-26T13:00:00Z)"
printf '%s' "$out" | jq -e '.matched_pass_count == 0 and .backfill_verdict == "no-backfill-change-insufficient-passes"' >/dev/null \
  || fail "a human edit must reset the jam trigger: $out"
grep -q '^Backfill' "$human/get/$slug.txt" && fail "a human edit reset must write nothing"
pass_line 2026-09-26T13:00:00Z 2026-09-26T12:00:00Z 0 3 >>"$tmp/human.jsonl"
out="$(run_refill "$human" "$tmp/human.jsonl")"
printf '%s' "$out" | jq -e '.matched_pass_count == 1 and .verdict != "would-backfill"' >/dev/null \
  || fail "one fresh pass after a human edit is not enough: $out"
pass_line 2026-09-26T14:00:00Z 2026-09-26T12:00:00Z 0 3 >>"$tmp/human.jsonl"
out="$(run_refill "$human" "$tmp/human.jsonl")"
printf '%s' "$out" | jq -e '.verdict == "would-backfill"' >/dev/null \
  || fail "two fresh jammed passes after a human edit fire again: $out"

# ------------------------------- refill still wins when both slots are drained
drain="$tmp/drain"
base_record "$drain"
{ pass_line 2026-09-26T01:00:00Z 2026-09-26T00:00:00Z 0 0
  pass_line 2026-09-26T02:00:00Z 2026-09-26T00:00:00Z 0 0
} | jq -c '.primary_idle_empty = 0 | .secondary_idle_empty = 0' >"$tmp/drain.jsonl"
out="$(run_refill "$drain" "$tmp/drain.jsonl")"
printf '%s' "$out" | jq -e '.verdict == "would-refill" and .candidate == "north-star-b"' >/dev/null \
  || fail "the Secondary refill runs first; backfill waits: $out"

# ----------------------------- an old pass without runnable counts never jams
old="$tmp/old"
base_record "$old"
{ pass_line 2026-09-26T01:00:00Z 2026-09-26T00:00:00Z 0 3
  pass_line 2026-09-26T02:00:00Z 2026-09-26T00:00:00Z 0 3
} | jq -c 'del(.primary_runnable, .secondary_runnable, .runnable_by_admitted, .backfill)' >"$tmp/old.jsonl"
out="$(run_refill "$old" "$tmp/old.jsonl")"
printf '%s' "$out" | jq -e '.backfill_verdict == "no-backfill-no-jam"' >/dev/null \
  || fail "a pass with no runnable count must not count as jammed: $out"

echo "ok last-stack-portfolio-jam-backfill"
