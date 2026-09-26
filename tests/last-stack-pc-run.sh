#!/usr/bin/env bash
# last-stack-pc-run sends the script on stdin with GIT_TERMINAL_PROMPT=0 and
# the forge token as env-only git config; the token never reaches argv.
# papercut-pc-wsl-forge-clone-hangs-forever-on-credential-prompt
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-pc-run"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pc-run.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

mkdir -p "$WORK/bin"
cat >"$WORK/bin/ssh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$FAKE_DIR/argv"
cat >"$FAKE_DIR/stdin"
echo remote-ok
FAKE
chmod +x "$WORK/bin/ssh"
printf 'echo hello-from-script\n' >"$WORK/job.sh"

export LAST_STACK_PC_CI_STATE="$WORK/no-pause.json"
out="$(FAKE_DIR="$WORK" FORGE_TOKEN=secret-tok PATH="$WORK/bin:$PATH" "$BIN" --timeout 30 "$WORK/job.sh")"
[ "$out" = remote-ok ] || fail "stdout: $out"
grep -q '^export GIT_TERMINAL_PROMPT=0$' "$WORK/stdin" || fail "no GIT_TERMINAL_PROMPT=0"
grep -q 'GIT_CONFIG_KEY_0=http.extraHeader' "$WORK/stdin" || fail "no extraHeader key"
grep -q 'secret-tok' "$WORK/stdin" || fail "token missing from stdin payload"
grep -q 'echo hello-from-script' "$WORK/stdin" || fail "script body missing"
! grep -q 'secret-tok' "$WORK/argv" || fail "token leaked into ssh argv"
grep -q 'wsl -d Ubuntu-24.04 -u tom -- bash -s' "$WORK/argv" || fail "remote command: $(cat "$WORK/argv")"

# stdin form
out="$(printf 'echo via-stdin\n' | FAKE_DIR="$WORK" FORGE_TOKEN=t2 PATH="$WORK/bin:$PATH" "$BIN" -)"
grep -q 'echo via-stdin' "$WORK/stdin" || fail "stdin script missing"

# timeout: a hung ssh is killed
cat >"$WORK/bin/ssh" <<'FAKE'
#!/usr/bin/env bash
cat >/dev/null; sleep 30
FAKE
start=$SECONDS
set +e; FORGE_TOKEN=t PATH="$WORK/bin:$PATH" "$BIN" --timeout 2 "$WORK/job.sh" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -ne 0 ] || fail "timeout returned 0"
[ $((SECONDS - start)) -lt 15 ] || fail "timeout did not stop the hung ssh"
# owner pause: refuse while paused, run once the pause has expired
cat >"$WORK/bin/ssh" <<'FAKE'
#!/usr/bin/env bash
cat >/dev/null; echo remote-ok
FAKE
printf '{"intent":"paused","until":"2999-01-01T00:00:00Z","reason":"gaming"}\n' >"$WORK/paused.json"
set +e; err="$(LAST_STACK_PC_CI_STATE="$WORK/paused.json" FORGE_TOKEN=t PATH="$WORK/bin:$PATH" "$BIN" "$WORK/job.sh" 2>&1 >/dev/null)"; rc=$?; set -e
[ "$rc" -eq 3 ] && [[ "$err" == *"paused by its owner"*"gaming"* ]] || fail "pause not honored: rc=$rc err=$err"
printf '{"intent":"paused","until":"2000-01-01T00:00:00Z","reason":"old"}\n' >"$WORK/expired.json"
out="$(LAST_STACK_PC_CI_STATE="$WORK/expired.json" FORGE_TOKEN=t PATH="$WORK/bin:$PATH" "$BIN" "$WORK/job.sh")"
[ "$out" = remote-ok ] || fail "expired pause still blocked: $out"

# empty pause file must not block execution
# papercut-forge-runner-watchdog-empty-pause-jq-20260923
printf '' >"$WORK/empty.json"
out="$(LAST_STACK_PC_CI_STATE="$WORK/empty.json" FORGE_TOKEN=t PATH="$WORK/bin:$PATH" "$BIN" "$WORK/job.sh")"
[ "$out" = remote-ok ] || fail "empty pause file blocked execution: $out"

echo "ok last-stack-pc-run"
