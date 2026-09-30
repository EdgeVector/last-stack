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
    "title": "Merged stuck PR",
    "body": "Status: OPEN\nEvidence: https://github.com/EdgeVector/last-stack/pull/101"
  },
  {
    "slug": "papercut-pipeline-stuck-cr-last-stack-open",
    "title": "Open stuck PR",
    "body": "Status: OPEN\nEvidence: https://github.com/EdgeVector/last-stack/pull/102"
  },
  {
    "slug": "papercut-pipeline-stuck-cr-last-stack-fixed",
    "title": "Already fixed",
    "body": "Status: OPEN\nStatus: FIXED (2026-08-01T00:00:00Z)\nEvidence: https://github.com/EdgeVector/last-stack/pull/101"
  }
]
JSON

bin_dir="$tmp/bin"
mkdir -p "$bin_dir"
cat >"$bin_dir/brain" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = papercut ] && [ "${2:-}" = close ]; then
  printf 'CLOSE %s\n' "$*" >>"$BRAIN_APPEND_LOG"
  exit 0
fi
if [ "$1" = get ] && [ "${3:-}" = --type ] && [ "${4:-}" = reference ]; then
  printf '{"slug":"%s","body":""}\n' "$2"
  exit 0
fi
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

cat >"$bin_dir/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# gh pr view <n> -R <owner/repo> --json state,mergedAt
[ "${1:-}" = pr ] && [ "${2:-}" = view ] || { echo "unexpected gh args: $*" >&2; exit 2; }
case "$3" in
  101)
    printf '%s\n' '{"state":"MERGED","mergedAt":"2026-09-30T00:00:00Z"}'
    ;;
  102)
    printf '%s\n' '{"state":"OPEN","mergedAt":null}'
    ;;
  *)
    echo "unknown pr $3" >&2
    exit 1
    ;;
esac
SH
chmod +x "$bin_dir/gh"

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
grep -q '^CLOSE papercut close papercut-pipeline-stuck-cr-last-stack-merged --status fixed ' "$BRAIN_APPEND_LOG"
if grep -q '^Status: FIXED' "$BRAIN_APPEND_LOG"; then
  echo "untyped records-json path appended Status: FIXED" >&2
  exit 1
fi
grep -q 'papercut-pipeline-stuck-cr-last-stack-merged -> card:none | pattern:lifecycle-auto-close | skip:fixed:github:EdgeVector/last-stack#101' "$BRAIN_APPEND_LOG"
if grep -q 'papercut-pipeline-stuck-cr-last-stack-open -> card:none' "$BRAIN_APPEND_LOG"; then
  echo "open PR was marked fixed" >&2
  exit 1
fi

# Typed path: lifecycle transitions through `brain papercut close`, never a
# prose Status append. This is the production path after the queue migration.
cat >"$bin_dir/typed-brain" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "get papercut-pipeline-stuck-cr-last-stack-typed --type papercut --json")
    printf '%s\n' '{"slug":"papercut-pipeline-stuck-cr-last-stack-typed","title":"Typed merged PR","body":"Evidence: https://github.com/EdgeVector/last-stack/pull/101","status":"open"}'
    ;;
  papercut\ close\ papercut-pipeline-stuck-cr-last-stack-typed*)
    printf 'CLOSE %s\n' "$*" >>"$BRAIN_TYPED_LOG"
    ;;
  "get papercut-reconciler-ledger --type reference --json")
    printf '{"slug":"papercut-reconciler-ledger","body":""}\n'
    ;;
  "append papercut-reconciler-ledger --type reference")
    cat >>"$BRAIN_TYPED_LOG"
    ;;
  *)
    echo "unexpected typed brain args: $*" >&2
    exit 2
    ;;
