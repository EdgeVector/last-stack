#!/usr/bin/env bash
# Tests for last-stack-lastdb-dev — drive the real script against a FAKE
# primary home and a FAKE lastdbd. Never touches ~/.lastdb, ~/.brain, ~/.fkanban.
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-lastdb-dev"
chmod +x "$BIN"

fail=0
pass=0
assert() {
  local name="$1"
  shift
  if "$@"; then
    echo "ok - $name"
    pass=$((pass + 1))
  else
    echo "not ok - $name" >&2
    fail=$((fail + 1))
  fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/lastdb-dev-test.XXXXXX")"
cleanup() {
  if [ -f "$T/state/node.pid" ]; then
    kill "$(cat "$T/state/node.pid")" 2>/dev/null || true
  fi
  [ -n "${SLEEP_PID:-}" ] && kill "$SLEEP_PID" 2>/dev/null || true
  rm -rf "$T"
}
trap cleanup EXIT

# Fake primary home: a data/ tree, a live-looking socket name, cloud creds.
mkdir -p "$T/primary/data/data" "$T/state" "$T/home/Library/LaunchAgents"
echo "record" >"$T/primary/data/data/x"
echo '{"token":"secret"}' >"$T/primary/cloud_sync.json"
echo '{"pid":1}' >"$T/primary/current-session.json"
# A live socket in the primary makes cp -cR complain; the clone must survive it.
python3 - "$T/primary/data/folddb.sock" <<'PY' || true
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
PY

# Fake LaunchAgent plist with the primary's LASTDB_* tuning plus HOME-shaped keys.
cat >"$T/home/Library/LaunchAgents/com.example.lastdbd-primary-1.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.example.lastdbd-primary-1</string>
  <key>EnvironmentVariables</key><dict>
    <key>LASTDB_HOME</key><string>/should/not/leak</string>
    <key>LASTDB_ATOM_KEY_ENCODING</key><string>partition_prefix</string>
    <key>LASTDB_HASH_GROUP_WARM_BYTES</key><string>4294967296</string>
    <key>OBS_SENTRY_DSN</key><string>https://dsn.example</string>
  </dict>
</dict></plist>
PLIST

# Fake lastdbd: keeps its argv (no exec), prints the env it booted with.
cat >"$T/fake-lastdbd" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo "lastdbd 0.0.0-fake"; exit 0; fi
echo "argv: $*"
echo "LASTDB_HOME=${LASTDB_HOME:-unset}"
echo "FOLDDB_HOME=${FOLDDB_HOME:-unset}"
echo "LASTDB_ATOM_KEY_ENCODING=${LASTDB_ATOM_KEY_ENCODING:-unset}"
echo "LASTDB_HASH_GROUP_WARM_BYTES=${LASTDB_HASH_GROUP_WARM_BYTES:-unset}"
echo "OBS_SENTRY_DSN=${OBS_SENTRY_DSN:-unset}"
echo "EXTRA=${LASTDB_DEV_TEST_EXTRA:-unset}"
echo "RUST_MIN_STACK=${RUST_MIN_STACK:-unset}"
while :; do sleep 1; done
SH
chmod +x "$T/fake-lastdbd"

export LASTDB_DEV_HOME="$T/dev"
export LASTDB_DEV_STATE="$T/state"
export LASTDB_DEV_PRIMARY_HOME="$T/primary"
export LASTDB_LAUNCHD_PLIST="$T/home/Library/LaunchAgents/com.example.lastdbd-primary-1.plist"
export OBS_SENTRY_DSN="https://caller-dsn.example"

# 1) help
"$BIN" --help >/dev/null
assert "--help exits 0" test $? -eq 0

# 2) usage error
set +e; "$BIN" >/dev/null 2>&1; rc=$?; set -e
assert "no command exits 2" test "$rc" -eq 2

# 3) refuse a dev home that IS the primary
set +e
out="$(LASTDB_DEV_HOME="$T/primary" "$BIN" up --bin "$T/fake-lastdbd" --no-wait 2>&1)"; rc=$?
set -e
assert "dev home == primary is refused" test "$rc" -ne 0
assert "refusal names the primary" bash -c "printf '%s' \"\$1\" | grep -q 'primary home'" _ "$out"

# 4) refuse a dev home nested inside the primary
set +e
LASTDB_DEV_HOME="$T/primary/data" "$BIN" status >/dev/null 2>&1; rc_status=$?
LASTDB_DEV_HOME="$T/primary/data" "$BIN" up --bin "$T/fake-lastdbd" --no-wait >/dev/null 2>&1; rc=$?
set -e
assert "dev home inside primary is refused" test "$rc" -ne 0

# 5) refuse a symlinked dev home
ln -s "$T/primary" "$T/devlink"
set +e
LASTDB_DEV_HOME="$T/devlink" "$BIN" up --bin "$T/fake-lastdbd" --no-wait >/dev/null 2>&1; rc=$?
set -e
assert "symlinked dev home is refused" test "$rc" -ne 0
rm -f "$T/devlink"

# 6) up: clones, strips cloud creds, boots with mirrored env and dev home
"$BIN" up --bin "$T/fake-lastdbd" --no-wait --env LASTDB_DEV_TEST_EXTRA=yes >"$T/up.out" 2>&1
assert "up exits 0" test $? -eq 0
assert "clone has the data tree" test -f "$T/dev/data/data/x"
assert "clone survived the primary's live socket" test ! -e "$T/dev/data/folddb.sock"
assert "socket complaint is not surfaced as a warning" bash -c '! grep -q "WARN clone" "$1"' _ "$T/up.out"
assert "clone has no cloud_sync.json" test ! -e "$T/dev/cloud_sync.json"
assert "clone has no current-session.json" test ! -e "$T/dev/current-session.json"
assert "primary still has cloud_sync.json" test -f "$T/primary/cloud_sync.json"
assert "pidfile written" test -f "$T/state/node.pid"
sleep 1
assert "node argv carries --data-dir dev home" grep -q -- "argv: --data-dir $T/dev" "$T/state/boot.log"
assert "LASTDB_HOME overridden to dev home" grep -q "^LASTDB_HOME=$T/dev\$" "$T/state/boot.log"
assert "FOLDDB_HOME overridden to dev home" grep -q "^FOLDDB_HOME=$T/dev\$" "$T/state/boot.log"
assert "atom key encoding mirrored from plist" grep -q '^LASTDB_ATOM_KEY_ENCODING=partition_prefix$' "$T/state/boot.log"
assert "warm bytes mirrored from plist" grep -q '^LASTDB_HASH_GROUP_WARM_BYTES=4294967296$' "$T/state/boot.log"
assert "sentry dsn stripped" grep -q '^OBS_SENTRY_DSN=unset$' "$T/state/boot.log"
assert "--env K=V reaches the node" grep -q '^EXTRA=yes$' "$T/state/boot.log"
assert "boot.env recorded" grep -q 'LASTDB_ATOM_KEY_ENCODING=partition_prefix' "$T/state/boot.env"

# 7) status
assert "status --json says running" test "$("$BIN" status --json | jq -r '.running')" = "true"
assert "status --json records binary source" test "$("$BIN" status --json | jq -r '.binary_source')" = "bin"
assert "status --json carries dev socket" test "$("$BIN" status --json | jq -r '.socket')" = "$T/dev/data/folddb.sock"

# 8) second up refuses while running
set +e; "$BIN" up --bin "$T/fake-lastdbd" --no-wait >/dev/null 2>&1; rc=$?; set -e
assert "up while running is refused" test "$rc" -ne 0

# 9) env: exports point every client at the dev socket
env_out="$("$BIN" env)"
assert "env exports LASTDB_HOME" bash -c "printf '%s' \"\$1\" | grep -q \"^export LASTDB_HOME='$T/dev'\$\"" _ "$env_out"
assert "env exports FBRAIN_FOLDDB_SOCKET" bash -c "printf '%s' \"\$1\" | grep -q \"^export FBRAIN_FOLDDB_SOCKET='$T/dev/data/folddb.sock'\$\"" _ "$env_out"
assert "env exports FOLDDB_SOCKET_PATH" bash -c "printf '%s' \"\$1\" | grep -q \"^export FOLDDB_SOCKET_PATH='$T/dev/data/folddb.sock'\$\"" _ "$env_out"
assert "env exports LAST_STACK_LASTDB_SOCKET" bash -c "printf '%s' \"\$1\" | grep -q '^export LAST_STACK_LASTDB_SOCKET='" _ "$env_out"
assert "env is eval-able" bash -c "eval \"\$1\" && [ \"\$LASTDB_DEV_ACTIVE\" = 1 ]" _ "$env_out"

# 10) run -- passes the env to the child
got="$("$BIN" run -- sh -c 'printf %s "$LASTDB_HOME"')"
assert "run -- sees the dev home" test "$got" = "$T/dev"

# 11) restart keeps the clone (no re-clone) and boots again
before="$(cut -d' ' -f1 "$T/state/clone.stamp")"
"$BIN" restart --bin "$T/fake-lastdbd" --no-wait >/dev/null 2>&1
after="$(cut -d' ' -f1 "$T/state/clone.stamp")"
assert "restart keeps the clone" test "$before" = "$after"
assert "restart is running" test "$("$BIN" status --json | jq -r '.running')" = "true"

# 12) stop
"$BIN" stop >/dev/null 2>&1
assert "stop exits 0" test $? -eq 0
assert "stop removes pidfile" test ! -f "$T/state/node.pid"
assert "status says down" test "$("$BIN" status --json | jq -r '.running')" = "false"

# 13) stop refuses a pid that is not our node
sleep 300 &
SLEEP_PID=$!
echo "$SLEEP_PID" >"$T/state/node.pid"
set +e; "$BIN" stop >/dev/null 2>&1; rc=$?; set -e
assert "stop refuses a foreign pid" test "$rc" -ne 0
assert "foreign pid still alive" kill -0 "$SLEEP_PID"
kill "$SLEEP_PID" 2>/dev/null || true
SLEEP_PID=""
rm -f "$T/state/node.pid"

# 14) stop when down is a no-op success
"$BIN" stop >/dev/null 2>&1
assert "stop when down exits 0" test $? -eq 0

# 15) refresh re-clones (new stamp) and does not restart a node that was down
echo "newer" >"$T/primary/data/data/y"
sleep 1
"$BIN" refresh >/dev/null 2>&1
assert "refresh picks up new primary data" test -f "$T/dev/data/data/y"
assert "refresh leaves a down node down" test "$("$BIN" status --json | jq -r '.running')" = "false"

# 16) build path: a fake cargo stages the binary out of target/, and a debug
#     build boots with the raised worker stack
mkdir -p "$T/wt/lastdb_node" "$T/fakebin"
echo '[package]' >"$T/wt/lastdb_node/Cargo.toml"
cat >"$T/fakebin/cargo" <<SH
#!/usr/bin/env bash
# fake cargo: "build" drops a lastdbd into target/<profile>/
profile=debug
for a in "\$@"; do [ "\$a" = --release ] && profile=release; done
mkdir -p "target/\$profile"
cp "$T/fake-lastdbd" "target/\$profile/lastdbd"
echo "fake cargo built \$profile"
SH
chmod +x "$T/fakebin/cargo"
PATH="$T/fakebin:$PATH" "$BIN" build --worktree "$T/wt" >"$T/build.out" 2>&1
assert "build exits 0" test $? -eq 0
assert "build stages the binary out of target/" test -x "$T/state/bin/lastdbd"
assert "build records profile=debug" grep -q '^profile=debug$' "$T/state/source"
assert "build remembers the worktree" test "$(cat "$T/state/worktree")" = "$(cd "$T/wt" && pwd -P)"
"$BIN" up --staged --no-wait >/dev/null 2>&1
sleep 1
assert "debug build boots with a raised RUST_MIN_STACK" grep -q '^RUST_MIN_STACK=67108864$' "$T/state/boot.log"
"$BIN" stop >/dev/null 2>&1
"$BIN" up --staged --no-wait --env RUST_MIN_STACK=1234 >/dev/null 2>&1
sleep 1
assert "caller's RUST_MIN_STACK wins over the default" grep -q '^RUST_MIN_STACK=1234$' "$T/state/boot.log"
"$BIN" stop >/dev/null 2>&1
PATH="$T/fakebin:$PATH" "$BIN" build --worktree "$T/wt" --release >/dev/null 2>&1
assert "release build records profile=release" grep -q '^profile=release$' "$T/state/source"
"$BIN" up --staged --no-wait >/dev/null 2>&1
sleep 1
assert "release build gets no RUST_MIN_STACK default" grep -q '^RUST_MIN_STACK=unset$' "$T/state/boot.log"
"$BIN" stop >/dev/null 2>&1

# 17) reset deletes the dev home, never the primary
"$BIN" reset >/dev/null 2>&1
assert "reset removes the dev home" test ! -e "$T/dev"
assert "reset leaves the primary intact" test -f "$T/primary/data/data/x"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
