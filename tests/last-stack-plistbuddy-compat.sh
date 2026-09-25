#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tool="$ROOT/tests/ci/plistbuddy-compat.py"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
plist="$tmp/test.plist"

python3 - "$plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "wb") as destination:
    plistlib.dump({"Label": "test", "ProgramArguments": ["bash", "run"], "EnvironmentVariables": {}}, destination)
PY

[ "$(python3 "$tool" -c 'Print :ProgramArguments:1' "$plist")" = run ]
python3 "$tool" -c 'Add :EnvironmentVariables:MODE string test' "$plist"
[ "$(python3 "$tool" -c 'Print :EnvironmentVariables:MODE' "$plist")" = test ]
python3 "$tool" -c 'Set :EnvironmentVariables:MODE verified' "$plist"
[ "$(python3 "$tool" -c 'Print :EnvironmentVariables:MODE' "$plist")" = verified ]

echo "ok last-stack-plistbuddy-compat"
