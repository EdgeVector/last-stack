#!/usr/bin/env bash
# The Forge token must never appear in a child process's argv.
#
# `ps aux` lists argv to every local account on this host, so a token passed as
# `git -c http.<base>.extraHeader=Authorization: token <t>` or as
# `curl -H "Authorization: token <t>"` is a secret published machine-wide for the
# life of the call. Both were observed live on the primary:
#   papercut-forge-git-extraheader-token-visible-in-ps-20260923   (p0)
#   papercut-last-stack-forge-api-token-on-curl-argv-20260924     (p1)
#
# This suite asserts BOTH halves, because either one alone is satisfiable by a
# broken helper: the token is absent from argv, AND the request still carries the
# Authorization header. A helper that simply stopped authenticating would pass a
# leak-only check.
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
TOKEN="tok-argv-probe-4d9f2a"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/forge-token-argv.XXXXXX")"
cleanup() {
  if [ -n "${MOCK_PID:-}" ] && kill -0 "$MOCK_PID" 2>/dev/null; then
    kill "$MOCK_PID" 2>/dev/null || true
    wait "$MOCK_PID" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

REAL_GIT="$(command -v git)"
REAL_CURL="$(command -v curl)"

# ---------------------------------------------------------------- git half ---
# A `git` shim records the argv of the real work verb and, from inside that same
# process, asks the real git what the config machinery resolved. That second
# read is the delivery half: it sees GIT_CONFIG_* the way git-remote-http does.
mkdir -p "$tmp/shim"
cat > "$tmp/shim/git" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    rev-parse|remote) exec "$REAL_GIT" "\$@" ;;
  esac
done
printf '%s\n' "\$@" > "$tmp/git-argv.txt"
"$REAL_GIT" config --get-all 'http.http://localhost:3300/.extraHeader' > "$tmp/git-resolved.txt" 2>/dev/null || true
"$REAL_GIT" config --get-all 'http.http://127.0.0.1:3300/.extraHeader' >> "$tmp/git-resolved.txt" 2>/dev/null || true
exit 0
SHIM
chmod +x "$tmp/shim/git"

repo="$tmp/repo"
mkdir -p "$repo"
"$REAL_GIT" -C "$repo" init -q
"$REAL_GIT" -C "$repo" remote add origin http://localhost:3300/EdgeVector/probe.git

env -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0 \
  PATH="$tmp/shim:$PATH" FORGE_TOKEN="$TOKEN" \
  "$ROOT/bin/last-stack-forge-git" -C "$repo" ls-remote origin main >/dev/null 2>&1 \
  || fail "last-stack-forge-git exited non-zero against the shim"

[ -f "$tmp/git-argv.txt" ] || fail "the git shim never ran"
if grep -qF "$TOKEN" "$tmp/git-argv.txt"; then
  fail "last-stack-forge-git put the token on git argv: $(cat "$tmp/git-argv.txt")"
fi
grep -qF "ls-remote" "$tmp/git-argv.txt" || fail "git argv lost the caller's verb"
grep -qF "Authorization: token $TOKEN" "$tmp/git-resolved.txt" \
  || fail "git resolved no extraHeader for the forge base: $(cat "$tmp/git-resolved.txt")"
[ "$(grep -c "Authorization: token $TOKEN" "$tmp/git-resolved.txt")" -eq 2 ] \
  || fail "both localhost and 127.0.0.1 spellings must carry the header"

# An outer GIT_CONFIG_COUNT must survive: last-stack-portal-wt exports two entries
# of its own and then calls other forge helpers.
env PATH="$tmp/shim:$PATH" FORGE_TOKEN="$TOKEN" \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=outer-probe \
  bash -c '. "'"$ROOT"'/lib/forge-token.sh" && last_stack_forge_export_git_config && '"$REAL_GIT"' config --get user.name' \
  > "$tmp/outer.txt" 2>/dev/null || fail "export helper failed with an outer GIT_CONFIG_COUNT"
grep -qx 'outer-probe' "$tmp/outer.txt" \
  || fail "the export helper clobbered a caller's GIT_CONFIG entry: $(cat "$tmp/outer.txt")"

# --------------------------------------------------------------- curl half ---
# Mock forge: records every Authorization header it is given.
python3 - "$tmp/port.txt" "$tmp/seen.txt" <<'PY' >"$tmp/mock.log" 2>&1 &
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
port_file, seen_file = sys.argv[1], sys.argv[2]

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        with open(seen_file, "a") as fh:
            fh.write((self.headers.get("Authorization") or "NONE") + "\n")
        body = b'{"ok":true}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

srv = HTTPServer(("127.0.0.1", 0), H)
with open(port_file, "w") as fh:
    fh.write(str(srv.server_address[1]))
srv.serve_forever()
PY
MOCK_PID=$!

for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -s "$tmp/port.txt" ] && break
  sleep 0.2
done
[ -s "$tmp/port.txt" ] || fail "mock forge never reported a port: $(cat "$tmp/mock.log" 2>/dev/null)"
PORT="$(cat "$tmp/port.txt")"

cat > "$tmp/shim/curl" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$tmp/curl-argv.txt"
exec "$REAL_CURL" "\$@"
SHIM
chmod +x "$tmp/shim/curl"

env PATH="$tmp/shim:$PATH" FORGE_TOKEN="$TOKEN" FORGE_ROOT="http://127.0.0.1:$PORT" \
  "$ROOT/bin/last-stack-forge-api" repos/EdgeVector/probe/pulls >/dev/null 2>&1 \
  || fail "last-stack-forge-api exited non-zero against the mock forge"

[ -f "$tmp/curl-argv.txt" ] || fail "the curl shim never ran"
if grep -qF "$TOKEN" "$tmp/curl-argv.txt"; then
  fail "last-stack-forge-api put the token on curl argv: $(cat "$tmp/curl-argv.txt")"
fi
# The mock records the header VALUE, so the expected text is "token <t>".
grep -qFx "token $TOKEN" "$tmp/seen.txt" \
  || fail "the mock forge saw no token header: $(cat "$tmp/seen.txt" 2>/dev/null)"

# The config file carries the secret, so it must not be group/other readable, and
# it must not survive the call.
auth_file="$(grep -A1 -x -- '-K' "$tmp/curl-argv.txt" | tail -1)"
[ -n "$auth_file" ] || fail "curl argv carried no -K config file: $(cat "$tmp/curl-argv.txt")"
[ ! -e "$auth_file" ] || fail "the auth config file outlived the call: $auth_file"

perm="$(env FORGE_TOKEN="$TOKEN" bash -c '
  . "'"$ROOT"'/lib/forge-token.sh"
  f="$(last_stack_forge_curl_auth_config)"
  stat -f "%Lp" "$f"
  rm -rf "$(dirname "$f")"')"
[ "$perm" = "600" ] || fail "auth config file mode is $perm, expected 600"

echo "ok forge-token-not-on-argv: git argv clean + header resolved, curl argv clean + header delivered"
