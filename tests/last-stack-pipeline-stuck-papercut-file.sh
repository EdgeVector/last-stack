#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp "${TMPDIR:-${TMP:-${TEMP:-/tmp}}}/last-stack-pipeline-stuck.XXXXXX")"
rm -f "$tmp"
mkdir -p "$tmp"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

helper="$ROOT/bin/last-stack-pipeline-stuck-papercut-file"
closer="$ROOT/bin/last-stack-papercut-lifecycle-close"
queue="$ROOT/bin/last-stack-papercut-queue"
[ -x "$helper" ]
[ -x "$closer" ]
[ -x "$queue" ]

cat >"$tmp/brain" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
state="$BRAIN_STATE"
case "${1:-} ${2:-}" in
  "papercut file")
    slug="$3"
    jq --arg slug "$slug" \
      '. + [{slug:$slug,title:"stuck",status:"open",component:"pipeline",severity:"p0",kind:"specified-fix",body:"Evidence: lastgit://demo/cr/cr-aaa"}]' \
      "$state" >"$state.tmp"
    mv "$state.tmp" "$state"
    printf 'filed %s\n' "$slug"
    ;;
  "papercut list")
    rows="$(jq -c '[.[] | select(.status == "open")]' "$state")"
    total="$(printf '%s' "$rows" | jq 'length')"
    jq -cn --argjson rows "$rows" --argjson total "$total" \
      '{rows:$rows,total:$total,method:"method: status-keyed papercut index (canary)"}'
    ;;
  "papercut close")
    slug="$3"
    jq --arg slug "$slug" 'map(if .slug == $slug then .status = "fixed" else . end)' \
      "$state" >"$state.tmp"
    mv "$state.tmp" "$state"
    printf 'CLOSE %s\n' "$*" >>"$BRAIN_CLOSE_LOG"
    ;;
  "get "*)
    slug="$2"
    rec="$(jq -c --arg slug "$slug" '.[] | select(.slug == $slug)' "$state")"
    if [ -z "$rec" ]; then
      echo "missing $slug" >&2
      exit 1
    fi
    printf '%s\n' "$rec"
    ;;
  "append "*)
    slug="$2"
    body="$(cat)"
    jq --arg slug "$slug" --arg body "$body" \
      'map(if .slug == $slug then .body = (.body + "\n" + $body) else . end)' \
      "$state" >"$state.tmp"
    mv "$state.tmp" "$state"
    printf 'APPEND %s\n' "$slug" >>"$BRAIN_APPEND_LOG"
    printf '%s\n' "$body" >>"$BRAIN_APPEND_LOG"
    ;;
  *)
    echo "unexpected brain args: $*" >&2
    exit 2
    ;;
esac
SH
chmod +x "$tmp/brain"

cat >"$tmp/lastgit" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cr_id="${4:-}"
case "$cr_id" in
  cr-aaa|cr-bbb)
    printf '{"cr_id":"%s","repo":"demo","state":"merged","merge_oid":"abc123"}\n' "$cr_id"
    ;;
  *)
    echo "unknown cr $cr_id" >&2
    exit 1
    ;;
esac
SH
chmod +x "$tmp/lastgit"

export BRAIN_STATE="$tmp/brain-state.json"
export BRAIN_CLOSE_LOG="$tmp/close.log"
export BRAIN_APPEND_LOG="$tmp/append.log"
printf '[]\n' >"$BRAIN_STATE"
: >"$BRAIN_CLOSE_LOG"
: >"$BRAIN_APPEND_LOG"

root="papercut-lastgit-forge-primary-down"
first="$("$helper" --brain-bin "$tmp/brain" --json \
  --repo demo --cr-id cr-aaa --root-cause-slug "$root" \
  --evidence "first stuck CR cr-aaa")"
printf '%s\n' "$first" | jq -e --arg slug "$root" \
  '.ok and .action == "file" and .slug == $slug' >/dev/null

second="$("$helper" --brain-bin "$tmp/brain" --json \
  --repo demo --cr-id cr-bbb --root-cause-slug "$root" \
  --evidence "second stuck CR cr-bbb")"
printf '%s\n' "$second" | jq -e --arg slug "$root" \
  '.ok and .action == "append" and .slug == $slug' >/dev/null

# Per-CR slug is rewritten to the stable merges slug when filing a new root.
per_cr="$("$helper" --brain-bin "$tmp/brain" --json \
  --repo other --cr-id cr-zzz \
  --root-cause-slug papercut-pipeline-stuck-cr-other-cr-zzz \
  --evidence "must not mint per-CR")"
printf '%s\n' "$per_cr" | jq -e \
  '.ok and .action == "file" and .slug == "papercut-pipeline-stuck-merges-other"' >/dev/null

snapshot="$tmp/open.json"
"$queue" snapshot --brain-bin "$tmp/brain" --output "$snapshot" --json \
  | jq -e '.ok and .discovered == 2' >/dev/null
jq -e --arg root "$root" \
  'any(.rows[].slug; . == $root)
   and all(.rows[].slug; startswith("papercut-pipeline-stuck-cr-") | not)' \
  "$snapshot" >/dev/null

# Heal through the same lifecycle-close path the reconciler runs. The typed
# status must leave the open snapshot; a Status: FIXED body stamp is not enough.
jq --arg slug "$root" \
  'map(if .slug == $slug then .body = "Evidence: lastgit://demo/cr/cr-aaa\n" else . end)' \
  "$BRAIN_STATE" >"$BRAIN_STATE.tmp"
mv "$BRAIN_STATE.tmp" "$BRAIN_STATE"

"$closer" "$root" --brain-bin "$tmp/brain" --lastgit-bin "$tmp/lastgit" --json \
  | jq -e '.checked == 1 and (.fixed | length) == 1 and (.errors | length) == 0' >/dev/null
grep -q '^CLOSE papercut close '"$root"' --status fixed ' "$BRAIN_CLOSE_LOG"
if grep -q 'Status: FIXED' "$BRAIN_APPEND_LOG"; then
  echo "lifecycle closer appended Status: FIXED instead of papercut close" >&2
  exit 1
fi

"$queue" snapshot --brain-bin "$tmp/brain" --output "$tmp/after.json" --json \
  | jq -e '.ok' >/dev/null
jq -e --arg root "$root" \
  'all(.rows[].slug; . != $root)' "$tmp/after.json" >/dev/null
jq -e --arg root "$root" \
  '.[] | select(.slug == $root) | .status == "fixed"' "$BRAIN_STATE" >/dev/null

jq -e '
  .apps[] | select(.app == "last-stack") | .links[] |
  select(.source == "bin/last-stack-pipeline-stuck-papercut-file" and
         .target == "$HOME/.local/bin/last-stack-pipeline-stuck-papercut-file")
' "$ROOT/config/host-track/apps.json" >/dev/null

printf 'ok last-stack-pipeline-stuck-papercut-file\n'
