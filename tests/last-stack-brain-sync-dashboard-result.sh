#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-brain-sync-dashboard-result"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/brain-sync-dashboard-result.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

cat >"$WORK/previous.html" <<'HTML'
<!doctype html>
<title>North Star dashboard</title>
<p>Generated <code>2026-07-23T23:05Z</code>.</p>
HTML

cat >"$WORK/socket.err" <<'ERR'
ERROR=command failed (1): brain list --type project --json --limit 200
error: node socket not reachable at unix:/Users/tomtang/.lastdb/data/folddb.sock
hint: A Unix socket file exists but it did not accept a connection.
ERR

result="$("$BIN" --mode rollup --rc 1 --stderr-file "$WORK/socket.err" --previous-html "$WORK/previous.html" --brain-record-missing)"
case "$result" in
  outcome=noop\ detail=mode=rollup\ reason=dashboard-backpressure-prior-snapshot*) ;;
  *)
    echo "expected socket dashboard failure with prior HTML to be noop" >&2
    echo "$result" >&2
    exit 1
    ;;
esac
grep -q 'dashboard_error=brain-list-socket-unreachable' <<<"$result"
grep -q 'brain_record_missing=1' <<<"$result"
grep -q 'previous_html_bytes=' <<<"$result"
grep -q 'previous_generated=2026-07-23T23:05Z' <<<"$result"

result="$("$BIN" --mode rollup --rc 1 --stderr-file "$WORK/socket.err" --previous-html "$WORK/missing.html")"
case "$result" in
  outcome=error\ detail=mode=rollup\ reason=dashboard-failed*) ;;
  *)
    echo "expected socket dashboard failure without prior HTML to stay error" >&2
    echo "$result" >&2
    exit 1
    ;;
esac
grep -q 'dashboard_error=brain-list-socket-unreachable' <<<"$result"

cat >"$WORK/missing-record.err" <<'ERR'
ERROR=command failed (1): brain get north-star-dashboard --type reference
record not found: north-star-dashboard
ERR
result="$("$BIN" --mode rollup --rc 1 --stderr-file "$WORK/missing-record.err" --previous-html "$WORK/previous.html")"
case "$result" in
  outcome=error\ detail=mode=rollup\ reason=dashboard-failed*) ;;
  *)
    echo "expected non-transient missing-record failure to stay error" >&2
    echo "$result" >&2
    exit 1
    ;;
esac
grep -q 'dashboard_error=missing-brain-record' <<<"$result"
grep -q 'previous_html_bytes=' <<<"$result"

echo "PASS last-stack-brain-sync-dashboard-result"
