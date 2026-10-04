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
  ok)        echo "[${slug}]"
             # The one-hop mode reads the BODY, which the `ok` line alone has
             # never carried. A body line is `slug|text`; `\n` becomes a newline.
             if [ -n "${BRAIN_STUB_BODIES:-}" ] && [ -f "$BRAIN_STUB_BODIES" ]; then
               sed -n "s/^${slug}|//p" "$BRAIN_STUB_BODIES" | head -1 \
                 | sed 's/\\n/\
/g'
             fi
             exit 0 ;;
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
  BRAIN_STUB_BODIES="${BRAIN_STUB_BODIES:-}" \
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

# ------------- case 11: a dangling preference- citation must be caught too.
# papercut-prose-citation-check-does-not-scan-preference-prefixed-tokens-20260927:
# the checker only extracted papercut-/sop-/decision- tokens and silently
# reported 0 dangling while a real dangling preference- slug sat in shipped
# frontmatter (skills/*/SKILL.md `description:`, which is plain text to this
# checker, not YAML-parsed).
R="$TMP/r11"; make_root "$R" 'Standing rule: preference-lastdb-upgrade-ephemeral-probe-first.'
printf 'preference-lastdb-upgrade-ephemeral-probe-first=missing\n' > "$TMP/v11"
run_check "$R" "$TMP/v11"
[ "$(rc)" = 1 ] || bad "case11 preference dangling: rc $(rc) != 1"
[ "$(slugs dangling)" = "preference-lastdb-upgrade-ephemeral-probe-first" ] \
  || bad "case11 preference dangling: slugs '$(slugs dangling)'"
note "case11 preference dangling rc=$(rc) slug=$(slugs dangling)"

# ------------- case 12: the table covers the brain's WHOLE type vocabulary.
# This is the structural half. CITED_TYPES was widened twice before, once per
# prefix someone happened to notice (case 11 is the second one), and each time
# the checker had been answering `dangling 0` over a subset while real dangling
# citations in the uncovered prefixes were invisible. Pin the whole vocabulary
# so the third partial set cannot ship: these are the ten `<type> new` commands
# `brain help` prints, plus `papercut`, which is its own subcommand.
#
# Not derived from `brain help` at run time on purpose: this case must pass on a
# CI runner with no brain installed, which is also why the checker is not a
# merge gate. If brain gains a type, this list is the one place to widen.
expected_types='agent concept decision design papercut preference project reference sop spike task'
actual_types="$(python3 - "$CHECK" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
block = re.search(r"CITED_TYPES = \{(.*?)\}", src, re.S).group(1)
print(" ".join(sorted(set(re.findall(r'"[a-z-]+":\s*"([a-z-]+)"', block)))))
PY
)"
[ "$actual_types" = "$expected_types" ] \
  || bad "case12 vocabulary: CITED_TYPES maps to '$actual_types', expected '$expected_types'"
note "case12 vocabulary ok: $actual_types"

# ----- case 13: a dangling citation in each prefix added 2026-10-03 is caught.
# One case per newly covered prefix, each with a slug that LOOKS exactly like a
# real citation, because the failure these reproduce is silence: before the
# widening every one of these read as `dangling 0`.
for pfx in design task concept reference agent project spike; do
  R="$TMP/r13-$pfx"; make_root "$R" "Ground truth: ${pfx}-gone-from-the-store-20260901 covers it."
  printf '%s-gone-from-the-store-20260901=missing\n' "$pfx" > "$TMP/v13"
  run_check "$R" "$TMP/v13"
  [ "$(rc)" = 1 ] || bad "case13 $pfx: rc $(rc) != 1"
  [ "$(slugs dangling)" = "${pfx}-gone-from-the-store-20260901" ] \
    || bad "case13 $pfx: slugs '$(slugs dangling)'"
done
note "case13 seven new prefixes caught"

# ------------- case 14: `concepts-` is accepted and point-got as type `concept`.
# This host's prose cites concept records under both spellings. The plural is not
# a type, so a naive prefix==type mapping asks `brain get --type concepts` and
# that is not the question. The negative half is the one that matters: the typed
# get must be the SINGULAR, so the stub answers `ok` only for the typed form and
# a wrong type would have to fall back to the typeless retry.
R="$TMP/r14"; make_root "$R" 'READ FIRST: concepts-the-canonical-model is the model.'
printf 'concepts-the-canonical-model:yes=ok\nconcepts-the-canonical-model:no=missing\n' > "$TMP/v14"
run_check "$R" "$TMP/v14"
[ "$(rc)" = 0 ] || bad "case14 concepts alias: rc $(rc) != 0 (dangling=$(slugs dangling))"
[ "$(count dangling)" = 0 ] || bad "case14 concepts alias: a plural-spelled concept citation was called dead"
# The load-bearing assertion, and NOT the two above it. Dropping the alias makes
# the plural token fail to EXTRACT, so the report is empty and rc is 0: measured
# 2026-10-03, the mutation probe for the alias came back GREEN until this line
# existed. An invisible citation and a resolved one are the same number
# everywhere except here.
[ "$(field checked)" = 1 ] \
  || bad "case14 concepts alias: checked=$(field checked) != 1; the plural token was never extracted, not resolved"
