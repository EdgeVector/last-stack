#!/usr/bin/env bash
# Fixture test for bin/last-stack-kanban-show-batch: one HashKeys query, no
# per-slug show / HashKey, and a missing slug is omitted (read-error / skip).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-kanban-show-batch"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/kanban-show-batch-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# ── CLI --slugs path ──────────────────────────────────────────────────────
fx="$tmp/fx"
mkdir -p "$fx"
jq -n --arg slug a --arg body 'DONE-WHEN: date >= 2000-01-01' \
  '{slug:$slug, body:$body, column:"backlog"}' >"$fx/show-a.json"
jq -n --arg slug b '{slug:$slug, body:"no predicate", column:"todo"}' >"$fx/show-b.json"

cat >"$tmp/kanban" <<EOF
#!/usr/bin/env bash
fx="$fx"
EOF
cat >>"$tmp/kanban" <<'EOF'
printf '%s\n' "$*" >> "$fx/calls.log"
case "$1" in
  show)
    slugs=""
    pos=""
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --json) shift ;;
        --slugs) slugs="$2"; shift 2 ;;
        --help|-h) echo "Options: --json --slugs"; exit 0 ;;
        *) pos="$1"; shift ;;
      esac
    done
    if [ -n "$slugs" ]; then
      printf '['
      sep=""
      old_ifs="$IFS"
      IFS=','
      set -f
      # shellcheck disable=SC2086
      set -- $slugs
      set +f
      IFS="$old_ifs"
      for s in "$@"; do
        [ -f "$fx/show-$s.json" ] || continue
        printf '%s' "$sep"
        cat "$fx/show-$s.json"
        sep=","
      done
      printf ']\n'
      exit 0
    fi
    [ -f "$fx/show-$pos.json" ] || { echo "No card with slug \"$pos\"" >&2; exit 1; }
    cat "$fx/show-$pos.json"
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$tmp/kanban"

"$BIN" --board-cli "$tmp/kanban" a b missing >"$tmp/out.json" 2>"$tmp/err"
jq -e 'type=="array" and length==2 and .[0].slug=="a" and .[1].slug=="b"' "$tmp/out.json" >/dev/null \
  || fail "cli-slugs payload: $(cat "$tmp/out.json")"
grep -q 'via=cli-slugs' "$tmp/err" || fail "via=cli-slugs missing: $(cat "$tmp/err")"
# missing slug is omitted
jq -e '[.[].slug] | index("missing") == null' "$tmp/out.json" >/dev/null \
  || fail "missing slug was returned"
batch_n="$(grep -c '^show --slugs ' "$fx/calls.log" || true)"
[ "$batch_n" = 1 ] || fail "want 1 show --slugs, got $batch_n: $(cat "$fx/calls.log")"
if grep -E '^show ' "$fx/calls.log" | grep -v -- '--slugs' | grep -v -- '--help' | grep -q .; then
  fail "per-slug show was used: $(cat "$fx/calls.log")"
fi

# ── HashKeys query path ───────────────────────────────────────────────────
cat >"$tmp/query" <<'EOF'
#!/usr/bin/env bash
cat >"${QUERY_LOG:?}"
cat <<'JSON'
{"ok":true,"results":[{"slug":"a","body":"A","column":"backlog"},{"slug":"b","body":"B","column":"todo"}]}
JSON
EOF
chmod +x "$tmp/query"

QUERY_LOG="$tmp/query-body.json"
export QUERY_LOG
out="$(
  LAST_STACK_KANBAN_SHOW_BATCH_VIA=query \
  LAST_STACK_LASTDB_QUERY_CMD="$tmp/query" \
    "$BIN" --slugs a,b,missing 2>"$tmp/q.err"
)"
printf '%s\n' "$out" | jq -e 'type=="array" and length==2' >/dev/null \
  || fail "query payload: $out"
grep -q 'via=query-hashkeys' "$tmp/q.err" || fail "via=query-hashkeys missing: $(cat "$tmp/q.err")"
jq -e '.filter.HashKeys == ["a","b","missing"]' "$QUERY_LOG" >/dev/null \
  || fail "want HashKeys filter, got: $(cat "$QUERY_LOG")"
jq -e '.limit == 3' "$QUERY_LOG" >/dev/null \
  || fail "want limit=chunk length 3, got: $(cat "$QUERY_LOG")"
if jq -e '.filter.HashKey' "$QUERY_LOG" >/dev/null 2>&1; then
  fail "per-slug HashKey was used: $(cat "$QUERY_LOG")"
