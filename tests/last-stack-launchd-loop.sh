#!/usr/bin/env bash
# Fixture test for bin/last-stack-launchd-loop (KeepAlive guard loop).
# No launchd, no real ra/situations: fakes record what would be paged.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
LOOP="$ROOT/bin/last-stack-launchd-loop"
fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/launchd-loop-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
hb="$tmp/hb"
mkdir -p "$hb" "$tmp/bin"
cat >"$tmp/bin/ra" <<EOF
#!/bin/sh
echo "ra \$*" >>"$tmp/pages.log"
EOF
cat >"$tmp/bin/situations" <<EOF
#!/bin/sh
echo "situations \$*" >>"$tmp/pages.log"
EOF
cat >"$tmp/bin/guard" <<EOF
#!/bin/sh
echo "guard pass" >>"$tmp/guard.log"
exit 3
EOF
chmod +x "$tmp/bin/"*

export LAUNCHD_LOOP_HEARTBEAT_DIR="$hb"
export LAUNCHD_LOOP_RA="$tmp/bin/ra"
export LAUNCHD_LOOP_SITUATIONS="$tmp/bin/situations"
export LAUNCHD_LOOP_INTERVAL_SEC=0
export LAUNCHD_LOOP_LABEL=com.example.guard-a

# 1. Missing label is a usage error, not a silent loop.
if LAUNCHD_LOOP_LABEL='' "$LOOP" /bin/true >/dev/null 2>&1; then
  fail "loop ran without LAUNCHD_LOOP_LABEL"
fi

# 2. A failing guard does not end the loop; each pass writes a heartbeat.
out="$(LAUNCHD_LOOP_MAX_PASSES=3 "$LOOP" "$tmp/bin/guard")" || fail "loop exited non-zero"
[ "$(wc -l <"$tmp/guard.log" | tr -d ' ')" = 3 ] || fail "expected 3 guard passes, got $(cat "$tmp/guard.log")"
printf '%s\n' "$out" | grep -q 'pass=1 program exited rc=3 (loop continues)' || fail "no rc line: $out"
grep -q 'interval=0 ' "$hb/com.example.guard-a.hb" || fail "heartbeat lacks interval"
grep -q 'pass=3 rc=3 state=idle' "$hb/com.example.guard-a.hb" || fail "heartbeat: $(cat "$hb/com.example.guard-a.hb")"

# 3. A stale peer pages once, then the cooldown suppresses it.
old=$(( $(date +%s) - 1000 ))
printf 'epoch=%s interval=60 pid=1 pass=9 rc=0 state=idle\n' "$old" >"$hb/com.example.guard-b.hb"
out="$(LAUNCHD_LOOP_MAX_PASSES=1 "$LOOP" /usr/bin/true)"
printf '%s\n' "$out" | grep -q 'ALERT stale_peer peer=com.example.guard-b' || fail "no stale alert: $out"
grep -q '^ra notify .*guard com.example.guard-b is stale' "$tmp/pages.log" || fail "ra not paged: $(cat "$tmp/pages.log" 2>/dev/null)"
grep -q '^situations notice --title guard loop stale: com.example.guard-b' "$tmp/pages.log" || fail "no notice"
out="$(LAUNCHD_LOOP_MAX_PASSES=1 "$LOOP" /usr/bin/true)"
printf '%s\n' "$out" | grep -q 'stale_peer_suppressed peer=com.example.guard-b' || fail "cooldown did not hold: $out"
[ "$(grep -c '^ra ' "$tmp/pages.log")" = 1 ] || fail "paged twice"

# 4. A fresh peer and a long-interval peer inside its window do not page.
now=$(date +%s)
printf 'epoch=%s interval=60 pid=1 pass=1 rc=0 state=idle\n' "$now" >"$hb/com.example.guard-b.hb"
printf 'epoch=%s interval=900 pid=1 pass=1 rc=0 state=idle\n' "$((now - 1200))" >"$hb/com.example.guard-c.hb"
out="$(LAUNCHD_LOOP_MAX_PASSES=1 "$LOOP" /usr/bin/true)"
printf '%s\n' "$out" | grep -q 'stale_peer' && fail "false stale alert: $out"

# 5. SIGTERM (launchctl bootout) removes the own heartbeat and exits 0.
rm -f "$hb/com.example.guard-a.hb"
LAUNCHD_LOOP_INTERVAL_SEC=30 "$LOOP" /usr/bin/true >"$tmp/term.log" 2>&1 &
pid=$!
n=0
while [ ! -f "$hb/com.example.guard-a.hb" ] || ! grep -q 'state=idle' "$hb/com.example.guard-a.hb"; do
  n=$((n + 1)); [ "$n" -lt 50 ] || fail "loop did not reach sleep"; sleep 0.2
done
kill -TERM "$pid"
wait "$pid" || fail "loop exit status after TERM was $?"
[ ! -f "$hb/com.example.guard-a.hb" ] || fail "heartbeat left after TERM"
grep -q 'stop signal=TERM' "$tmp/term.log" || fail "no stop line: $(cat "$tmp/term.log")"

printf 'PASS: last-stack-launchd-loop\n'
