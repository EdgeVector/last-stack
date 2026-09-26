#!/usr/bin/env bash
# Guard: bin/last-stack-prose-citation-check must tell a DANGLING citation apart
# from a busy node, from a generator template prefix, and from one of this
# repo's own tool names.
#
# The whole value of this checker is the discrimination. A checker that reports a
# transient node error as a dangling citation is ignored within a day, and then
# the real dangling citations ride along with the noise. A checker that reports
# the generator prefixes is ignored for the same reason — those were the measured
# false positives in
# papercut-shipped-prose-cites-brain-slugs-that-do-not-resolve-20260926.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
CHECK="$ROOT/bin/last-stack-prose-citation-check"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/prose-citation-test.XXXXXX")"
fail=0

note() { printf '%s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*" >&2; fail=1; }

# A stub `brain` whose verdict per slug comes from a file, so a case can make the
# node answer "absent", "busy", or "here" without a node.
make_brain() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/brain" <<'STUB'
#!/usr/bin/env bash
# args: get <slug> [--type <t>]
slug="$2"
typed=no
for a in "$@"; do [ "$a" = "--type" ] && typed=yes; done
verdict="$(sed -n "s/^${slug}:${typed}=//p" "$BRAIN_STUB_VERDICTS" | head -1)"
[ -n "$verdict" ] || verdict="$(sed -n "s/^${slug}=//p" "$BRAIN_STUB_VERDICTS" | head -1)"
case "$verdict" in
  ok)        echo "[${slug}]"; exit 0 ;;
  missing)   echo "error: No papercut: ${slug}" >&2
             echo "hint:  No papercut with that slug. Drop --type ..." >&2; exit 1 ;;
  transient) echo "error: node did not respond within 30000ms" >&2; exit 1 ;;
  weird)     echo "error: something the checker has never seen" >&2; exit 1 ;;
  *)         echo "error: No papercut: ${slug}" >&2; exit 1 ;;
esac
STUB
  chmod +x "$dir/brain"
}

# A fixture root shaped like an install root: prose in routines/, a bin/ whose
# names can collide with a token, and an ignore file.
make_root() {
  local root="$1" prose="$2"
  mkdir -p "$root/routines" "$root/bin" "$root/config"
  printf '%s\n' "$prose" > "$root/routines/fixture.md"
  : > "$root/bin/last-stack-papercut-lifecycle-close"
}

run_check() {
  local root="$1" verdicts="$2"; shift 2
  BRAIN_STUB_VERDICTS="$verdicts" \
  PROSE_CITATION_BRAIN_BIN="$TMP/stub/brain" \
    "$CHECK" --root "$root" --json "$@" > "$TMP/out.json" 2> "$TMP/out.err"
  echo $? > "$TMP/out.rc"
}

rc() { cat "$TMP/out.rc"; }
count() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(len(d[sys.argv[2]]))" "$TMP/out.json" "$1"; }
slugs() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(' '.join(r['slug'] for r in d[sys.argv[2]]))" "$TMP/out.json" "$1"; }
field() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$TMP/out.json" "$1"; }

make_brain "$TMP/stub"

# ---------------------------------------------------------------- case 1: clean
R="$TMP/r1"; make_root "$R" 'Ground truth: papercut-a-real-record-20260101 covers it.'
printf 'papercut-a-real-record-20260101=ok\n' > "$TMP/v1"
run_check "$R" "$TMP/v1"
[ "$(rc)" = 0 ] || bad "case1 clean: rc $(rc) != 0"
[ "$(count dangling)" = 0 ] || bad "case1 clean: dangling $(count dangling) != 0"
note "case1 clean rc=$(rc)"

# ------------------------------------------------------------- case 2: dangling
R="$TMP/r2"; make_root "$R" 'Ground truth: papercut-gone-in-the-gbrain-era-20260901 covers it.'
printf 'papercut-gone-in-the-gbrain-era-20260901=missing\n' > "$TMP/v2"
run_check "$R" "$TMP/v2"
[ "$(rc)" = 1 ] || bad "case2 dangling: rc $(rc) != 1"
[ "$(slugs dangling)" = "papercut-gone-in-the-gbrain-era-20260901" ] \
  || bad "case2 dangling: slugs '$(slugs dangling)'"
note "case2 dangling rc=$(rc) slug=$(slugs dangling)"

# ---------------------------------- case 3: a busy node is unknown, NOT dangling
# The load-bearing case. A node under backpressure must never be reported as a
# missing record, and it must not be reported as clean either.
R="$TMP/r3"; make_root "$R" 'Ground truth: papercut-node-was-busy-20260901 covers it.'
printf 'papercut-node-was-busy-20260901=transient\n' > "$TMP/v3"
run_check "$R" "$TMP/v3"
[ "$(rc)" = 3 ] || bad "case3 transient: rc $(rc) != 3"
[ "$(count dangling)" = 0 ] || bad "case3 transient: reported $(count dangling) dangling; a busy node is not an absent record"
[ "$(count unknown)" = 1 ] || bad "case3 transient: unknown $(count unknown) != 1"
note "case3 transient rc=$(rc) dangling=$(count dangling) unknown=$(count unknown)"

