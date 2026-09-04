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
  },
  {
    "slug": "papercut-pipeline-stuck-forge-fold-pr1018",
    "title": "Pipeline: fold Forgejo PR 1018 stuck (no dash before the number)",
    "status": "open",
    "body": "Status: OPEN\nSeverity: P0\nRepo: EdgeVector/fold\nPR: Forgejo #1018\n"
  },
  {
    "slug": "papercut-pipeline-stuck-cr-last-stack-cr-msc85npn-c483",
    "title": "Pipeline: last-stack CR id carrying its disambiguator suffix",
    "status": "open",
    "body": "Status: OPEN\nSeverity: P0\nRepo: EdgeVector/last-stack\n"
  },
  {
    "slug": "papercut-pipeline-stuck-cr-fold-1709",
    "title": "Pipeline: a fold forge PR filed under the -cr- prefix",
    "status": "open",
    "body": "Symptom: Fold PR 1709 has a stale red required Forge CI check\n\nchecked_at=2026-08-22T19:07:24Z; repo=EdgeVector/fold; PR=1709; head=ec4fd4fc\n"
  },
  {
    "slug": "papercut-pipeline-stuck-cr-last-stack-msh21rhh",
    "title": "Pipeline: CR short id with no -cr- separator, corroborated by the body",
    "status": "open",
    "body": "Status: OPEN\nSeverity: P0\nRepo: EdgeVector/last-stack\n\n## Symptom\ncr-msh21rhh-c064 open >10m with ci-required failure.\n"
  },
  {
    "slug": "papercut-pipeline-stuck-cr-last-stack-notacrid",
    "title": "Pipeline: slug tail that is not a CR id and nothing corroborates it",
    "status": "open",
    "body": "Status: OPEN\nSeverity: P0\nRepo: EdgeVector/last-stack\n\n## Symptom\nThe rebase target was cr-mt1t6wpi-33a6, which is somebody else's CR.\n"
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
  last-stack/cr-mt1t6wpi-33a6|last-stack/cr-mt33r3h2-5b5b|fold/cr-mrxxzsay-bbf3|last-stack/cr-msc85npn-c483|last-stack/cr-msh21rhh-c064)
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
  repos/EdgeVector/lastgit/pulls/90|repos/EdgeVector/fold/pulls/1018|repos/EdgeVector/fold/pulls/1709)
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
assert data["checked"] == 12, data["checked"]

fixed = {item["slug"]: item["ref"] for item in data["fixed"]}
assert fixed == {
    "papercut-lifecycle-ref-punctuation-semicolon": "lastgit://last-stack/cr/cr-mt1t6wpi-33a6",
    "papercut-lifecycle-ref-punctuation-period": "lastgit://last-stack/cr/cr-mt33r3h2-5b5b",
    "papercut-lifecycle-ref-punctuation-backtick": "lastgit://fold/cr/cr-mrxxzsay-bbf3",
    "papercut-pipeline-stuck-forge-lastgit-pr-90": "EdgeVector/lastgit/pulls/90",
    # `-pr1018`, not `-pr-1018`: the spelling `pipeline-health` actually writes
    # 21 times in the ledger, and the one no fixture covered until 2026-09-04.
    "papercut-pipeline-stuck-forge-fold-pr1018": "EdgeVector/fold/pulls/1018",
    # A CR id keeps its `-<disambiguator>` suffix.
    "papercut-pipeline-stuck-cr-last-stack-cr-msc85npn-c483": "lastgit://last-stack/cr/cr-msc85npn-c483",
    # A forge PR filed under the `-cr-` prefix resolves at the forge, not LastGit.
    "papercut-pipeline-stuck-cr-fold-1709": "EdgeVector/fold/pulls/1709",
    # A CR short id with no `-cr-` separator, taken only because the body
    # carries the matching full id.
    "papercut-pipeline-stuck-cr-last-stack-msh21rhh": "lastgit://last-stack/cr/cr-msh21rhh-c064",
}, fixed

skipped = {item["slug"]: item for item in data["skipped"]}
# fold#826 is still OPEN, so the row stays open and the reason says which of the
# two non-merged states it is. `review-not-merged` used to conflate "still open"
# with "closed and never coming back"; only the second is terminal.
assert skipped["papercut-pipeline-stuck-forge-fold-pr-826"]["reason"] == "review-still-open"
assert skipped["papercut-lifecycle-ref-prose-mention"]["reason"] == "no-review-ref"
unmapped = skipped["papercut-pipeline-stuck-forge-mystery-service-pr-7"]
assert unmapped["reason"] == "unresolved-review-ref", unmapped
assert unmapped["details"] == ["unmapped-forge-repo:mystery-service"], unmapped

# A slug tail that merely LOOKS like a CR short id is not one. Nothing in the
# body corroborates it, so no ref is invented and no venue is called.
# The body names an unrelated CR. Corroboration means the body carries THIS
# slug's id, not merely some id — without that check the extractor would file
# a close against another record's review.
uncorroborated = skipped["papercut-pipeline-stuck-cr-last-stack-notacrid"]
assert uncorroborated["reason"] == "unresolved-review-ref", uncorroborated
assert uncorroborated["details"] == [
    "uncorroborated-stuck-cr-slug:papercut-pipeline-stuck-cr-last-stack-notacrid"
], uncorroborated
PY

# No punctuated, invented, or prose-scraped token may ever reach a live venue.
for forbidden in 'cr-mt1t6wpi-33a6;' 'cr-mt33r3h2-5b5b.' 'cr-mrxxzsay-bbf3`' 'cr-ms7sdfqg-16b8' 'cr-notacrid' 'cr-1709'; do
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
grep -qx 'repos/EdgeVector/fold/pulls/1018' "$FORGE_CALL_LOG"
grep -qx 'repos/EdgeVector/fold/pulls/1709' "$FORGE_CALL_LOG"

printf 'ok last-stack-papercut-lifecycle-close-ref-extraction\n'
