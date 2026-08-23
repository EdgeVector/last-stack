#!/usr/bin/env bash
# Tests for last-stack-lastdb-ops-offenders.
#
# Load-bearing: a dump we cannot rank must exit 2, never "clean".
# Long-poll wait and cheap high-count queries must be SKIP, not findings.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-lastdb-ops-offenders"
FIX="$ROOT/tests/fixtures/lastdb-ops-offenders"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-lastdb-ops-offenders.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -x "$BIN" ] || chmod +x "$BIN"

# --- malformed: no top_by_total_ms → UNKNOWN, not clean ----------------------
set +e
out="$("$BIN" --ops-file "$FIX/malformed.json" --no-snapshot --json 2>"$tmp/malformed.err")"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "malformed should exit 2, got $rc ($out)"
grep -qi 'UNKNOWN\|could not rank\|missing\|empty' "$tmp/malformed.err" \
  || fail "malformed stderr should explain UNKNOWN: $(cat "$tmp/malformed.err")"

# --- fixture ranks BoardCards mutation; skips long-poll + cheap lastgit ------
out="$("$BIN" --ops-file "$FIX/status.json" --snapshot-dir "$tmp/snap" --json)"
echo "$out" | python3 -c '
import json,sys
d=json.load(sys.stdin)
offs=d.get("offenders") or []
skips=d.get("skipped") or []
clients_kinds=[(r["client"], r["kind"]) for r in offs]
skip_reasons={(r["client"], r["kind"]): r.get("skip_reason") for r in skips}
if ("kanban","mutation") not in clients_kinds:
    raise SystemExit("expected kanban mutation as an offender")
if ("kanban","query") not in clients_kinds:
    raise SystemExit("expected kanban query as an offender")
if ("lastgit","local_watch") in clients_kinds:
    raise SystemExit("long-poll lastgit local_watch must not be an offender")
if skip_reasons.get(("lastgit","local_watch")) != "long_poll":
    raise SystemExit("lastgit local_watch should skip as long_poll")
if skip_reasons.get(("lastgit","query")) != "cheap_count":
    raise SystemExit("lastgit query should skip as cheap_count")
if skip_reasons.get(("brain","query")) not in {"cheap_count","tiny"}:
    raise SystemExit("brain query should skip as cheap_count/tiny")
n = d.get("offender_count")
if n != 2:
    raise SystemExit("expected 2 offenders, got %s" % n)
'
test -f "$tmp/snap/latest.json" || fail "snapshot latest.json missing"

# text mode mentions the mutation and forbids restart
txt="$("$BIN" --ops-file "$FIX/status.json" --no-snapshot 2>&1)"
case "$txt" in
  *kanban*mutation*) : ;;
  *) fail "text mode should name kanban mutation: $txt" ;;
esac
case "$txt" in
  *"Do NOT restart"*) : ;;
  *) fail "text mode must say not to restart primary" ;;
esac

echo "ok last-stack-lastdb-ops-offenders"
