#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

cat >"$tmp/records.json" <<'JSON'
[
  {
    "slug": "papercut-pipeline-stuck-cr-last-stack-merged",
    "title": "Merged stuck CR",
    "body": "Status: OPEN\nEvidence: lastgit://last-stack/cr/cr-merged"
  },
  {
    "slug": "papercut-pipeline-stuck-cr-last-stack-open",
    "title": "Open stuck CR",
    "body": "Status: OPEN\nEvidence: lastgit://last-stack/cr/cr-open"
  },
  {
    "slug": "papercut-pipeline-stuck-cr-last-stack-fixed",
    "title": "Already fixed",
    "body": "Status: OPEN\nStatus: FIXED (2026-08-01T00:00:00Z)\nEvidence: lastgit://last-stack/cr/cr-merged"
  }
]
JSON

bin_dir="$tmp/bin"
mkdir -p "$bin_dir"
cat >"$bin_dir/brain" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = append ]; then
  slug="$2"
  cat >>"$BRAIN_APPEND_LOG"
  printf 'APPEND %s\n' "$slug" >>"$BRAIN_APPEND_LOG"
  exit 0
fi
echo "unexpected brain args: $*" >&2
exit 2
SH
chmod +x "$bin_dir/brain"

cat >"$bin_dir/lastgit" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cr_id="$4"
printf '{"event":"verb_timing","verb":"schema.ensure","duration_ms":1}\n'
case "$cr_id" in
  cr-merged)
    cat <<'JSON'
{
  "cr_id": "cr-merged",
  "repo": "last-stack",
  "state": "merged",
  "merge_oid": "abc123"
}
JSON
    ;;
  cr-open)
    cat <<'JSON'
{
  "cr_id": "cr-open",
  "repo": "last-stack",
  "state": "open",
  "merge_oid": ""
}
JSON
    ;;
  *)
    echo "unknown cr $cr_id" >&2
    exit 1
    ;;
esac
printf '{"event":"verb_timing","verb":"cr.view","duration_ms":2}\n'
SH
chmod +x "$bin_dir/lastgit"

export BRAIN_APPEND_LOG="$tmp/appends.log"
: >"$BRAIN_APPEND_LOG"

PATH="$bin_dir:$PATH" "$ROOT/bin/last-stack-papercut-lifecycle-close" \
  --records-json "$tmp/records.json" \
  --dry-run \
  --json >"$tmp/dry.json"
python3 - "$tmp/dry.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["checked"] == 3
assert [item["slug"] for item in data["fixed"]] == ["papercut-pipeline-stuck-cr-last-stack-merged"]
assert any(item["reason"] == "not-open" for item in data["skipped"])
PY
[ ! -s "$BRAIN_APPEND_LOG" ] || {
  echo "dry-run wrote to brain" >&2
  exit 1
}

PATH="$bin_dir:$PATH" "$ROOT/bin/last-stack-papercut-lifecycle-close" \
  --records-json "$tmp/records.json" \
  --json >"$tmp/live.json"
grep -q 'Status: FIXED' "$BRAIN_APPEND_LOG"
grep -q 'Lifecycle-Closer: last-stack-papercut-lifecycle-close' "$BRAIN_APPEND_LOG"
grep -q 'papercut-pipeline-stuck-cr-last-stack-merged -> card:none | pattern:lifecycle-auto-close | skip:fixed:lastgit:last-stack/cr-merged' "$BRAIN_APPEND_LOG"
if grep -q 'papercut-pipeline-stuck-cr-last-stack-open -> card:none' "$BRAIN_APPEND_LOG"; then
  echo "open CR was marked fixed" >&2
  exit 1
fi

printf 'ok last-stack-papercut-lifecycle-close\n'
