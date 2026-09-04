#!/usr/bin/env bash
# Hermetic fixtures for last-stack-portfolio-pass-record.
# Cases: a normal pass appends one JSONL line with correct per-NS idle
# counts; an unreadable admission record soft-skips without failing; a
# missing/garbage gap-report soft-skips too (never breaks milestone-driver).
# decision-2026-09-03-portfolio-auto-refill-from-ranking
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="$ROOT/bin/last-stack-portfolio-pass-record"
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

live="$tmp/live"
write_admission "$live" <<'REC'
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

gap="$tmp/gap-report.json"
cat >"$gap" <<'JSON'
{
  "milestones": [
    {"slug": "ms-a", "north_star": "north-star-feature-delivery-effective-flow", "action": "promote"},
    {"slug": "ms-b", "north_star": "north-star-feature-delivery-effective-flow", "action": "decompose"},
    {"slug": "ms-c", "north_star": "north-star-lastdb-no-scan-access", "action": "skip"},
    {"slug": "ms-d", "north_star": "north-star-other", "action": "decompose"}
  ]
}
JSON

passes="$tmp/passes.jsonl"

out="$("$bin" --gap-report "$gap" --fixture-dir "$live" --passes-file "$passes" --ts 2026-09-03T18:00:00Z --json)"
printf '%s' "$out" | jq -e '.recorded == true' >/dev/null || fail "expected a recorded pass: $out"

[ -f "$passes" ] || fail "pass-history file was not created"
[ "$(wc -l <"$passes" | tr -d ' ')" = "1" ] || fail "expected exactly one line: $(cat "$passes")"

line="$(cat "$passes")"
printf '%s' "$line" | jq -e '
  .primary == "north-star-feature-delivery-effective-flow"
  and .secondary == "north-star-lastdb-no-scan-access"
  and .primary_idle_promoteable == 1
  and .primary_idle_empty == 1
  and .secondary_idle_promoteable == 0
  and .secondary_idle_empty == 0
  and .admission_updated_at == "2026-09-01T00:00:00Z"
  and .admission_updated_by == "owner"
  and .ts == "2026-09-03T18:00:00Z"
' >/dev/null || fail "unexpected pass record: $line"

# A second pass appends, never overwrites.
"$bin" --gap-report "$gap" --fixture-dir "$live" --passes-file "$passes" --ts 2026-09-03T19:00:00Z >/dev/null
[ "$(wc -l <"$passes" | tr -d ' ')" = "2" ] || fail "expected two appended lines: $(cat "$passes")"

# ----------------------------------------------------------- soft-skip cases
missing="$tmp/missing"
mkdir -p "$missing/get"
out="$("$bin" --gap-report "$gap" --fixture-dir "$missing" --passes-file "$tmp/skip-passes.jsonl" --json)"
printf '%s' "$out" | jq -e '.recorded == false' >/dev/null \
  || fail "unreadable admission record must soft-skip, not fail: $out"
[ -f "$tmp/skip-passes.jsonl" ] && fail "soft-skip must not create a passes file"

rc=0
"$bin" --gap-report "$tmp/no-such-file.json" --fixture-dir "$live" --passes-file "$tmp/skip-passes2.jsonl" --json >/dev/null || rc=$?
[ "$rc" -eq 0 ] || fail "a missing gap-report must exit 0 (soft-skip), got rc=$rc"

printf 'ok last-stack-portfolio-pass-record\n'