esac
SH
chmod +x "$bin_dir/typed-brain"
export BRAIN_TYPED_LOG="$tmp/typed.log"
: >"$BRAIN_TYPED_LOG"
PATH="$bin_dir:$PATH" "$ROOT/bin/last-stack-papercut-lifecycle-close" \
  papercut-pipeline-stuck-cr-last-stack-typed \
  --brain-bin "$bin_dir/typed-brain" --json >"$tmp/typed.json"
jq -e '.checked == 1 and (.fixed | length) == 1 and (.errors | length) == 0' "$tmp/typed.json" >/dev/null
grep -q '^CLOSE papercut close papercut-pipeline-stuck-cr-last-stack-typed --status fixed ' "$BRAIN_TYPED_LOG"
if grep -q '^Status: FIXED' "$BRAIN_TYPED_LOG"; then
  echo "typed record was closed by prose append" >&2
  exit 1
fi

# Slug-derived GitHub ref: pipeline-stuck bodies often name no URL. The closer
# must still read the PR from the slug (`stuck-pr-<repo>-<n>`).
cat >"$bin_dir/slug-brain" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "get papercut-pipeline-stuck-pr-last-stack-201 --type papercut --json")
    printf '%s\n' '{"slug":"papercut-pipeline-stuck-pr-last-stack-201","title":"Merged canary PR","body":"Repo: EdgeVector/last-stack\nPR 201 merged.","status":"open"}'
    ;;
  papercut\ close\ papercut-pipeline-stuck-pr-last-stack-201*)
    printf 'CLOSE %s\n' "$*" >>"$BRAIN_SLUG_LOG"
    ;;
  "get papercut-reconciler-ledger --type reference --json")
    printf '{"slug":"papercut-reconciler-ledger","body":""}\n'
    ;;
  "append papercut-reconciler-ledger --type reference")
    cat >>"$BRAIN_SLUG_LOG"
    ;;
  *)
    echo "unexpected slug brain args: $*" >&2
    exit 2
    ;;
esac
SH
chmod +x "$bin_dir/slug-brain"
cat >"$bin_dir/slug-gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# gh pr view <n> -R <owner/repo> --json state,mergedAt
[ "${1:-}" = pr ] && [ "${2:-}" = view ] || { echo "unexpected gh args: $*" >&2; exit 2; }
case "$3" in
  201)
    printf '%s\n' '{"state":"MERGED","mergedAt":"2026-09-30T00:00:00Z"}'
    ;;
  *)
    echo "unknown pr $3" >&2
    exit 1
    ;;
esac
SH
chmod +x "$bin_dir/slug-gh"
export BRAIN_SLUG_LOG="$tmp/slug.log"
: >"$BRAIN_SLUG_LOG"
PATH="$bin_dir:$PATH" "$ROOT/bin/last-stack-papercut-lifecycle-close" \
  papercut-pipeline-stuck-pr-last-stack-201 \
  --brain-bin "$bin_dir/slug-brain" \
  --gh-bin "$bin_dir/slug-gh" \
  --json >"$tmp/slug.json"
jq -e '.checked == 1 and (.fixed | length) == 1 and (.errors | length) == 0' "$tmp/slug.json" >/dev/null
grep -q '^CLOSE papercut close papercut-pipeline-stuck-pr-last-stack-201 --status fixed ' "$BRAIN_SLUG_LOG"

# Default path must NOT return after the prevention registry. A COVERED
# registry of 3 unreadable cards used to report scanned=3 and skip the
# pipeline-stuck open queue entirely.
cat >"$bin_dir/default-brain" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "get papercut-prevention-registry --type reference")
    cat <<'EOF'