note "case14 concepts alias rc=$(rc) checked=$(field checked)"

# ------------- case 15: a token after a `/` is a PATH SEGMENT, not a citation.
# `https://thelastdb.com/docs/agent-access-model` is a URL in the workspace
# CLAUDE.md. Measured over both prose roots 2026-10-03: every slash-preceded
# token was a path segment and none was a citation. The fixture supplies a WRONG
# value rather than an absent one -- the slug resolves nowhere and the stub is
# told so -- so the only way this case passes is the lookbehind.
R="$TMP/r15"; make_root "$R" 'Mirror: https://thelastdb.com/docs/agent-access-model and docs/design-some-page-here.'
printf 'agent-access-model=missing\ndesign-some-page-here=missing\n' > "$TMP/v15"
run_check "$R" "$TMP/v15"
[ "$(rc)" = 0 ] || bad "case15 path segment: rc $(rc) != 0 (dangling=$(slugs dangling))"
[ "$(count dangling)" = 0 ] || bad "case15 path segment: a URL path segment was reported as a dangling record"
note "case15 path segment rc=$(rc)"

# ------------- case 16: a dangling citation in a HOOK's deny text is caught.
# The hook surface was unscanned until 2026-10-04 while PROSE_GLOBS was `*.md`
# only, and it is the surface most likely to be copied: a deny message arrives
# mid-task, phrased as an instruction, naming a slug as the authority for a
# refusal. Three of this repo's six `hooks/*.sh` citations were dangling when it
# was first scanned, against `dangling 0` on the `*.md` corpus the same day.
R="$TMP/r16"; make_root "$R" 'Nothing cited here.'
mkdir -p "$R/hooks"
cat > "$R/hooks/deny-something.sh" <<'HOOK'
#!/usr/bin/env bash
emit_deny "BLOCKED: do not do that here.

(brain papercut-the-deny-text-authority-20260101)"
HOOK
printf 'papercut-the-deny-text-authority-20260101=missing\n' > "$TMP/v16"
run_check "$R" "$TMP/v16"
[ "$(rc)" = 1 ] || bad "case16 hook prose: rc $(rc) != 1 (hooks/*.sh is not being scanned)"
[ "$(slugs dangling)" = "papercut-the-deny-text-authority-20260101" ] \
  || bad "case16 hook prose: slugs '$(slugs dangling)'"
# The load-bearing assertion (case 14's lesson). Dropping `hooks/*.sh` from
# PROSE_GLOBS makes the token fail to EXTRACT, so the report is empty and rc is
# 0 -- an unscanned citation and a resolved one are the same number everywhere
# except in `checked`.
[ "$(field checked)" = 1 ] \
  || bad "case16 hook prose: checked=$(field checked) != 1; the hook was never read"
note "case16 hook prose rc=$(rc) checked=$(field checked)"

# ------------- case 17: --changed-since reads ONLY the changed prose.
# The per-change mode is what gives this checker a live caller at all (close-out
# runs on every substantive change; its scheduled caller sits in a routine the
# fleet has had paused). Both halves matter: the changed file's dangling
# citation must be CAUGHT, and the untouched file's must not be read -- the
# narrowing is the whole reason the sweep costs about 1 s instead of 29 s.
R="$TMP/r17"
mkdir -p "$R/routines" "$R/bin" "$R/config"
git -C "$R" init -q 2>/dev/null
git -C "$R" config user.email ci@example.com
git -C "$R" config user.name ci
printf 'Old prose cites papercut-untouched-and-gone-20260101.\n' > "$R/routines/old.md"
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" commit -qm base >/dev/null 2>&1
base_ref="$(git -C "$R" rev-parse HEAD)"
printf 'New prose cites papercut-just-written-and-gone-20260101.\n' > "$R/routines/new.md"
printf 'papercut-untouched-and-gone-20260101=missing\npapercut-just-written-and-gone-20260101=missing\n' > "$TMP/v17"
run_check "$R" "$TMP/v17" --changed-since "$base_ref"
[ "$(rc)" = 1 ] || bad "case17 changed-since: rc $(rc) != 1; the changed file's dangling citation was missed"
[ "$(slugs dangling)" = "papercut-just-written-and-gone-20260101" ] \
  || bad "case17 changed-since: slugs '$(slugs dangling)'; the untouched file must not be read"
