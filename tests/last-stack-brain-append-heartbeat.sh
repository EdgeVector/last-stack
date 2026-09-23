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

echo "ok"
