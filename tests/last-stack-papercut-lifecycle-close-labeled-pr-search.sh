#!/usr/bin/env bash
# A papercut that names no review closes only when a MERGED forge PR carries
# the exact slug on a labeled repair line (`Papercut:`, `Fixes:`, ...).
# Ground truth: papercut-card-merge-does-not-close-its-named-papercuts-20260926
# (13 papercuts open after their fix merged). Negative cases keep
# papercut-lifecycle-closer-treats-incident-pr-as-fix-20260925 closed: a prose
# mention, an unmerged PR, and a longer slug that shares a prefix never close.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/records.json" <<'JSON'
[
  {"slug": "papercut-labeled-fix", "title": "Labeled line in a merged PR", "status": "open",
   "body": "Status: OPEN\nRepo: EdgeVector/last-stack\n"},
  {"slug": "papercut-prose-only", "title": "Named only in prose", "status": "open",
   "body": "Status: OPEN\nRepo: EdgeVector/last-stack\n"},
  {"slug": "papercut-unmerged-fix", "title": "Labeled line, PR not merged", "status": "open",
   "body": "Status: OPEN\nRepo: EdgeVector/last-stack\n"},
  {"slug": "papercut-prefix", "title": "Only a longer slug is labeled", "status": "open",
   "body": "Status: OPEN\nRepo: EdgeVector/last-stack\n"},
  {"slug": "papercut-search-down", "title": "Search fails", "status": "open",
   "body": "Status: OPEN\nRepo: EdgeVector/last-stack\n"}
]
JSON

bin_dir="$tmp/bin"
mkdir -p "$bin_dir"
export FORGE_CALL_LOG="$tmp/forge-calls.log"
: >"$FORGE_CALL_LOG"

cat >"$bin_dir/forge-api" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
route="$1"
printf '%s\n' "$route" >>"$FORGE_CALL_LOG"
pr() {  # repo number merged body
  printf '{"number":%s,"title":"t","html_url":"http://forge.test/EdgeVector/%s/pulls/%s","body":"%s","repository":{"full_name":"EdgeVector/%s"},"pull_request":{"merged":%s}}' \
    "$2" "$1" "$2" "$4" "$1" "$3"
}
case "$route" in
  "repos/issues/search?q=papercut-labeled-fix&"*)
    printf '['; pr last-stack 11 true 'GOAL\n\n- Papercut: papercut-labeled-fix\n'; printf ']\n' ;;
  "repos/issues/search?q=papercut-prose-only&"*)
    printf '['; pr fold 12 true 'Evidence: papercut-prose-only shows the same shape.'; printf ']\n' ;;
  "repos/issues/search?q=papercut-unmerged-fix&"*)
    printf '['; pr last-stack 13 false 'Papercut: papercut-unmerged-fix'; printf ']\n' ;;
  "repos/issues/search?q=papercut-prefix&"*)
    printf '['; pr last-stack 14 true 'Papercut: papercut-prefix-longer'; printf ']\n' ;;
  repos/EdgeVector/last-stack/pulls/11)
    printf '{"state":"closed","merged":true}\n' ;;
  *)
    echo "404 Not Found: $route" >&2
    exit 1 ;;
esac
SH
chmod +x "$bin_dir/forge-api"
cat >"$bin_dir/brain" <<'SH'
#!/usr/bin/env bash
echo "brain must not be called on the dry-run records-json path: $*" >&2
exit 2
SH
chmod +x "$bin_dir/brain"

run_closer() {
  PATH="$bin_dir:$PATH" "$ROOT/bin/last-stack-papercut-lifecycle-close" \
    --records-json "$tmp/records.json" --forge-api-bin "$bin_dir/forge-api" \
    --brain-bin "$bin_dir/brain" --lastgit-bin /usr/bin/false --dry-run --json "$@"
}

run_closer >"$tmp/result.json"
python3 - "$tmp/result.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert not data.get("errors"), data.get("errors")
fixed = {f["slug"]: f for f in data["fixed"]}
assert set(fixed) == {"papercut-labeled-fix"}, sorted(fixed)
f = fixed["papercut-labeled-fix"]
assert f["ref"] == "http://forge.test/EdgeVector/last-stack/pulls/11", f
assert "labeled repair line" in f["detail"], f
skips = {s["slug"]: s for s in data["skipped"] if s.get("slug")}
for slug in ("papercut-prose-only", "papercut-unmerged-fix", "papercut-prefix", "papercut-search-down"):
    assert skips[slug]["reason"] == "no-review-ref", (slug, skips.get(slug))
assert "forge_search_error" in skips["papercut-search-down"], skips["papercut-search-down"]
PY

# --no-forge-search restores the old behaviour: no search call, nothing closes.
: >"$FORGE_CALL_LOG"
run_closer --no-forge-search >"$tmp/off.json"
python3 - "$tmp/off.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert not data["fixed"], data["fixed"]
PY
if grep -q 'issues/search' "$FORGE_CALL_LOG"; then
  echo "FAIL: --no-forge-search still searched" >&2
  exit 1
fi

echo "ok: lifecycle closer closes on a labeled repair line in a merged PR, never on prose, unmerged, or prefix matches"