[ "$(field prose_files)" = 1 ] \
  || bad "case17 changed-since: prose_files=$(field prose_files) != 1; the set was not narrowed"
note "case17 changed-since rc=$(rc) prose_files=$(field prose_files) slug=$(slugs dangling)"

# ------------- case 18: a changed set that cannot be computed is NOT a pass.
# Exit 2, never 0. A narrowing that silently covers nothing prints `dangling 0`
# and reads exactly like a clean corpus, which is the failure this whole checker
# exists to stop -- the same shape as case 14 and case 16, one level up.
run_check "$R" "$TMP/v17" --changed-since no-such-ref-here
[ "$(rc)" = 2 ] \
  || bad "case18 unresolvable ref: rc $(rc) != 2; an uncomputable changed set must not read as clean"
grep -q 'cannot determine the changed set' "$TMP/out.err" \
  || bad "case18 unresolvable ref: no message naming the cause ($(head -1 "$TMP/out.err"))"
note "case18 unresolvable ref rc=$(rc)"

# ------------- case 19: the checker has a LIVE caller.
# The wiring case, and the one that matters most over time. This tool shipped
# correct, installed correctly, and ran zero times on a schedule, because its
# only automatic caller was a step in a routine the fleet had paused -- every
# number its papercut carries was produced by hand. A checker nothing runs is
# the same artifact as no checker. close-out runs on this host after every
# substantive change, by every agent, and a paused fleet cannot silence it.
grep -q 'last-stack-prose-citation-check' "$ROOT/skills/close-out/SKILL.md" \
  || bad "case19 live caller: skills/close-out/SKILL.md no longer runs the checker"
grep -q -- '--changed-since' "$ROOT/skills/close-out/SKILL.md" \
  || bad "case19 live caller: close-out must use the per-change mode, not a 29 s full-root sweep"
note "case19 live caller ok"

# ------------- case 20: a dangling [[target]] INSIDE a cited record is caught.
# The prose extractor can only see a token that starts with one of the eleven
# CITED_TYPES, so an untyped record name a SOP links onward to is invisible to it
# forever. Measured 2026-10-04 one hop from this install's prose: 25 of 70
# [[targets]] did not resolve, and `dogfood-registry`, `open-decisions` and
# `new-repositories-default-to-lastgit` are among them -- none of which any
# prefix table can reach.
R="$TMP/r20"; make_root "$R" 'Read sop-the-one-that-exists-20260101 first.'
printf 'sop-the-one-that-exists-20260101=ok\ndogfood-registry=missing\n' > "$TMP/v20"
printf 'sop-the-one-that-exists-20260101|The index is [[dogfood-registry]].\n' > "$TMP/b20"
BRAIN_STUB_BODIES="$TMP/b20" run_check "$R" "$TMP/v20" --one-hop
[ "$(rc)" = 1 ] || bad "case20 one hop: rc $(rc) != 1; the hop finding did not reach the exit code"
[ "$(slugs hop_dangling)" = "dogfood-registry" ] \
  || bad "case20 one hop: hop_dangling '$(slugs hop_dangling)'"
# What was EXAMINED, not only what was found: a hop over zero records reports
# `hop_dangling 0` and reads exactly like a corpus whose links all resolve.
[ "$(field hop_sources)" = 1 ] \
  || bad "case20 one hop: hop_sources=$(field hop_sources) != 1; no record body was read"
[ "$(field hop_targets)" = 1 ] \
  || bad "case20 one hop: hop_targets=$(field hop_targets) != 1; the [[target]] was not extracted"
note "case20 one hop rc=$(rc) sources=$(field hop_sources) targets=$(field hop_targets)"

# ------------- case 21: the hop is OPT-IN, and its absence is reported.
# It costs one brain get per cited record plus one per distinct target, which the
# per-change pre-PR caller cannot afford on the full root. A default nobody
# measured is the mistake this repo has already made in the other direction, so
# the method line has to SAY the hop did not run.
BRAIN_STUB_BODIES="$TMP/b20" run_check "$R" "$TMP/v20"
[ "$(rc)" = 0 ] || bad "case21 opt-in: rc $(rc) != 0; the hop ran without --one-hop"
[ "$(field hop_targets)" = None ] \
  || bad "case21 opt-in: hop_targets=$(field hop_targets); a skipped hop must be None, not 0"
