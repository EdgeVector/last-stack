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
   "body": "Status: OPEN\nRepo: EdgeVector/last-stack\n"},
  {"slug": "papercut-cited-as-context", "title": "A bare Papercut: line IS the hand-written repair convention", "status": "open",
   "body": "Status: OPEN\nRepo: EdgeVector/last-stack\n"},
  {"slug": "papercut-keeps-itself-open", "title": "Record asserts it must stay open", "status": "open",
   "body": "Status: OPEN\nRepo: EdgeVector/last-stack\nThe delivered half is done. Residual claim 1 is unchanged and is why this record stays open.\n"},
  {"slug": "papercut-keep-open-structured", "title": "Record uses the structured marker", "status": "open",
   "body": "Status: OPEN\nRepo: EdgeVector/last-stack\nKeep-open: only the instrument shipped; the titled claim stands\n"},
  {"slug": "papercut-describes-staying-open", "title": "Its DEFECT is about things staying open", "status": "open",
   "body": "Status: OPEN\nRepo: EdgeVector/last-stack\nSymptom: papercuts stay open after the card that names them merges; the closer skips no-review-ref.\n"},
  {"slug": "papercut-verb-no-card", "title": "A repair VERB needs no card markers", "status": "open",
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
  # The shape that closed a live claim: a hand-written PR body whose ONLY
  # reference to the record is a `Papercut:` trailer, with no card markers. The
  # body even says it is additive, exactly as EdgeVector/last-stack#255 did.
  "repos/issues/search?q=papercut-cited-as-context&"*)
    printf '['; pr last-stack 15 true 'Additive on purpose; this corrects the prescription in\nPapercut: papercut-cited-as-context'; printf ']\n' ;;
  # A repair VERB closes with no card markers anywhere in the body.
  "repos/issues/search?q=papercut-verb-no-card&"*)
    printf '['; pr last-stack 16 true 'Fixes: papercut-verb-no-card'; printf ']\n' ;;
  # Both keep-open records are named by a merged PR on a labeled line. Nothing
  # about the PR is wrong; the RECORD says it must stay open.
  "repos/issues/search?q=papercut-keeps-itself-open&"*)
    printf '['; pr last-stack 17 true 'Papercut: papercut-keeps-itself-open'; printf ']\n' ;;
  "repos/issues/search?q=papercut-keep-open-structured&"*)
    printf '['; pr last-stack 18 true 'Papercut: papercut-keep-open-structured'; printf ']\n' ;;
  "repos/issues/search?q=papercut-describes-staying-open&"*)
    printf '['; pr last-stack 19 true 'Papercut: papercut-describes-staying-open'; printf ']\n' ;;
  repos/EdgeVector/last-stack/pulls/11|repos/EdgeVector/last-stack/pulls/15|repos/EdgeVector/last-stack/pulls/16|repos/EdgeVector/last-stack/pulls/17|repos/EdgeVector/last-stack/pulls/18|repos/EdgeVector/last-stack/pulls/19)
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
# A bare `Papercut:` line closes (it is the hand-written repair convention:
# 7 of 7 merged PRs carrying one carry no card marker), and so does `Fixes:`.
# The two keep-open records are named by merged PRs on labeled lines and must
# still NOT close, because the record is the authority on its own claim.
assert set(fixed) == {
    "papercut-labeled-fix",
    "papercut-verb-no-card",
    "papercut-cited-as-context",
    # Describing a defect about things staying open is NOT asserting that THIS
    # record stays open. The prose arm demands a self-reference for exactly this
    # row, which is real corpus text.
    "papercut-describes-staying-open",
}, sorted(fixed)
keep = {s["slug"]: s for s in data["skipped"] if s.get("slug")}
for slug in ("papercut-keeps-itself-open", "papercut-keep-open-structured"):
    assert keep[slug]["reason"] == "keep-open-asserted", (slug, keep.get(slug))
    assert keep[slug].get("marker"), (slug, keep[slug])
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

# --ignore-keep-open is the operator override, and it must close BOTH keep-open
# records while changing nothing else.
run_closer --ignore-keep-open >"$tmp/override.json"
python3 - "$tmp/override.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
fixed = {f["slug"] for f in data["fixed"]}
assert {"papercut-keeps-itself-open", "papercut-keep-open-structured"} <= fixed, sorted(fixed)
PY

echo "ok: lifecycle closer closes on a labeled repair line in a merged PR, never on prose, unmerged, or prefix matches, and never against a record that asserts it must stay open"
