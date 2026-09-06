#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT
fake_home="$tmp/home"
mkdir -p "$fake_home/.local/bin"

cat > "$fake_home/.local/bin/security" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' fake-sentry-token
EOF
chmod +x "$fake_home/.local/bin/security"

cat > "$fake_home/.local/bin/brain" <<'EOF'
#!/usr/bin/env bash
cat <<'RECORD'
---
type: reference
slug: signal-sources
---
### sentry
- **scopes**: `edge-vector/demo-project`
RECORD
EOF
chmod +x "$fake_home/.local/bin/brain"

# usage-bugs.sh resolves its project list with `brain get signal-sources`. This
# fixture stubbed `fbrain`, the name the script used before the rename, so
# `brain` fell through the fake PATH to the operator's real ~/.local/bin/brain
# and this supposedly hermetic test read the LIVE primary node -- and on a
# runner with no brain at all it silently took the hard-coded fallback list, so
# the assertion below could never match. Pin the resolution rather than trusting
# the PATH order.
resolved_brain="$(HOME="$fake_home" PATH="$fake_home/.local/bin:$PATH" command -v brain || true)"
if [ "$resolved_brain" != "$fake_home/.local/bin/brain" ]; then
  echo "FAIL: brain resolves to '$resolved_brain', not the fixture stub;" \
       "this test would read the live primary node" >&2
  exit 1
fi

cat > "$fake_home/.local/bin/curl" <<'EOF'
#!/usr/bin/env bash
headers=""
body=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -D)
      headers="$2"
      shift 2
      ;;
    -o)
      body="$2"
      shift 2
      ;;
    -H|--max-time)
      shift 2
      ;;
    -s|-sS)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done

if [ -z "$headers" ] || [ -z "$body" ]; then
  echo "fake curl expected -D and -o" >&2
  exit 2
fi

if printf '%s\n' "$url" | grep -q 'cursor=page2'; then
  cat > "$headers" <<'HEADERS'
HTTP/2 200
Link: <https://sentry.io/api/0/projects/edge-vector/demo-project/issues/?query=is:unresolved&statsPeriod=14d&limit=100&cursor=done>; rel="next"; results="false"; cursor="done"
HEADERS
  cat > "$body" <<'JSON'
[{"id":"2","title":"Second page error","level":"error","count":"7","userCount":0,"firstSeen":"2026-07-22T00:00:00Z","lastSeen":"2026-07-22T00:00:00Z","permalink":"https://sentry.example/2"}]
JSON
else
  cat > "$headers" <<'HEADERS'
HTTP/2 200
Link: <https://sentry.io/api/0/projects/edge-vector/demo-project/issues/?query=is:unresolved&statsPeriod=14d&limit=100&cursor=page2>; rel="next"; results="true"; cursor="page2"
HEADERS
  cat > "$body" <<'JSON'
[{"id":"1","title":"First page error","level":"error","count":"3","userCount":0,"firstSeen":"2026-07-22T00:00:00Z","lastSeen":"2026-07-22T00:00:00Z","permalink":"https://sentry.example/1"}]
JSON
fi
EOF
chmod +x "$fake_home/.local/bin/curl"

output="$(HOME="$fake_home" PATH="$fake_home/.local/bin:$PATH" "$ROOT/skills/morning-sync/usage-bugs.sh" sentry)"

# Each expectation reports itself. These were bare `grep -q` lines under
# `set -e`: a miss aborted the script with rc=1 and NOTHING on stdout or
# stderr, so the failure could not be diagnosed without bash -x. That mute
# failure is why this file sat in tests/.ci-exempt instead of in the gate.
expect_output() {
  if ! printf '%s\n' "$output" | grep -q "$1"; then
    echo "FAIL: usage-bugs output does not match: $1" >&2
    echo "--- usage-bugs.sh sentry output ---" >&2
    printf '%s\n' "$output" >&2
    echo "--- end output ---" >&2
    exit 1
  fi
}

expect_output '\*\*demo-project\*\*: 2 unresolved'
expect_output 'First page error'
expect_output 'Second page error'

echo "ok morning-sync usage-bugs paginates sentry issues"