python3 -c "import json,sys; m=json.load(open(sys.argv[1]))['method']; sys.exit(0 if 'NO hop' in m else 1)" "$TMP/out.json" \
  || bad "case21 opt-in: the method line does not say the hop was skipped"
note "case21 opt-in rc=$(rc) hop_targets=$(field hop_targets)"

# ------------- case 22: the measured non-citations are REFUSED and reported.
# Inside `[[ ]]` a token is a citation by construction -- except where the body
# quotes a shell snippet. All three non-citations in the 2026-10-04 measurement
# were shape, not semantics: `[[ -n "$repo" ]]`, `[[:space:]]` and an ellipsis
# placeholder. A memory-file name is the fourth: records do link to those, they
# live under ~/.claude, and 0 of the 164 slugs that resolved contained an
# underscore. Refused, and REPORTED -- a silent drop is how a narrow gate reads
# as a clean one.
R="$TMP/r22"; make_root "$R" 'Read sop-with-shell-snippets-20260101 first.'
printf 'sop-with-shell-snippets-20260101=ok\n' > "$TMP/v22"
printf 'sop-with-shell-snippets-20260101|Guard with [[ -n "$repo" ]] and strip [[:space:]] then see [[north-star-\xe2\x80\xa6]] and [[feedback_always_file_papercuts]].\n' > "$TMP/b22"
BRAIN_STUB_BODIES="$TMP/b22" run_check "$R" "$TMP/v22" --one-hop
[ "$(rc)" = 0 ] || bad "case22 refused shapes: rc $(rc) != 0; a shell snippet was read as a citation"
[ "$(field hop_targets)" = 0 ] \
  || bad "case22 refused shapes: hop_targets=$(field hop_targets) != 0"
[ "$(count hop_refused)" = 4 ] \
  || bad "case22 refused shapes: hop_refused=$(count hop_refused) != 4; the refusals must be reported, not dropped"
note "case22 refused shapes rc=$(rc) refused=$(count hop_refused)"

# ------------- case 23: a busy node on a hop target is unknown, NOT dangling.
# Case 3 one level down. The hop runs 70+ extra point reads against a node this
# host regularly has under backpressure, so it is the likeliest place for a
# transient to be misread as an absent record.
R="$TMP/r23"; make_root "$R" 'Read sop-links-to-a-busy-one-20260101 first.'
printf 'sop-links-to-a-busy-one-20260101=ok\nsome-busy-target=transient\n' > "$TMP/v23"
printf 'sop-links-to-a-busy-one-20260101|See [[some-busy-target]].\n' > "$TMP/b23"
BRAIN_STUB_BODIES="$TMP/b23" run_check "$R" "$TMP/v23" --one-hop
[ "$(rc)" = 3 ] || bad "case23 hop transient: rc $(rc) != 3"
[ "$(count hop_dangling)" = 0 ] \
  || bad "case23 hop transient: reported $(count hop_dangling) hop_dangling; a busy node is not an absent record"
[ "$(count hop_unknown)" = 1 ] \
  || bad "case23 hop transient: hop_unknown=$(count hop_unknown) != 1"
note "case23 hop transient rc=$(rc) hop_unknown=$(count hop_unknown)"

# ------------- case 24: the HOP has a live caller too.
# Case 19 for the one-hop mode. The mode is opt-in, so a caller that does not
# pass the flag leaves it exactly where the full-root sweep already sits: shipped,
# installed, correct and never run. The per-change source set is only the records
# the change itself points a reader at, and it was measured at 0.11 s when the
# change touches no prose and 13.0 s over an 11-file prose delta.
# The flag must be on the INVOCATION line, not merely somewhere in the file. The
# first version of this case grepped the whole document and stayed GREEN when the
# flag was removed from the command, because the paragraph that EXPLAINS --one-hop
# still mentions it. A wiring guard that matches its own rationale text certifies
# nothing (last-stack-routine-shell-lint hit the same shape on 2026-10-03).
grep -q -- 'last-stack-prose-citation-check".*--one-hop' "$ROOT/skills/close-out/SKILL.md" \
  || bad "case24 live hop caller: close-out does not pass --one-hop on the line that runs the checker, so the hop never executes"
note "case24 live hop caller ok"

rm -rf -- "$TMP"
if [ "$fail" -ne 0 ]; then
  echo "prose-citation-check guard: FAILED" >&2
  exit 1
fi
echo "ok prose-citation-check guard: 24 cases"
