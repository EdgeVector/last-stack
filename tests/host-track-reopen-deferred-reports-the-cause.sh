#!/usr/bin/env bash
# host-track's deferred-card reopen pass must report WHY it failed.
#
# Until 2026-10-04 `reopen_deferred_cards()` ran the helper as
# `>/dev/null 2>&1` and, on failure, printed a fixed line with no cause and no
# exit code -- strictly less than the exit code alone. Measured that day on this
# host: 31 failures in ~/.host-track-guard/guard.log between 2026-09-24 and
# 2026-10-04, every one identical, and the cause present in no artefact. The
# helper names its reason every time it fails
# (`error=[Errno 2] No such file or directory: 'kanban'` under a PATH without
# ~/.local/bin); `2>&1` to /dev/null is what deleted it. And because the message
# ends `next activation retries`, a permanent cause and a transient one print
# identically at the same cadence, so a reader cannot even tell which they have.
# papercut-host-track-deferred-card-reopen-failed-31-times-in-10-days-and-the-wrapper-discards-the-cause-20261004
set -uo pipefail

ROOT_REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/ht-reopen-test.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
fail=0
bad() { printf 'FAIL: %s\n' "$1" >&2; fail=1; }
pass() { printf 'ok: %s\n' "$1"; }

# ---------------------------------------------------------------------------
# 1. Structural: the helper invocation must not discard its own streams.
# Comments are stripped first -- the rationale above and in bin/host-track
# quotes the defective form verbatim, and a guard that matches its own
# explanation fires on correct source.
# ---------------------------------------------------------------------------
body="$(awk '/^reopen_deferred_cards\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$ROOT_REPO/bin/host-track")"
[ -n "$body" ] || bad "reopen_deferred_cards() not found in bin/host-track"
code="$(printf '%s\n' "$body" | sed 's/[[:space:]]*#.*$//')"
printf '%s\n' "$code" | grep -q '>/dev/null 2>&1' \
  && bad "reopen_deferred_cards still sends the helper's streams to /dev/null; the cause cannot reach any log"
printf '%s\n' "$code" | grep -q 'rc=%s' \
  || bad "the failure message does not carry the helper's exit code"
pass "the helper invocation keeps its streams and the message carries rc"

# ---------------------------------------------------------------------------
# 2. Behavioural: a failing helper's first stderr line reaches the message.
# This is the assertion that matters. The structural check above can be
# satisfied by a capture that is then thrown away.
# ---------------------------------------------------------------------------
mkdir -p "$tmp/root/bin"
cat > "$tmp/root/bin/last-stack-kanban-reopen-deferred" <<'STUB'
#!/usr/bin/env bash
echo "stub stdout that must not be mistaken for the cause"
echo "last-stack-kanban-reopen-deferred: error=[Errno 2] No such file or directory: 'kanban'" >&2
echo "a second stderr line that is NOT the one to report" >&2
exit 7
STUB
chmod +x "$tmp/root/bin/last-stack-kanban-reopen-deferred"

ROOT="$tmp/root"
eval "$body"
reopen_deferred_cards 2> "$tmp/err" > "$tmp/out"

grep -q 'rc=7' "$tmp/err" \
  || bad "the message does not name the helper's exit code 7: $(head -1 "$tmp/err")"
grep -q "No such file or directory: 'kanban'" "$tmp/err" \
  || bad "the helper's own first stderr line did not reach the message: $(head -1 "$tmp/err")"
grep -q 'next activation retries' "$tmp/err" \
  || bad "the message no longer says the pass retries"
grep -q 'a second stderr line' "$tmp/err" \
  && bad "the message carries more than the first stderr line; a multi-line log row is not a message"
grep -q 'stub stdout' "$tmp/err" \
  && bad "stdout was reported as the cause; the diagnosis is on stderr"
pass "a failing helper's exit code and first stderr line reach the message"

# ---------------------------------------------------------------------------
# 3. A helper that SUCCEEDS stays silent. The denominator comes from the
# activation count, and a row per tick would bury the failures this exists to
# show -- so the quiet path is deliberate and pinned.
# ---------------------------------------------------------------------------
cat > "$tmp/root/bin/last-stack-kanban-reopen-deferred" <<'STUB'
#!/usr/bin/env bash
echo "last-stack-kanban-reopen-deferred scanned=14 reopened=0 unchanged=14 skipped=0"
exit 0
STUB
chmod +x "$tmp/root/bin/last-stack-kanban-reopen-deferred"
reopen_deferred_cards 2> "$tmp/err2" > "$tmp/out2"
[ ! -s "$tmp/err2" ] \
  || bad "a successful reopen pass wrote to stderr: $(head -1 "$tmp/err2")"
pass "a successful reopen pass is silent"

# ---------------------------------------------------------------------------
# 4. HOST_TRACK_REOPEN_DEFERRED=0 still disables the pass entirely.
# ---------------------------------------------------------------------------
cat > "$tmp/root/bin/last-stack-kanban-reopen-deferred" <<'STUB'
#!/usr/bin/env bash
echo "this helper must not run" >&2
exit 9
STUB
chmod +x "$tmp/root/bin/last-stack-kanban-reopen-deferred"
HOST_TRACK_REOPEN_DEFERRED=0 reopen_deferred_cards 2> "$tmp/err3" > "$tmp/out3"
[ ! -s "$tmp/err3" ] \
  || bad "HOST_TRACK_REOPEN_DEFERRED=0 no longer disables the pass: $(head -1 "$tmp/err3")"
pass "HOST_TRACK_REOPEN_DEFERRED=0 disables the pass"

if [ "$fail" -ne 0 ]; then
  echo "host-track reopen-deferred diagnosis guard: FAILED" >&2
  exit 1
fi
echo "ok host-track reopen-deferred diagnosis guard: 4 checks"