### papercut-last-stack-self-upgrade-lock-stale-no-timeout
- Prevention: COVERED
- Card: `missing-card-a`
### papercut-kanban-stress-harness-milestone-gate
- Prevention: COVERED
- Card: `missing-card-b`
### papercut-lastdb-backup-retries-nontransient-quota-rejection-forever
- Prevention: COVERED
- Card: `missing-card-c`
EOF
    ;;
  "papercut list --status open --index-only --json"|"papercut list --status open --json")
    printf '%s\n' '{"rows":[{"slug":"papercut-unrelated-open","status":"open"},{"slug":"papercut-pipeline-stuck-pr-last-stack-201","status":"open"}],"total":2,"method":"method: status-keyed papercut index (canary)"}'
    ;;
  "get papercut-pipeline-stuck-pr-last-stack-201 --type papercut --json")
    printf '%s\n' '{"slug":"papercut-pipeline-stuck-pr-last-stack-201","title":"Merged canary PR","body":"Repo: EdgeVector/last-stack\nPR 201 merged.","status":"open"}'
    ;;
  "get papercut-unrelated-open --type papercut --json")
    printf '%s\n' '{"slug":"papercut-unrelated-open","title":"No review ref","body":"Status: OPEN","status":"open"}'
    ;;
  papercut\ close\ papercut-pipeline-stuck-pr-last-stack-201*)
    printf 'CLOSE %s\n' "$*" >>"$BRAIN_DEFAULT_LOG"
    ;;
  "get papercut-reconciler-ledger --type reference --json")
    printf '{"slug":"papercut-reconciler-ledger","body":""}\n'
    ;;
  "append papercut-reconciler-ledger --type reference")
    cat >>"$BRAIN_DEFAULT_LOG"
    ;;
  *)
    echo "unexpected default brain args: $*" >&2
    exit 2
    ;;
esac
SH
chmod +x "$bin_dir/default-brain"
cat >"$bin_dir/kanban" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "card missing" >&2
exit 1
SH
chmod +x "$bin_dir/kanban"
export BRAIN_DEFAULT_LOG="$tmp/default.log"
: >"$BRAIN_DEFAULT_LOG"
PATH="$bin_dir:$PATH" "$ROOT/bin/last-stack-papercut-lifecycle-close" \
  --limit 200 --json \
  --brain-bin "$bin_dir/default-brain" \
  --gh-bin "$bin_dir/slug-gh" \
  >"$tmp/default.json"
python3 - "$tmp/default.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["ok"] is True
assert data["registry_scanned"] == 3
assert data["pipeline_stuck_checked"] == 1
assert data["review_checked"] == 2
assert data["scanned"] == 5
assert data["fixed"] == 1
assert data["scanned"] != 3
refs = data.get("fixed_refs") or []
assert refs and refs[0]["slug"] == "papercut-pipeline-stuck-pr-last-stack-201"
PY
grep -q '^CLOSE papercut close papercut-pipeline-stuck-pr-last-stack-201 --status fixed ' "$BRAIN_DEFAULT_LOG"


# A CLOSED review is TERMINAL. A `pipeline-stuck` papercut claims "this review
# is stuck", so a review closed without merging resolves it -- as `wontfix`,
# never `fixed`. Every other papercut class claims "the fix is covered by this
# review", where a closed-unmerged review means the fix was ABANDONED and the
# record must stay open for a human. Measured 2026-09-04: 41 of 43 open p0
# pipeline-stuck rows named an already-closed review and could never close.
cat >"$bin_dir/terminal-brain" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "get papercut-pipeline-stuck-pr-last-stack-301 --type papercut --json")
    printf '%s\n' '{"slug":"papercut-pipeline-stuck-pr-last-stack-301","title":"Abandoned stuck PR","body":"Evidence: https://github.com/EdgeVector/last-stack/pull/301","status":"open"}'
    ;;
  "get papercut-last-stack-some-other-defect --type papercut --json")
    printf '%s\n' '{"slug":"papercut-last-stack-some-other-defect","title":"Fix cited an abandoned PR","body":"Fixed-by: https://github.com/EdgeVector/last-stack/pull/301","status":"open"}'
    ;;
  papercut\ close\ *)
    printf 'CLOSE %s\n' "$*" >>"$BRAIN_TERMINAL_LOG"
    ;;
  "get papercut-reconciler-ledger --type reference --json")
    printf '{"slug":"papercut-reconciler-ledger","body":""}\n'
    ;;
  "append papercut-reconciler-ledger --type reference")
    cat >>"$BRAIN_TERMINAL_LOG"
    ;;
  *)
    echo "unexpected terminal brain args: $*" >&2
    exit 2
    ;;
