#!/usr/bin/env bash
# Every socket call the lastdb-safe-upgrade skill makes must self-identify with
# X-LastDB-Client (2026-08-30). Unlabelled curl traffic lands in the
# client=unknown row of `lastdb ops`, so a slow or chatty upgrade probe cannot
# be attributed to this skill. Static check: no node round-trip required.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
SCRIPTS="$ROOT/skills/lastdb-safe-upgrade/scripts"

[ -d "$SCRIPTS" ] || { echo "FAIL: missing $SCRIPTS" >&2; exit 1; }

python3 - "$SCRIPTS" <<'PY'
import io, os, sys

scripts = sys.argv[1]
bad = []
checked = 0

for name in sorted(os.listdir(scripts)):
    if not name.endswith(".sh"):
        continue
    path = os.path.join(scripts, name)
    with io.open(path, encoding="utf-8") as fh:
        raw = fh.readlines()
    # Join backslash continuations so a header on the next physical line still
    # counts as part of the same curl command.
    joined = []          # (first_line_number, logical_line)
    buf = ""
    start = 0
    for n, line in enumerate(raw, 1):
        if not buf:
            start = n
        stripped = line.rstrip("\n")
        if stripped.endswith("\\"):
            buf += stripped[:-1] + " "
            continue
        buf += stripped
        joined.append((start, buf))
        buf = ""
    if buf:
        joined.append((start, buf))

    for n, line in joined:
        if "--unix-socket" not in line:
            continue
        checked += 1
        if "X-LastDB-Client" not in line:
            bad.append("%s:%d: %s" % (name, n, line.strip()[:120]))

if checked == 0:
    print("FAIL: found no --unix-socket call sites; the check is not looking at anything", file=sys.stderr)
    sys.exit(1)
if bad:
    print("FAIL: socket calls without X-LastDB-Client:", file=sys.stderr)
    for entry in bad:
        print("  " + entry, file=sys.stderr)
    sys.exit(1)
print("ok: %d --unix-socket call sites all send X-LastDB-Client" % checked)
PY

echo "PASS: lastdb-safe-upgrade socket calls self-identify"
