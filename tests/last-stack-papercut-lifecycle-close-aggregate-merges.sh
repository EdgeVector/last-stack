#!/usr/bin/env bash
# An aggregate `papercut-pipeline-stuck-merges-<repo>` row names its reviews in
# prose, several of them, across weeks of per-wake appends. It closes only when
# EVERY named review is terminal, and only when the slug says the row is about
# that repo's reviews at all.
#
# Ground truth: papercut-lifecycle-close-misparses-review-refs. Measured on the
# primary 2026-09-04 over the 12 open `-merges-` rows: main resolved 2 (both by
# closing on the FIRST terminal ref of a 49-ref row), the change resolved 11 and
# left the twelfth — a claim about brain-record growth, not about any review —
# untouched.
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
    "slug": "papercut-pipeline-stuck-merges-loom-20260901t2104z",
    "title": "Pipeline: Loom CI remains pending on an open merge",
    "status": "open",
    "extra_fields": {"repo": "EdgeVector/loom"},
    "body": "Status: OPEN\nSeverity: P0\nSymptom: LastGit Loom CR remains open with ci-required pending\n\nLastGit CR cr-mtj3svjt-c8ef has auto-merge=true.\n\nCompared against and judged distinct from: [[papercut-pipeline-stuck-cr-brain-cr-mszzzzzz-9999]].\n\n## Recurrence\nCR cr-mtjezzzy-0e8d remains open after 15 minutes. See papercut-pipeline-stuck-cr-fold-cr-msyyyyyy-8888 for the sibling.\n"
  },
  {
    "slug": "papercut-pipeline-stuck-merges-fkanban-20260830t0916z",
    "title": "Pipeline: fkanban CR stuck, body also quotes a last-stack CR",
    "status": "open",
    "extra_fields": {"repo": "EdgeVector/fkanban"},
    "body": "Status: OPEN\nSeverity: P1\n\nCR cr-mtkam5ht-752c (fkanban) is stuck. The same pass also retriggered\ncr-mtfj1j5s-d442, which lives in last-stack, not here.\n"
  },
  {
    "slug": "papercut-pipeline-stuck-merges-fold",
    "title": "Pipeline: Fold PRs stuck",
    "status": "open",
    "extra_fields": {"repo": "EdgeVector/fold"},
    "body": "Status: OPEN\nSeverity: P0\n\nSymptom: Fold PR 1801 is red on required CI.\n\n2026-09-01T20:05Z: Fold PRs #1869 and #1870 remain open.\n\nNo empty-commit this wake (heavy unit was lastgit#507). No force-merge occurred.\n"
  },
  {
    "slug": "papercut-pipeline-stuck-merges-last-stack-20260904t03",
    "title": "Pipeline: last-stack merges blocked, one CR still live",
    "status": "open",
    "extra_fields": {"repo": "EdgeVector/last-stack"},
    "body": "Status: OPEN\nSeverity: P0\n\ncr-mtmmb1wa-aeda merged earlier this pass.\n\n## Recurrence\ncr-mtmn3fqi-1624 is still open on the same base.\n"
  },
  {
    "slug": "papercut-pipeline-stuck-merges-canonical-record-unbounded-growth",
    "title": "The canonical stuck-merge record grows past the get window",
    "status": "open",
    "extra_fields": {"repo": "EdgeVector/fold"},
    "body": "Status: OPEN\nSeverity: P2\n\nSymptom: the canonical dedupe target grew past the ~40K brain-get window.\nIt was filed for PR 1801 and now also carries 1902 and 1903 evidence.\n"
  }
]
JSON

bin_dir="$tmp/bin"
mkdir -p "$bin_dir"

export LASTGIT_CALL_LOG="$tmp/lastgit-calls.log"
export FORGE_CALL_LOG="$tmp/forge-calls.log"
: >"$LASTGIT_CALL_LOG"
: >"$FORGE_CALL_LOG"

# `lastgit cr view` on another repo's CR id exits 0 and streams `cr_not_found`.
# The stub reproduces that exactly, because "the venue does not have this
# review" is what tells the closer a prose token is somebody else's CR.
cat >"$bin_dir/lastgit" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
repo="$3"
cr_id="$4"
printf '%s %s\n' "$repo" "$cr_id" >>"$LASTGIT_CALL_LOG"
case "$repo/$cr_id" in
  loom/cr-mtj3svjt-c8ef|fkanban/cr-mtkam5ht-752c|last-stack/cr-mtmmb1wa-aeda)
    printf '{"cr_id":"%s","repo":"%s","state":"merged","merge_oid":"deadbee"}\n' "$cr_id" "$repo"
    ;;
  loom/cr-mtjezzzy-0e8d)
    printf '{"cr_id":"%s","repo":"%s","state":"closed","merge_oid":""}\n' "$cr_id" "$repo"
    ;;
  last-stack/cr-mtmn3fqi-1624)
    printf '{"cr_id":"%s","repo":"%s","state":"open","merge_oid":""}\n' "$cr_id" "$repo"
    ;;
  *)
    printf '{"ts":"2026-09-04T09:28:49.070Z","error":"cr_not_found: %s does not exist on %s.","event":"verb_timing","verb":"cr.view","duration_ms":1,"ok":false}\n' "$cr_id" "$repo"
    ;;
