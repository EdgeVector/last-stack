#!/usr/bin/env bash
# Heartbeats are filesystem-only (not LastDB/brain).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

export LAST_STACK_HEARTBEATS_FILE="$tmp/routine-heartbeats.log"

"$ROOT/bin/last-stack-brain-append-heartbeat" --line "first-line"
"$ROOT/bin/last-stack-brain-append-heartbeat" --line "second-line"
printf '%s\n' "third-line" | "$ROOT/bin/last-stack-brain-append-heartbeat" --stdin

expected="$tmp/expected"
printf 'first-line\nsecond-line\nthird-line\n' >"$expected"
cmp "$expected" "$LAST_STACK_HEARTBEATS_FILE"

# Must never invoke brain even if on PATH
fake_bin="$tmp/bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/brain" <<'FAKE'
#!/usr/bin/env bash
echo "brain must not be called for heartbeats" >&2
exit 99
FAKE
chmod +x "$fake_bin/brain"
export PATH="$fake_bin:/usr/bin:/bin"
"$ROOT/bin/last-stack-brain-append-heartbeat" --line "no-brain"
grep -q 'no-brain' "$LAST_STACK_HEARTBEATS_FILE"

path_out="$("$ROOT/bin/last-stack-heartbeats-path")"
[ "$path_out" = "$LAST_STACK_HEARTBEATS_FILE" ]

# Must not require host /tmp (Codex sandbox EPERM). Capture stderr in-process
# even when TMPDIR is a missing/unwritable path.
blocked="$tmp/blocked-tmp"
mkdir -p "$blocked"
chmod 000 "$blocked"
export TMPDIR="$blocked"
"$ROOT/bin/last-stack-brain-append-heartbeat" --line "no-host-tmp"
grep -q 'no-host-tmp' "$LAST_STACK_HEARTBEATS_FILE"
chmod 700 "$blocked"

# PATH-linked from a non-root dir (host-track links into ~/.local/bin, and
# ~/.local/logs exists): the log must go to $HOME/.last-stack/logs, not to
# <link dir>/../logs.
unset LAST_STACK_HEARTBEATS_FILE
export TMPDIR="$tmp"
fake_home="$tmp/home"
mkdir -p "$fake_home/.last-stack/logs" "$tmp/local/bin" "$tmp/local/logs"
ln -s "$ROOT/bin/last-stack-brain-append-heartbeat" "$tmp/local/bin/last-stack-brain-append-heartbeat"
ln -s "$ROOT/bin/last-stack-heartbeats-path" "$tmp/local/bin/last-stack-heartbeats-path"
HOME="$fake_home" ROUTINES_HOME="$tmp/routines" "$tmp/local/bin/last-stack-brain-append-heartbeat" --line "via-path-link"
grep -q 'via-path-link' "$fake_home/.last-stack/logs/routine-heartbeats.log"
[ ! -e "$tmp/local/logs/routine-heartbeats.log" ]
linked_path="$(HOME="$fake_home" ROUTINES_HOME="$tmp/routines" "$tmp/local/bin/last-stack-heartbeats-path")"
case "$linked_path" in
  */home/.last-stack/logs/routine-heartbeats.log) ;;
  *) echo "heartbeats-path via PATH link printed $linked_path" >&2; exit 1 ;;
esac

# --automation / --automation-id / --run-id: the milestone-driver prompt passes
# them, and the positional fallback used to log the flags as the line
# ("--automation-id last-stack-milestone-driver --line GAP_FILL ..."). Now the
# line gets the standard "<routine> <UTC time> <rest>" shape.
export LAST_STACK_HEARTBEATS_FILE="$tmp/auto.log"
"$ROOT/bin/last-stack-brain-append-heartbeat" --automation-id last-stack-milestone-driver --line "GAP_FILL FILED=0 outcome=noop"
"$ROOT/bin/last-stack-brain-append-heartbeat" --automation last-stack-milestone-driver --run-id 2026-09-26T02-38-23Z --line "GAP_FILL FILED=1"
grep -Eq '^last-stack-milestone-driver [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z GAP_FILL FILED=0 outcome=noop$' "$LAST_STACK_HEARTBEATS_FILE" \
  || { echo "--automation-id line has the wrong shape" >&2; cat "$LAST_STACK_HEARTBEATS_FILE" >&2; exit 1; }
grep -Eq '^last-stack-milestone-driver [0-9T:Z-]+ GAP_FILL FILED=1$' "$LAST_STACK_HEARTBEATS_FILE" \
  || { echo "--automation --run-id line has the wrong shape" >&2; exit 1; }
if grep -q -- '--' "$LAST_STACK_HEARTBEATS_FILE"; then
  echo "a flag leaked into the heartbeat log" >&2; exit 1
fi
# An unknown flag is an error, not a logged line.
if "$ROOT/bin/last-stack-brain-append-heartbeat" --bogus x --line y 2>/dev/null; then
  echo "unknown flag was accepted" >&2; exit 1
fi
"$ROOT/bin/last-stack-brain-append-heartbeat" --routine kanban-pickup --label x --line "noop fenced"
grep -Eq '^kanban-pickup [0-9T:Z-]+ noop fenced$' "$LAST_STACK_HEARTBEATS_FILE" || { echo "--routine alias failed" >&2; exit 1; }
[ "$(wc -l < "$LAST_STACK_HEARTBEATS_FILE" | tr -d ' ')" = 3 ] || { echo "unknown flag wrote a line" >&2; exit 1; }
# The plain positional form still works.
"$ROOT/bin/last-stack-brain-append-heartbeat" "plain-routine 2026-09-26T00:00:00Z ok"
grep -q '^plain-routine 2026-09-26T00:00:00Z ok$' "$LAST_STACK_HEARTBEATS_FILE"

echo "ok"
