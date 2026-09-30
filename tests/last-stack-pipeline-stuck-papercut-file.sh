#!/usr/bin/env bash
# The stuck-CR filer is a retired LastGit door: every id is skipped, nothing is
# written to the brain, and the old argument contract still exits 0.
set -euo pipefail
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"
tool="$ROOT/bin/last-stack-pipeline-stuck-papercut-file"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/stuck-file.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# A brain stub that records any call: the filer must never call it.
cat >"$tmp/brain" <<SH
#!/bin/sh
echo "\$@" >>"$tmp/brain.calls"
exit 9
SH
chmod +x "$tmp/brain"

for id in cr-abc123 forgejo-pr-132 '#44' 7; do
  rc=0
  "$tool" --repo EdgeVector/fold --cr-id "$id" --evidence "reason=x" \
    --root-cause-slug papercut-pipeline-stuck-merges-fold --brain-bin "$tmp/brain" --json \
    >"$tmp/out.json" 2>"$tmp/out.err" || rc=$?
  [ "$rc" -eq 0 ] || { echo "cr id $id: rc=$rc" >&2; cat "$tmp/out.err" >&2; exit 1; }
  jq -e '.ok == true and .action == "skip-lastgit-retired"' "$tmp/out.json" >/dev/null \
    || { echo "cr id $id: not skipped" >&2; cat "$tmp/out.json" >&2; exit 1; }
done
[ ! -e "$tmp/brain.calls" ] || { echo "the retired filer called the brain" >&2; cat "$tmp/brain.calls" >&2; exit 1; }
# Text mode and dry-run keep exit 0 too.
"$tool" --repo fold --cr-id cr-1 --evidence e --dry-run >"$tmp/out.txt"
grep -q skip-lastgit-retired "$tmp/out.txt"
# The required flags stay required (contract).
if "$tool" --repo fold >/dev/null 2>&1; then echo "missing --cr-id must fail" >&2; exit 1; fi
echo "ok last-stack-pipeline-stuck-papercut-file"
