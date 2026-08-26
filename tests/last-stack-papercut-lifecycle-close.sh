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
if [ "${1:-}" = papercut ] && [ "${2:-}" = close ]; then
  printf 'CLOSE %s\n' "$*" >>"$BRAIN_APPEND_LOG"
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
grep -q '^CLOSE papercut close papercut-pipeline-stuck-cr-last-stack-merged --status fixed ' "$BRAIN_APPEND_LOG"
if grep -q '^Status: FIXED' "$BRAIN_APPEND_LOG"; then
  echo "untyped records-json path appended Status: FIXED" >&2
  exit 1
fi
grep -q 'papercut-pipeline-stuck-cr-last-stack-merged -> card:none | pattern:lifecycle-auto-close | skip:fixed:lastgit:last-stack/cr-merged' "$BRAIN_APPEND_LOG"
if grep -q 'papercut-pipeline-stuck-cr-last-stack-open -> card:none' "$BRAIN_APPEND_LOG"; then
  echo "open CR was marked fixed" >&2
  exit 1
fi

# Typed path: lifecycle transitions through `brain papercut close`, never a
# prose Status append. This is the production path after the queue migration.
cat >"$bin_dir/typed-brain" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "get papercut-pipeline-stuck-cr-last-stack-typed --type papercut --json")
    printf '%s\n' '{"slug":"papercut-pipeline-stuck-cr-last-stack-typed","title":"Typed merged CR","body":"Evidence: lastgit://last-stack/cr/cr-merged","status":"open"}'
    ;;
  papercut\ close\ papercut-pipeline-stuck-cr-last-stack-typed*)
    printf 'CLOSE %s\n' "$*" >>"$BRAIN_TYPED_LOG"
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

# Slug-derived LastGit ref: pipeline-stuck bodies often name cr-<id> without a
# lastgit:// URL. The closer must still point-get the CR from the slug.
cat >"$bin_dir/slug-brain" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "get papercut-pipeline-stuck-cr-last-stack-cr-msfkhqbn --type papercut --json")
    printf '%s\n' '{"slug":"papercut-pipeline-stuck-cr-last-stack-cr-msfkhqbn","title":"Merged canary CR","body":"Repo: EdgeVector/last-stack\nLastGit CR cr-msfkhqbn-e1a2 merged.","status":"open"}'
    ;;
  papercut\ close\ papercut-pipeline-stuck-cr-last-stack-cr-msfkhqbn*)
    printf 'CLOSE %s\n' "$*" >>"$BRAIN_SLUG_LOG"
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
cat >"$bin_dir/slug-lastgit" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cr_id="$4"
printf '{"event":"verb_timing","verb":"schema.ensure","duration_ms":1}\n'
case "$cr_id" in
  cr-msfkhqbn-e1a2)
    printf '%s\n' '{"cr_id":"cr-msfkhqbn-e1a2","repo":"last-stack","state":"merged","merge_oid":"1c6e688"}'
    ;;
  *)
    echo "unexpected cr $cr_id" >&2
    exit 1
    ;;
esac
SH
chmod +x "$bin_dir/slug-lastgit"
export BRAIN_SLUG_LOG="$tmp/slug.log"
: >"$BRAIN_SLUG_LOG"
PATH="$bin_dir:$PATH" "$ROOT/bin/last-stack-papercut-lifecycle-close" \
  papercut-pipeline-stuck-cr-last-stack-cr-msfkhqbn \
  --brain-bin "$bin_dir/slug-brain" \
  --lastgit-bin "$bin_dir/slug-lastgit" \
  --json >"$tmp/slug.json"
jq -e '.checked == 1 and (.fixed | length) == 1 and (.errors | length) == 0' "$tmp/slug.json" >/dev/null
grep -q '^CLOSE papercut close papercut-pipeline-stuck-cr-last-stack-cr-msfkhqbn --status fixed ' "$BRAIN_SLUG_LOG"

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
  "papercut list --status open --json")
    printf '%s\n' '{"rows":[{"slug":"papercut-unrelated-open","status":"open"},{"slug":"papercut-pipeline-stuck-cr-last-stack-cr-msfkhqbn","status":"open"}],"total":2,"method":"method: status-keyed papercut index (canary)"}'
    ;;
  "get papercut-pipeline-stuck-cr-last-stack-cr-msfkhqbn --type papercut --json")
    printf '%s\n' '{"slug":"papercut-pipeline-stuck-cr-last-stack-cr-msfkhqbn","title":"Merged canary CR","body":"Repo: EdgeVector/last-stack\nLastGit CR cr-msfkhqbn-e1a2 merged.","status":"open"}'
    ;;
  "get papercut-unrelated-open --type papercut --json")
    printf '%s\n' '{"slug":"papercut-unrelated-open","title":"No review ref","body":"Status: OPEN","status":"open"}'
    ;;
  papercut\ close\ papercut-pipeline-stuck-cr-last-stack-cr-msfkhqbn*)
    printf 'CLOSE %s\n' "$*" >>"$BRAIN_DEFAULT_LOG"
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
  --lastgit-bin "$bin_dir/slug-lastgit" \
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
assert refs and refs[0]["slug"] == "papercut-pipeline-stuck-cr-last-stack-cr-msfkhqbn"
PY
grep -q '^CLOSE papercut close papercut-pipeline-stuck-cr-last-stack-cr-msfkhqbn --status fixed ' "$BRAIN_DEFAULT_LOG"

printf 'ok last-stack-papercut-lifecycle-close\n'