esac
SH
chmod +x "$bin_dir/terminal-brain"
cat >"$bin_dir/terminal-gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# gh pr view <n> -R <owner/repo> --json state,mergedAt
[ "${1:-}" = pr ] && [ "${2:-}" = view ] || { echo "unexpected gh args: $*" >&2; exit 2; }
case "$3" in
  301)
    printf '%s\n' '{"state":"CLOSED","mergedAt":null}'
    ;;
  *)
    echo "unknown pr $3" >&2
    exit 1
    ;;
esac
SH
chmod +x "$bin_dir/terminal-gh"
export BRAIN_TERMINAL_LOG="$tmp/terminal.log"
: >"$BRAIN_TERMINAL_LOG"
PATH="$bin_dir:$PATH" "$ROOT/bin/last-stack-papercut-lifecycle-close" \
  papercut-pipeline-stuck-pr-last-stack-301 \
  papercut-last-stack-some-other-defect \
  --brain-bin "$bin_dir/terminal-brain" \
  --gh-bin "$bin_dir/terminal-gh" \
  --json >"$tmp/terminal.json"
python3 - "$tmp/terminal.json" <<'TERMPY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["checked"] == 2, data
assert data["errors"] == [], data
# The stuck row closed on the abandoned review; nothing landed in `fixed`.
assert [item["slug"] for item in data["fixed"]] == [], data
closed = data.get("closed_unmerged") or []
assert [item["slug"] for item in closed] == [
    "papercut-pipeline-stuck-pr-last-stack-301"
], data
assert closed[0]["review_state"] == "closed", data
# The non-stuck row stayed open, with a reason that names WHY.
reasons = {
    item["slug"]: item["reason"] for item in data["skipped"] if isinstance(item, dict)
}
assert reasons.get("papercut-last-stack-some-other-defect") == "review-closed-not-merged", data
TERMPY
grep -q '^CLOSE papercut close papercut-pipeline-stuck-pr-last-stack-301 --status wontfix ' "$BRAIN_TERMINAL_LOG"
if grep -q 'papercut-last-stack-some-other-defect' "$BRAIN_TERMINAL_LOG"; then
  echo "a non-pipeline-stuck papercut was closed on an ABANDONED review" >&2
  exit 1
fi
if grep -q -- '--fixed-by' "$BRAIN_TERMINAL_LOG"; then
  echo "a wontfix close cited a fix that does not exist" >&2
  exit 1
fi

# A retired lastgit:// CR is unreadable: never fixed, never wontfix.
cat >"$tmp/retired.json" <<'JSON'
[{"slug":"papercut-pipeline-stuck-cr-last-stack-retired","title":"Old CR","body":"Status: OPEN\nEvidence: lastgit://last-stack/cr/cr-merged"}]
JSON
: >"$BRAIN_APPEND_LOG"
cat >"$bin_dir/lastgit" <<'SH'
#!/usr/bin/env bash
echo "lastgit must not be called" >&2
exit 1
SH
chmod +x "$bin_dir/lastgit"
PATH="$bin_dir:$PATH" "$ROOT/bin/last-stack-papercut-lifecycle-close" \
  --records-json "$tmp/retired.json" --json >"$tmp/retired-out.json"
jq -e '(.fixed | length) == 0 and ((.closed_unmerged // []) | length) == 0' "$tmp/retired-out.json" >/dev/null
[ ! -s "$BRAIN_APPEND_LOG" ] || { echo "a retired lastgit CR closed a papercut" >&2; cat "$BRAIN_APPEND_LOG" >&2; exit 1; }

printf 'ok last-stack-papercut-lifecycle-close\n'
