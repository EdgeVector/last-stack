#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

home="$tmp/home/.lastdb"
link_dir="$tmp/home/.local/bin"
bin_dir="$tmp/bin-with-upload-cap"
plist="$tmp/com.tomtang.lastdbd-primary.plist"
mkdir -p "$home" "$link_dir" "$bin_dir"
resolved_bin_dir="$(cd "$bin_dir" && pwd -P)"

for tool in lastdb lastdbd; do
  cat >"$bin_dir/$tool" <<'EOF'
#!/bin/sh
case "$1" in
  --version) echo "$0 0.test" ;;
esac
EOF
  chmod +x "$bin_dir/$tool"
done

python3 - "$plist" "$bin_dir" <<'PY'
import plistlib
import sys

plist, bin_dir = sys.argv[1:3]
data = {
    "Label": "com.tomtang.lastdbd-primary",
    "ProgramArguments": [f"{bin_dir}/lastdbd"],
    "EnvironmentVariables": {
        "PATH": f"{bin_dir}:/opt/homebrew/bin:/usr/bin:/bin",
        "LASTDB_HOME": "/tmp/unused",
    },
}
with open(plist, "wb") as f:
    plistlib.dump(data, f)
PY

"$ROOT/bin/last-stack-lastdb-current" set \
  --lastdb-home "$home" \
  --bin-dir "$bin_dir" \
  --link-dir "$link_dir" \
  --launch-agent-plist "$plist"

test "$(readlink "$home/current")" = "$resolved_bin_dir"
test "$(readlink "$link_dir/lastdb")" = "$home/current/lastdb"
test "$(readlink "$link_dir/lastdbd")" = "$home/current/lastdbd"
test "$(readlink "$link_dir/folddb")" = "$home/current/lastdb"
test -f "$plist.bak-lastdb-current-"*

PATH="$link_dir:/usr/bin:/bin" "$ROOT/bin/last-stack-lastdb-current" check \
  --lastdb-home "$home" \
  --bin-dir "$bin_dir" \
  --link-dir "$link_dir" \
  --verbose

python3 - "$plist" "$home" <<'PY'
import plistlib
import sys

plist, home = sys.argv[1:3]
with open(plist, "rb") as f:
    data = plistlib.load(f)
assert data["ProgramArguments"][0] == f"{home}/current/lastdbd"
path = data["EnvironmentVariables"]["PATH"].split(":")
assert path[0] == f"{home}/current"
assert not any(p.endswith("/bin-with-upload-cap") for p in path)
PY

bad_link_dir="$tmp/bad-link-dir"
mkdir -p "$bad_link_dir"
touch "$bad_link_dir/lastdb"

if "$ROOT/bin/last-stack-lastdb-current" set \
  --lastdb-home "$home" \
  --bin-dir "$bin_dir" \
  --link-dir "$bad_link_dir" >/dev/null 2>"$tmp/fail.err"; then
  echo "expected non-symlink refusal to fail" >&2
  exit 1
fi
grep -q 'refusing to replace non-symlink path' "$tmp/fail.err"

echo "ok"