esac
SH
chmod +x "$bin_dir/lastgit"

cat >"$bin_dir/forge-api" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
route="$1"
printf '%s\n' "$route" >>"$FORGE_CALL_LOG"
case "$route" in
  repos/EdgeVector/fold/pulls/1801|repos/EdgeVector/fold/pulls/1869)
    printf '{"state":"closed","merged":true}\n'
    ;;
  repos/EdgeVector/fold/pulls/1870)
    printf '{"state":"closed","merged":false}\n'
    ;;
  *)
    echo "last-stack-forge-api: HTTP 404 GET $route" >&2
    exit 1
    ;;
esac
SH
chmod +x "$bin_dir/forge-api"

cat >"$bin_dir/brain" <<'SH'
#!/usr/bin/env bash
echo "brain must not be called on the dry-run records-json path: $*" >&2
exit 2
SH
chmod +x "$bin_dir/brain"

PATH="$bin_dir:$PATH" "$ROOT/bin/last-stack-papercut-lifecycle-close" \
  --records-json "$tmp/records.json" \
  --lastgit-bin "$bin_dir/lastgit" \
  --forge-api-bin "$bin_dir/forge-api" \
  --brain-bin "$bin_dir/brain" \
  --dry-run \
  --json >"$tmp/result.json"

python3 - "$tmp/result.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
assert not data.get("errors"), data["errors"]
assert data["checked"] == 5, data["checked"]

fixed = {item["slug"]: item for item in data["fixed"]}
unmerged = {item["slug"]: item for item in data["closed_unmerged"]}
skipped = {item["slug"]: item for item in data["skipped"]}

# Every named review merged -> `fixed`, and the payload names the whole set.
# The last-stack CR quoted in this fkanban row is not fkanban's, so the venue's
# `cr_not_found` drops it instead of blocking the close forever.
fkanban = fixed["papercut-pipeline-stuck-merges-fkanban-20260830t0916z"]
assert fkanban["aggregate_refs"] == ["lastgit:fkanban/cr-mtkam5ht-752c=merged"], fkanban

# One review merged and one closed without merging: the set is terminal, so the
# stuck claim is resolved, but no fix can be cited. `wontfix`, not `fixed`.
loom = unmerged["papercut-pipeline-stuck-merges-loom-20260901t2104z"]
assert loom["review_state"] == "closed", loom
assert sorted(loom["aggregate_refs"]) == [
    "lastgit:loom/cr-mtj3svjt-c8ef=merged",
    "lastgit:loom/cr-mtjezzzy-0e8d=closed",
], loom

fold = unmerged["papercut-pipeline-stuck-merges-fold"]
assert sorted(fold["aggregate_refs"]) == [
    "forge:EdgeVector/fold#1801=merged",
    "forge:EdgeVector/fold#1869=merged",
    "forge:EdgeVector/fold#1870=closed",
], fold

# ONE live review keeps the whole row open. main closed a 49-ref row on the
# first terminal ref it happened to reach.
live = skipped["papercut-pipeline-stuck-merges-last-stack-20260904t03"]
assert live["reason"] == "aggregate-review-open", live

# The slug tail is not this record's repo, so the row is not a stuck-review
# roll-up at all. It claims a brain record grows unboundedly; the PR numbers in
# its prose belong to the record it is complaining about.
growth = skipped["papercut-pipeline-stuck-merges-canonical-record-unbounded-growth"]
assert growth["reason"] == "no-review-ref", growth
PY

# A `[[wikilink]]` and a `papercut-…` slug carry another record's review ids.
for forbidden in 'cr-mszzzzzz-9999' 'cr-msyyyyyy-8888'; do
  if grep -qF -- "$forbidden" "$LASTGIT_CALL_LOG"; then
    echo "a review id belonging to another record reached lastgit: $forbidden" >&2
    exit 1
  fi
done

# `lastgit#507` inside a fold row is lastgit's PR 507, not fold's.
if grep -qF -- 'pulls/507' "$FORGE_CALL_LOG"; then
  echo "a foreign repo's qualified PR number was called against this row's repo" >&2
  exit 1
fi

# The row that is not a stuck-review roll-up must cost no venue call at all.
for forbidden in 'pulls/1902' 'pulls/1903'; do
  if grep -qF -- "$forbidden" "$FORGE_CALL_LOG"; then
    echo "a non-review row was resolved against the forge: $forbidden" >&2
    exit 1
  fi
done

echo "ok $(basename "$0" .sh)"
