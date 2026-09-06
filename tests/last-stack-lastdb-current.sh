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
plist="$tmp/com.REPLACE.lastdbd-primary.plist"
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
    "Label": "com.REPLACE.lastdbd-primary",
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
  --launch-agent-plist "$plist" \
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

python3 - "$plist" "$bin_dir" <<'PY'
import plistlib
import sys

plist, bin_dir = sys.argv[1:3]
with open(plist, "rb") as f:
    data = plistlib.load(f)
data["ProgramArguments"][0] = f"{bin_dir}/lastdbd"
with open(plist, "wb") as f:
    plistlib.dump(data, f)
PY

if PATH="$link_dir:/usr/bin:/bin" "$ROOT/bin/last-stack-lastdb-current" check \
  --lastdb-home "$home" \
  --bin-dir "$bin_dir" \
  --link-dir "$link_dir" \
  --launch-agent-plist "$plist" >"$tmp/plist-check.out" 2>"$tmp/plist-check.err"; then
  echo "expected non-canonical launch agent path to fail" >&2
  exit 1
fi
grep -q 'ProgramArguments\[0\].*expected.*current/lastdbd' "$tmp/plist-check.err"

# A `current` dir holding two binaries from different builds must FAIL the
# check. This is the property the command's own description claims ("verify the
# shell-visible CLI and daemon binary agree") and could not assert: on
# 2026-08-01 the primary ran a CLI and a daemon 170 commits apart in one
# `current` dir and `check --verbose` printed five oks and exited 0. The
# versions used below are that incident's, so this test fails the exact tree
# the old check passed.
skew_home="$tmp/skew/.lastdb"
skew_link_dir="$tmp/skew/.local/bin"
skew_bin_dir="$tmp/skew/bin-skewed"
mkdir -p "$skew_home" "$skew_link_dir" "$skew_bin_dir"
printf '#!/bin/sh\necho "lastdbd 0.23.3-235-g4f5476498"\n' >"$skew_bin_dir/lastdbd"
printf '#!/bin/sh\necho "lastdb 0.23.2-65-g9934ab89e"\n' >"$skew_bin_dir/lastdb"
chmod +x "$skew_bin_dir/lastdbd" "$skew_bin_dir/lastdb"

"$ROOT/bin/last-stack-lastdb-current" set \
  --lastdb-home "$skew_home" \
  --bin-dir "$skew_bin_dir" \
  --link-dir "$skew_link_dir" >/dev/null

if PATH="$skew_link_dir:/usr/bin:/bin" "$ROOT/bin/last-stack-lastdb-current" check \
  --lastdb-home "$skew_home" \
  --bin-dir "$skew_bin_dir" \
  --link-dir "$skew_link_dir" >"$tmp/skew.out" 2>"$tmp/skew.err"; then
  echo "expected a version skew inside current to fail the check" >&2
  exit 1
fi
# The message must name BOTH versions. An operator who is told only "skew" has
# to go and run the two --version calls the check just ran.
grep -q 'version skew inside current' "$tmp/skew.err"
grep -q '0.23.3-235-g4f5476498' "$tmp/skew.err"
grep -q '0.23.2-65-g9934ab89e' "$tmp/skew.err"

# A binary that is present but not runnable is still caught, and is reported as
# an executability failure rather than as a skew — the `cp -a` codesigning
# brick this command has always caught must not be re-labelled by this change.
brick_home="$tmp/brick/.lastdb"
brick_link_dir="$tmp/brick/.local/bin"
brick_bin_dir="$tmp/brick/bin-bricked"
mkdir -p "$brick_home" "$brick_link_dir" "$brick_bin_dir"
printf '#!/bin/sh\necho "lastdbd 0.test"\n' >"$brick_bin_dir/lastdbd"
printf '#!/bin/sh\nexit 9\n' >"$brick_bin_dir/lastdb"
chmod +x "$brick_bin_dir/lastdbd" "$brick_bin_dir/lastdb"

"$ROOT/bin/last-stack-lastdb-current" set \
  --lastdb-home "$brick_home" \
  --bin-dir "$brick_bin_dir" \
  --link-dir "$brick_link_dir" >/dev/null

if PATH="$brick_link_dir:/usr/bin:/bin" "$ROOT/bin/last-stack-lastdb-current" check \
  --lastdb-home "$brick_home" \
  --bin-dir "$brick_bin_dir" \
  --link-dir "$brick_link_dir" >"$tmp/brick.out" 2>"$tmp/brick.err"; then
  echo "expected an unrunnable binary in current to fail the check" >&2
  exit 1
fi
grep -q 'not runnable' "$tmp/brick.err"

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
