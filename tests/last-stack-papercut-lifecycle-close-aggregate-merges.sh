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
export GH_CALL_LOG="$tmp/gh-calls.log"
export GH_DEFAULT_CALL_LOG="$tmp/gh-default-calls.log"
: >"$LASTGIT_CALL_LOG"
: >"$FORGE_CALL_LOG"
: >"$GH_CALL_LOG"
: >"$GH_DEFAULT_CALL_LOG"

# LastGit is retired: any call is a regression. A CR id named in prose is still
# parsed, but it resolves to no venue, so it never closes and never blocks.
cat >"$bin_dir/lastgit" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LASTGIT_CALL_LOG"
exit 1
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

# A missing explicit mock must refuse locally, before any network call.
cat >"$bin_dir/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_DEFAULT_CALL_LOG"
echo "default gh must not be called by this fixture" >&2
exit 2
SH
chmod +x "$bin_dir/gh"

cat >"$bin_dir/gh-repair-search" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
expected='search prs papercut-pipeline-stuck-merges-canonical-record-unbounded-growth --owner EdgeVector --merged --limit 10 --json number,repository,url,body'
printf '%s\n' "$*" >>"$GH_CALL_LOG"
if [ "$*" != "$expected" ]; then
  echo "unexpected fixture GitHub call: $*" >&2
  exit 2
fi
printf '[]\n'
SH
chmod +x "$bin_dir/gh-repair-search"

command_rc=0
PATH="$bin_dir:$PATH" "$ROOT/bin/last-stack-papercut-lifecycle-close" \
  --records-json "$tmp/records.json" \
  --forge-api-bin "$bin_dir/forge-api" \
  --brain-bin "$bin_dir/brain" \
  --gh-bin "$bin_dir/gh-repair-search" \
  --dry-run \
  --json >"$tmp/result.json" 2>"$tmp/result.err" || command_rc=$?
if [ "$command_rc" -ne 0 ]; then
  echo "FAIL: aggregate GH dependency command failed rc=$command_rc" >&2
  cat "$tmp/result.json" >&2
  cat "$tmp/result.err" >&2
  exit "$command_rc"
fi

expected_gh='search prs papercut-pipeline-stuck-merges-canonical-record-unbounded-growth --owner EdgeVector --merged --limit 10 --json number,repository,url,body'
if [ -s "$GH_DEFAULT_CALL_LOG" ] || [ "$(cat "$GH_CALL_LOG")" != "$expected_gh" ]; then
  echo "FAIL: aggregate GH dependency must use only the exact growth search" >&2
  cat "$GH_CALL_LOG" >&2
  cat "$GH_DEFAULT_CALL_LOG" >&2
  exit 1
fi

python3 - "$tmp/result.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
assert not data.get("errors"), data["errors"]
assert data["checked"] == 5, data["checked"]

fixed = {item["slug"]: item for item in data["fixed"]}
unmerged = {item["slug"]: item for item in data["closed_unmerged"]}
skipped = {item["slug"]: item for item in data["skipped"]}

# Rows whose reviews are only LastGit CRs have no readable review left: they
# stay open with `no-review-ref`, never fixed and never wontfix.
for retired in (
    "papercut-pipeline-stuck-merges-fkanban-20260830t0916z",
    "papercut-pipeline-stuck-merges-loom-20260901t2104z",
    "papercut-pipeline-stuck-merges-last-stack-20260904t03",
):
    assert retired not in fixed and retired not in unmerged, retired
    assert skipped[retired]["reason"] == "no-review-ref", skipped[retired]

fold = unmerged["papercut-pipeline-stuck-merges-fold"]
assert sorted(fold["aggregate_refs"]) == [
    "forge:EdgeVector/fold#1801=merged",
    "forge:EdgeVector/fold#1869=merged",
    "forge:EdgeVector/fold#1870=closed",
], fold

# The slug tail is not this record's repo, so the row is not a stuck-review
# roll-up at all. It claims a brain record grows unboundedly; the PR numbers in
# its prose belong to the record it is complaining about.
growth = skipped["papercut-pipeline-stuck-merges-canonical-record-unbounded-growth"]
assert growth["reason"] == "no-review-ref", growth
PY

# LastGit is retired: no CR id, in prose, a wikilink or a slug, may reach it.
if [ -s "$LASTGIT_CALL_LOG" ]; then
  echo "lastgit was called although it is retired:" >&2
  cat "$LASTGIT_CALL_LOG" >&2
  exit 1
fi

# `lastgit#507` inside a fold row is lastgit's PR 507, not fold's.
if grep -qF -- 'pulls/507' "$FORGE_CALL_LOG"; then
  echo "a foreign repo's qualified PR number was called against this row's repo" >&2
  exit 1
fi

# Its prose PR numbers must not become Forge reads. The explicit empty GitHub
# repair search above preserves the ordinary discovery path for this record.
for forbidden in 'pulls/1902' 'pulls/1903'; do
  if grep -qF -- "$forbidden" "$FORGE_CALL_LOG"; then
    echo "a non-review row was resolved against the forge: $forbidden" >&2
    exit 1
  fi
done

echo "ok $(basename "$0" .sh)"