# ------------------------------------ case 4: a generator template prefix is not
# a citation. `papercut-pipeline-forge-<repo>-pr-<n>` names a family minted at
# run time; point-getting the prefix always fails and the report gets ignored.
R="$TMP/r4"; make_root "$R" 'It files ONE row per PR: `papercut-pipeline-forge-<repo>-pr-<n>`, and papercut-real-one-20260101 is the design.'
printf 'papercut-real-one-20260101=ok\npapercut-pipeline-forge=missing\n' > "$TMP/v4"
run_check "$R" "$TMP/v4"
[ "$(rc)" = 0 ] || bad "case4 template prefix: rc $(rc) != 0 (dangling=$(slugs dangling))"
case " $(slugs dangling) $(python3 -c "import json;d=json.load(open('$TMP/out.json'));print(' '.join(r['slug'] for r in d['skipped_rows']))") " in
  *papercut-pipeline-forge*) bad "case4: the template prefix reached the checked set" ;;
esac
note "case4 template prefix rc=$(rc) checked=$(field checked)"

# ---------------------------- case 5: a token naming one of this repo's own bins
R="$TMP/r5"; make_root "$R" 'Close it with papercut-lifecycle-close and nothing else.'
printf 'papercut-lifecycle-close=missing\n' > "$TMP/v5"
run_check "$R" "$TMP/v5"
[ "$(rc)" = 0 ] || bad "case5 local tool name: rc $(rc) != 0"
[ "$(count skipped_rows)" = 1 ] || bad "case5 local tool name: skipped $(count skipped_rows) != 1"
note "case5 local tool name rc=$(rc) skipped=$(count skipped_rows)"

# ----------------------------------------- case 6: the ignore file, with reasons
R="$TMP/r6"; make_root "$R" 'The ledger state is `papercut-some-state-token` here.'
printf 'papercut-some-state-token  prose naming a STATE, not a record\n' > "$R/config/prose-citation-ignore.txt"
printf 'papercut-some-state-token=missing\n' > "$TMP/v6"
run_check "$R" "$TMP/v6"
[ "$(rc)" = 0 ] || bad "case6 ignore file: rc $(rc) != 0"
note "case6 ignore file rc=$(rc)"

# ------------- case 7: a typed miss that resolves typeless is NOT dangling.
# `papercut-prevention-registry` and `papercut-reconciler-ledger` carry a
# papercut-shaped slug and are filed as `reference`. Without the typeless retry
# this checker calls two live records dead on its first real run.
R="$TMP/r7"; make_root "$R" 'Read papercut-prevention-registry before appending.'
printf 'papercut-prevention-registry:yes=missing\npapercut-prevention-registry:no=ok\n' > "$TMP/v7"
run_check "$R" "$TMP/v7"
[ "$(rc)" = 0 ] || bad "case7 typeless retry: rc $(rc) != 0 (dangling=$(slugs dangling))"
[ "$(count dangling)" = 0 ] || bad "case7 typeless retry: called a live reference-typed record dead"
note "case7 typeless retry rc=$(rc)"

# ----------------- case 8: an error the checker has never seen is not an absence
R="$TMP/r8"; make_root "$R" 'Ground truth: papercut-unclassified-error-20260101 covers it.'
printf 'papercut-unclassified-error-20260101=weird\n' > "$TMP/v8"
run_check "$R" "$TMP/v8"
[ "$(rc)" = 3 ] || bad "case8 unclassified: rc $(rc) != 3"
[ "$(count dangling)" = 0 ] || bad "case8 unclassified: an unrecognised error is not evidence of absence"
note "case8 unclassified rc=$(rc) unknown=$(count unknown)"

# ------------------------------- case 9: --list-only never touches the resolver
R="$TMP/r9"; make_root "$R" 'Ground truth: papercut-a-real-record-20260101 covers it.'
printf '' > "$TMP/v9"
BRAIN_STUB_VERDICTS="$TMP/v9" PROSE_CITATION_BRAIN_BIN=/nonexistent/brain \
  "$CHECK" --root "$R" --list-only > "$TMP/list.out" 2> "$TMP/list.err"
lrc=$?
[ "$lrc" = 0 ] || bad "case9 list-only: rc $lrc != 0 ($(head -1 "$TMP/list.err"))"
grep -qx 'papercut-a-real-record-20260101' "$TMP/list.out" \
  || bad "case9 list-only: token not listed"
note "case9 list-only rc=$lrc"

# ------------------- case 10: the shipped ignore file states a reason per entry
awk 'NF && $0 !~ /^#/ { if (NF < 2) { print "unreasoned: " $0; bad=1 } } END { exit bad }' \
  "$ROOT/config/prose-citation-ignore.txt" \
  || bad "case10: config/prose-citation-ignore.txt has an entry with no reason"
note "case10 ignore-file reasons ok"

rm -rf -- "$TMP"
if [ "$fail" -ne 0 ]; then
  echo "prose-citation-check guard: FAILED" >&2
  exit 1
fi
echo "ok prose-citation-check guard: 10 cases"
