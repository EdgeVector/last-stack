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

cat > "$fake_home/.local/bin/fbrain" <<'EOF'
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
chmod +x "$fake_home/.local/bin/fbrain"

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

printf '%s\n' "$output" | grep -q '\*\*demo-project\*\*: 2 unresolved'
printf '%s\n' "$output" | grep -q 'First page error'
printf '%s\n' "$output" | grep -q 'Second page error'

echo "ok morning-sync usage-bugs paginates sentry issues"