fi
printf '%s\n' "$out" | jq -e '[.[].slug] | index("missing") == null' >/dev/null \
  || fail "query path returned missing slug"

# Truncated page (has_more) is a batch failure, not a short slug set.
cat >"$tmp/query-more" <<'EOF'
#!/usr/bin/env bash
cat >"${QUERY_LOG:?}"
cat <<'JSON'
{"ok":true,"has_more":true,"results":[{"slug":"a","body":"A","column":"backlog"}]}
JSON
EOF
chmod +x "$tmp/query-more"
QUERY_LOG="$tmp/query-more-body.json"
export QUERY_LOG
set +e
LAST_STACK_KANBAN_SHOW_BATCH_VIA=query \
LAST_STACK_LASTDB_QUERY_CMD="$tmp/query-more" \
  "$BIN" --slugs a,b,c >"$tmp/more.out" 2>"$tmp/more.err"
more_rc=$?
set -e
[ "$more_rc" = 1 ] || fail "has_more want exit 1, got $more_rc err=$(cat "$tmp/more.err")"
grep -q 'has_more=true' "$tmp/more.err" || fail "has_more error missing: $(cat "$tmp/more.err")"
jq -e '.limit == 3' "$QUERY_LOG" >/dev/null \
  || fail "has_more path want limit=3, got: $(cat "$QUERY_LOG")"

python3 - "$BIN" <<'PY' || fail "query_limit / query_truncated unit"
import sys
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader

loader = SourceFileLoader("show_batch", sys.argv[1])
spec = spec_from_loader("show_batch", loader)
assert spec is not None
mod = module_from_spec(spec)
loader.exec_module(mod)
assert mod.query_limit(["a", "b", "c"]) == 3
assert mod.query_limit(["s"] * 1001) == 1000
assert mod.query_truncated({"has_more": True})
assert not mod.query_truncated({"ok": True, "results": []})
assert mod.query_truncated({"page": {"hasMore": True}})
PY

# One-item path keeps single-slug show.
: >"$fx/calls.log"
"$BIN" --board-cli "$tmp/kanban" a >"$tmp/one.json" 2>"$tmp/one.err"
jq -e 'length==1 and .[0].slug=="a"' "$tmp/one.json" >/dev/null \
  || fail "one-item payload: $(cat "$tmp/one.json")"
grep -q 'via=cli-show' "$tmp/one.err" || fail "one-item via: $(cat "$tmp/one.err")"
if grep -q -- '--slugs' "$fx/calls.log"; then
  fail "one-item used --slugs: $(cat "$fx/calls.log")"
fi
grep -q '^show a --json$' "$fx/calls.log" || grep -q '^show --json a$' "$fx/calls.log" \
  || fail "one-item did not call show a: $(cat "$fx/calls.log")"

# Serial fixture that omits slug (column-only show). The requested slug is the
# key; attach it so callers can map the row. A batch query still omits missing.
cat >"$tmp/nslug" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${NSLUG_CALLS:?}"
case "$1" in
  show)
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --help|-h) echo "fixture show: slug then --json"; exit 0 ;;
        --json) shift ;;
        --slugs) echo "unknown option --slugs" >&2; exit 2 ;;
        *) shift ;;
      esac
    done
    printf '{"column":"doing"}\n'
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$tmp/nslug"
NSLUG_CALLS="$tmp/nslug.calls"
: >"$NSLUG_CALLS"
export NSLUG_CALLS
"$BIN" --board-cli "$tmp/nslug" a b >"$tmp/nslug.json" 2>"$tmp/nslug.err" \
  || fail "slug-less serial show exited $? err=$(cat "$tmp/nslug.err")"
jq -e 'type=="array" and length==2 and .[0].slug=="a" and .[1].slug=="b" and .[0].column=="doing" and .[1].column=="doing"' \
  "$tmp/nslug.json" >/dev/null \
  || fail "slug-less serial payload: $(cat "$tmp/nslug.json") err=$(cat "$tmp/nslug.err")"
grep -q 'via=cli-show' "$tmp/nslug.err" || fail "slug-less via: $(cat "$tmp/nslug.err")"
if grep -q -- '--slugs' "$NSLUG_CALLS"; then
  fail "slug-less fixture used --slugs: $(cat "$NSLUG_CALLS")"
fi

echo "ok last-stack-kanban-show-batch"
