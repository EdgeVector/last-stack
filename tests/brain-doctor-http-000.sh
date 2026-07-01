#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  if [ -n "${server_pid:-}" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

stubbin="$tmp/bin"
mkdir -p "$stubbin"

cat > "$stubbin/curl" <<'SH'
#!/usr/bin/env bash
printf '000'
exit 0
SH
chmod +x "$stubbin/curl"

cat > "$stubbin/lsof" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$stubbin/lsof"

cat > "$stubbin/pgrep" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$stubbin/pgrep"

cat > "$stubbin/launchctl" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "list" ]; then
  printf '123\t0\tcom.folddb.daemon\n'
fi
SH
chmod +x "$stubbin/launchctl"

cat > "$stubbin/brew" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$stubbin/brew"

cat > "$stubbin/df" <<'SH'
#!/usr/bin/env bash
printf 'Filesystem Size Used Avail Capacity Mounted on\n'
printf '/dev/disk 100Gi 50Gi 50Gi 50%% /System/Volumes/Data\n'
SH
chmod +x "$stubbin/df"

sock="$tmp/folddb.sock"
python3 - "$sock" <<'PY' &
import socket
import sys
import time

sock = socket.socket(socket.AF_UNIX)
sock.bind(sys.argv[1])
sock.listen(1)
time.sleep(60)
PY
server_pid=$!

for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -S "$sock" ] && break
  perl -e 'select undef, undef, undef, 0.05'
done
test -S "$sock"

out="$tmp/out"
set +e
PATH="$stubbin:$PATH" FOLDDB_HOME="$tmp/home" HEALTH_TIMEOUT=1 \
  "$ROOT/skills/brain-doctor/brain-doctor.sh" "$sock" >"$out" 2>&1
rc=$?
set -e

if [ "$rc" -ne 2 ]; then
  cat "$out" >&2
  echo "expected HTTP 000 to exit 2 (wedged/degraded), got $rc" >&2
  exit 1
fi

grep -q 'HTTP 000' "$out"
grep -q 'NOT alive' "$out"
if grep -q 'VERDICT: .*HEALTHY' "$out"; then
  cat "$out" >&2
  echo "HTTP 000 must not be reported as healthy" >&2
  exit 1
fi

echo "ok"
