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

echo "ok"
