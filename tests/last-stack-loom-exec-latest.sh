#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-loom-exec-latest"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

bash -n "$BIN"
[ -x "$BIN" ] || fail "lister is not executable"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-loom-exec.XXXXXX")"
# AF_UNIX paths are short on macOS; a sandboxed TMPDIR overruns the limit.
sockdir="$(mktemp -d /tmp/lsx.XXXXXX)"
trap 'rm -rf "$tmp" "$sockdir"' EXIT

# --- usage ---
set +e
"$BIN" >"$tmp/usage.out" 2>"$tmp/usage.err"
urc=$?
set -e
[ "$urc" -eq 2 ] || fail "no selector must exit 2, got $urc"

# --- unreadable loom records exit 3, never a silent empty listing ---
set +e
LOOM_SOCKET="$tmp/missing.sock" LOOM_SCHEMA_MAP="$tmp/missing.json" \
  "$BIN" --definition lastdb-canary-release >"$tmp/nosock.out" 2>"$tmp/nosock.err"
nrc=$?
set -e
[ "$nrc" -eq 3 ] || fail "missing socket must exit 3, got $nrc"

# Real socket, no schema map: still exit 3 (loom init never ran).
python3 - "$sockdir/node.sock" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
PY
printf '%s\n' '{"LoomDefinition":"aaa"}' >"$tmp/nomap.json"
set +e
LOOM_SOCKET="$sockdir/node.sock" LOOM_SCHEMA_MAP="$tmp/nomap.json" \
  "$BIN" --definition lastdb-canary-release >"$tmp/nomap.out" 2>"$tmp/nomap.err"
mrc=$?
set -e
[ "$mrc" -eq 3 ] || fail "missing LoomExecution schema must exit 3, got $mrc"

# --- windowed, newest-first walk over a stubbed node ---
printf '%s\n' '{"LoomExecution":"execschema"}' >"$tmp/map.json"
mkdir -p "$tmp/bin" "$tmp/rows"

recent="$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=2)).strftime("%Y%m%dT%H%M%S.000"))')"
older="$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=6)).strftime("%Y%m%dT%H%M%S.000"))')"
ancient="20200101T000000.000"

hit="lx-$recent-100-1"
sibling="lx-$recent-100-2"
prior="lx-$older-90-1"
stale="lx-$ancient-1-1"

cat >"$tmp/list.json" <<JSON
{"list":{"keys":[{"hash":"$prior"},{"hash":"$stale"},{"hash":"$sibling"},{"hash":"$hit"}],"truncated":false,"next_cursor":null}}
JSON

row() { printf '{"results":[{"fields":{"id":"%s","definition_name":"%s","status":"%s","state":"%s","created_at":"c","updated_at":"u"}}]}\n' "$1" "$2" "$3" "$4" >"$tmp/rows/$1.json"; }
row "$hit" lastdb-canary-release failed FAILED
row "$sibling" lastdb-safe-upgrade failed FAILED
row "$prior" lastdb-canary-release succeeded DONE
row "$stale" lastdb-canary-release failed FAILED

cat >"$tmp/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
payload=""
url=""
for a in "$@"; do
  case "$a" in
    *api/list*) url="list" ;;
    '{"schema_name"'*) payload="$a" ;;
  esac
done
if [ "$url" = "list" ]; then
  cat "$STUB_DIR/list.json"
  echo "$(basename "$0")" >>"$STUB_DIR/list-calls.txt"
  exit 0
fi
id="$(printf '%s' "$payload" | sed -E 's/.*"HashKey":"([^"]+)".*/\1/')"
echo "$id" >>"$STUB_DIR/probed.txt"
if [ -f "$STUB_DIR/rows/$id.json" ]; then
  cat "$STUB_DIR/rows/$id.json"
else
  echo '{"results":[]}'
fi
SH
chmod 755 "$tmp/bin/curl"

: >"$tmp/probed.txt"
export HIT="$hit"
out="$(STUB_DIR="$tmp" PATH="$tmp/bin:$PATH" LOOM_SOCKET="$sockdir/node.sock" \
  LOOM_SCHEMA_MAP="$tmp/map.json" \
  "$BIN" --definition lastdb-canary-release --window-hours 12)"

printf '%s\n' "$out" | python3 -c 'import json,sys,os
rows=json.load(sys.stdin)
assert isinstance(rows,list) and len(rows)==1, rows
assert rows[0]["id"]==os.environ["HIT"], rows
assert rows[0]["definition_name"]=="lastdb-canary-release", rows' \
  || fail "lister did not return the newest lane execution: $out"

# The out-of-window id is filtered on the key alone: never point-queried.
if grep -q "$stale" "$tmp/probed.txt"; then fail "lister probed an out-of-window execution"; fi
# The walk runs newest first and stops at the first match.
if grep -q "$prior" "$tmp/probed.txt"; then fail "lister kept probing after the newest match"; fi
grep -q "$hit" "$tmp/probed.txt" || fail "lister never probed the newest execution"

# --- point read by id needs no listing ---
: >"$tmp/probed.txt"
rm -f "$tmp/list-calls.txt"
one="$(STUB_DIR="$tmp" PATH="$tmp/bin:$PATH" LOOM_SOCKET="$sockdir/node.sock" \
  LOOM_SCHEMA_MAP="$tmp/map.json" "$BIN" --exec "$hit")"
printf '%s\n' "$one" | python3 -c 'import json,sys,os
rows=json.load(sys.stdin)
assert len(rows)==1 and rows[0]["id"]==os.environ["HIT"], rows' \
  || fail "--exec did not point-read the execution: $one"
[ ! -f "$tmp/list-calls.txt" ] || fail "--exec must not list keys"

echo "ok"
