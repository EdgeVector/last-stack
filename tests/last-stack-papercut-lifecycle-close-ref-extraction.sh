#!/usr/bin/env bash
# Compound regression: review-ref extraction must never feed punctuated,
# invented, or prose-scraped tokens into a live `lastgit cr view` / forge API
# call. Ground truth: papercut-lifecycle-close-misparses-review-refs (six
# reconciler passes, 2026-08-26 .. 2026-08-30, ~13-16 errors every run).
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
    "slug": "papercut-lifecycle-ref-punctuation-semicolon",
    "title": "Labeled CR ref terminated by a semicolon",
    "status": "open",
    "body": "Status: OPEN\nRepo: EdgeVector/last-stack\nFixed by: lastgit://last-stack/cr/cr-mt1t6wpi-33a6;\n"
  },
  {
    "slug": "papercut-lifecycle-ref-punctuation-period",
    "title": "Labeled CR ref ending a sentence",
    "status": "open",
    "body": "Status: OPEN\nRepo: EdgeVector/last-stack\nFixed by: lastgit://last-stack/cr/cr-mt33r3h2-5b5b.\n"
  },
  {
    "slug": "papercut-lifecycle-ref-punctuation-backtick",
    "title": "Labeled CR ref wrapped in backticks",
    "status": "open",
    "body": "Status: OPEN\nRepo: EdgeVector/fold\nFixed by: `lastgit://fold/cr/cr-mrxxzsay-bbf3`\n"
  },
  {
    "slug": "papercut-pipeline-stuck-forge-fold-pr-826",
    "title": "Pipeline: fold Forgejo PR 826 red required CI",
    "status": "open",
    "body": "Status: OPEN\nSeverity: P0\nRepo: EdgeVector/fold\nPR: Forgejo #826\n"
  },
  {
    "slug": "papercut-pipeline-stuck-forge-lastgit-pr-90",
    "title": "Pipeline: lastgit Forgejo PR 90 merge endpoint blocked",
    "status": "open",
    "body": "Status: OPEN\nSeverity: P0\nRepo: EdgeVector/lastgit\nPR: Forgejo #90\n"
  },
  {
    "slug": "papercut-lifecycle-ref-prose-mention",
    "title": "Body merely mentions somebody else's CR id",
    "status": "open",
    "body": "Status: OPEN\nRepo: EdgeVector/last-stack\n\n## Symptom\nThe reconciler read cr-ms7sdfqg-16b8 out of this record's prose and treated it\nas this papercut's own review ref.\n"
  },
  {
    "slug": "papercut-pipeline-stuck-forge-mystery-service-pr-7",
    "title": "Stuck forge PR with no Repo header to anchor the repo name",
    "status": "open",
    "body": "Status: OPEN\nSeverity: P0\nPR: Forgejo #7\n"
  }
]
JSON

bin_dir="$tmp/bin"
mkdir -p "$bin_dir"

export LASTGIT_CALL_LOG="$tmp/lastgit-calls.log"
export FORGE_CALL_LOG="$tmp/forge-calls.log"
: >"$LASTGIT_CALL_LOG"
: >"$FORGE_CALL_LOG"

# Only real, unpunctuated CR ids resolve. Everything else fails the way the
# live `lastgit cr view` fails today, so a regression is red, not silent.
cat >"$bin_dir/lastgit" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
repo="$3"
cr_id="$4"
printf '%s %s\n' "$repo" "$cr_id" >>"$LASTGIT_CALL_LOG"
case "$repo/$cr_id" in
  last-stack/cr-mt1t6wpi-33a6|last-stack/cr-mt33r3h2-5b5b|fold/cr-mrxxzsay-bbf3)
    printf '{"cr_id":"%s","repo":"%s","state":"merged","merge_oid":"deadbee"}\n' "$cr_id" "$repo"
    ;;
  *)
    echo "cr not found: $repo/$cr_id" >&2
    exit 1
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
  repos/EdgeVector/fold/pulls/826)
    printf '{"state":"open","merged":false}\n'
    ;;
  repos/EdgeVector/lastgit/pulls/90)
    printf '{"state":"closed","merged":true}\n'
    ;;
  *)
    echo "404 Not Found: $route" >&2
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
errors = data.get("errors") or []
assert not errors, f"self-inflicted parse errors survived: {errors}"
assert data["checked"] == 7, data["checked"]

fixed = {item["slug"]: item["ref"] for item in data["fixed"]}
assert fixed == {
    "papercut-lifecycle-ref-punctuation-semicolon": "lastgit://last-stack/cr/cr-mt1t6wpi-33a6",
    "papercut-lifecycle-ref-punctuation-period": "lastgit://last-stack/cr/cr-mt33r3h2-5b5b",
    "papercut-lifecycle-ref-punctuation-backtick": "lastgit://fold/cr/cr-mrxxzsay-bbf3",
    "papercut-pipeline-stuck-forge-lastgit-pr-90": "EdgeVector/lastgit/pulls/90",
}, fixed

skipped = {item["slug"]: item for item in data["skipped"]}
assert skipped["papercut-pipeline-stuck-forge-fold-pr-826"]["reason"] == "review-not-merged"
assert skipped["papercut-lifecycle-ref-prose-mention"]["reason"] == "no-review-ref"
unmapped = skipped["papercut-pipeline-stuck-forge-mystery-service-pr-7"]
assert unmapped["reason"] == "unresolved-review-ref", unmapped
assert unmapped["details"] == ["unmapped-forge-repo:mystery-service"], unmapped
PY

# No punctuated, invented, or prose-scraped token may ever reach a live venue.
for forbidden in 'cr-mt1t6wpi-33a6;' 'cr-mt33r3h2-5b5b.' 'cr-mrxxzsay-bbf3`' 'cr-ms7sdfqg-16b8'; do
  if grep -qF -- "$forbidden" "$LASTGIT_CALL_LOG"; then
    echo "lastgit was called with a misparsed ref: $forbidden" >&2
    exit 1
  fi
done
for forbidden in 'fold-pr' 'lastgit-pr' 'mystery-service-pr'; do
  if grep -qF -- "$forbidden" "$FORGE_CALL_LOG"; then
    echo "forge API was called with an invented repo: $forbidden" >&2
    exit 1
  fi
done
grep -qx 'repos/EdgeVector/fold/pulls/826' "$FORGE_CALL_LOG"
grep -qx 'repos/EdgeVector/lastgit/pulls/90' "$FORGE_CALL_LOG"

printf 'ok last-stack-papercut-lifecycle-close-ref-extraction\n'
