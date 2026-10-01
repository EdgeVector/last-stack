#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-canary-loom-rehearse"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
bash -n "$BIN"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-canary-loom-rehearse.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
tmp="$(CDPATH= cd -- "$tmp" && pwd -P)"
mock_bin="$tmp/cache-home/.local/bin"
mkdir -p "$mock_bin"

cat > "$mock_bin/last-stack-canary-loom" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_CANARY_LOOM_CALLS:?}"
case "${FAKE_CANARY_LOOM_MODE:-success}" in
  success) jq -cn --arg exec lx-rehearse-test '{outcome:"ok",execution:$exec,status:"running",key:"ignored-here"}' ;;
  no-exec) jq -cn '{outcome:"ok",execution:"",status:"running"}' ;;
esac
SH
chmod 755 "$mock_bin/last-stack-canary-loom"

cat > "$mock_bin/loom" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in show) printf '%s\n' 'status: succeeded' 'state: DONE' ;; *) exit 2 ;; esac
SH
chmod 755 "$mock_bin/loom"

mkdir -p "$tmp/fold-mirror"
git -C "$tmp/fold-mirror" init -q
git -C "$tmp/fold-mirror" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$tmp/cache-home/.cache/edgevector-git"
git -C "$tmp/fold-mirror" branch -f main
git clone -q --bare "$tmp/fold-mirror" "$tmp/cache-home/.cache/edgevector-git/fold.git"
expected_oid="$(git -C "$tmp/fold-mirror" rev-parse main)"

export FAKE_CANARY_LOOM_CALLS="$tmp/calls.log"
: >"$FAKE_CANARY_LOOM_CALLS"
out="$(HOME="$tmp/cache-home" PATH="$mock_bin:$PATH" FAKE_CANARY_LOOM_MODE=success "$BIN" --watch-secs 0)"
printf '%s\n' "$out" | grep -q 'REHEARSE_RESULT execution=lx-rehearse-test' || fail "rehearse did not report launch: $out"
grep -q -- "--oid $expected_oid" "$FAKE_CANARY_LOOM_CALLS" || fail "rehearse did not resolve fold main"
grep -Eq -- '--key canary-rehearse-[0-9]{8}T[0-9]{6}Z' "$FAKE_CANARY_LOOM_CALLS" || fail "rehearse did not mint a timestamped key"

: >"$FAKE_CANARY_LOOM_CALLS"
HOME="$tmp/cache-home" PATH="$mock_bin:$PATH" FAKE_CANARY_LOOM_MODE=success "$BIN" --watch-secs 0 >/dev/null
sleep 1
HOME="$tmp/cache-home" PATH="$mock_bin:$PATH" FAKE_CANARY_LOOM_MODE=success "$BIN" --watch-secs 0 >/dev/null
key1="$(sed -n '1p' "$FAKE_CANARY_LOOM_CALLS" | grep -oE 'canary-rehearse-[0-9TZ]+')"
key2="$(sed -n '2p' "$FAKE_CANARY_LOOM_CALLS" | grep -oE 'canary-rehearse-[0-9TZ]+')"
[ "$key1" != "$key2" ] || fail "two rehearsals minted the same key: $key1"

: >"$FAKE_CANARY_LOOM_CALLS"
HOME="$tmp/cache-home" PATH="$mock_bin:$PATH" FAKE_CANARY_LOOM_MODE=success "$BIN" --oid deadbeefdeadbeefdeadbeefdeadbeefdeadbeef --watch-secs 0 >/dev/null
grep -q -- '--oid deadbeefdeadbeefdeadbeefdeadbeefdeadbeef' "$FAKE_CANARY_LOOM_CALLS" || fail "explicit --oid was not passed through"

set +e
no_exec_out="$(HOME="$tmp/cache-home" PATH="$mock_bin:$PATH" FAKE_CANARY_LOOM_MODE=no-exec "$BIN" --oid deadbeefdeadbeefdeadbeefdeadbeefdeadbeef --watch-secs 0 2>&1)"
no_exec_rc=$?
set -e
[ "$no_exec_rc" -eq 3 ] || fail "missing execution id returned $no_exec_rc, expected 3"
printf '%s\n' "$no_exec_out" | grep -q 'did not return an execution id' || fail "missing-execution failure did not explain itself"

watch_out="$(HOME="$tmp/cache-home" PATH="$mock_bin:$PATH" FAKE_CANARY_LOOM_MODE=success "$BIN" --oid deadbeefdeadbeefdeadbeefdeadbeefdeadbeef --watch-secs 15 2>&1)"
printf '%s\n' "$watch_out" | grep -q 'status: succeeded state: DONE' || fail "watch mode did not report the state"

json_out="$(HOME="$tmp/cache-home" PATH="$mock_bin:$PATH" FAKE_CANARY_LOOM_MODE=success "$BIN" --oid deadbeefdeadbeefdeadbeefdeadbeefdeadbeef --watch-secs 0 --json)"
printf '%s\n' "$json_out" | jq -e '.execution == "lx-rehearse-test" and (.key | startswith("canary-rehearse-")) and .oid == "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"' >/dev/null || fail "--json output malformed"

set +e
bad_watch_out="$(HOME="$tmp/cache-home" PATH="$mock_bin:$PATH" "$BIN" --watch-secs nope 2>&1)"
bad_watch_rc=$?
set -e
[ "$bad_watch_rc" -eq 2 ] || fail "bad --watch-secs returned $bad_watch_rc, expected 2"

echo "ok last-stack-canary-loom-rehearse"
