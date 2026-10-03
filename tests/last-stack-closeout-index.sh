#!/usr/bin/env bash
set -euo pipefail

# Fixture for `last-stack-closeout-index`: a routine's closeout records are
# slugged with the author's own wall clock and nothing indexes the newest, so
# a pass guesses the time component and a miss reads a stale open list as
# current
# (papercut-no-stable-pointer-to-a-routines-newest-closeout-so-a-pass-guesses-slugs-and-reads-a-stale-open-list-20261003).
#
# The load-bearing case is REFUSE-ON-UNREADABLE. `brain put` replaces the whole
# body, so a rewrite driven by a failed read would silently truncate the index
# to a single entry -- destroying the exact history the pointer exists to
# serve. The negative fixture therefore supplies a WRONG read (a node error),
# never an absent one: an absent record is a legitimate create.

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tool="$ROOT/bin/last-stack-closeout-index"
[ -x "$tool" ] || { echo "missing executable closeout-index helper" >&2; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/closeout-index.XXXXXX")"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
bin_dir="$tmp/bin"
mkdir -p "$bin_dir"

fail() { echo "FAIL: $*" >&2; exit 1; }

# ---------------------------------------------------------------- case 1
# Absent index -> create, one entry, and the put body is what we rendered.
cat >"$bin_dir/brain" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "get" ]; then
  printf '{"error":"No reference: closeout-index-demo","hint":"x"}\n'
  exit 1
fi
if [ "$1" = "put" ]; then
  cat >"$PUT_LOG"
  echo "created reference $2"
  exit 0
fi
echo "unexpected brain args: $*" >&2; exit 2
SH
chmod +x "$bin_dir/brain"
export PUT_LOG="$tmp/put1.body"
out="$(PATH="$bin_dir:$PATH" "$tool" record demo closeout-20261003-demo-2200)"
[ "$out" = "closeout-index-demo" ] || fail "case1: stdout was '$out'"
grep -q '^- closeout-20261003-demo-2200$' "$PUT_LOG" || fail "case1: entry not in body"
grep -q '^slug: closeout-index-demo$' "$PUT_LOG" || fail "case1: frontmatter slug missing"
grep -q '^status: active$' "$PUT_LOG" || fail "case1: reference status must be active"

# ---------------------------------------------------------------- case 2
# Existing index -> newest first, existing entries preserved in order.
make_brain_with_body() {
  cat >"$bin_dir/brain" <<SH
#!/usr/bin/env bash
set -euo pipefail
if [ "\$1" = "get" ]; then
  printf '%s\n' '$1'
  exit 0
fi
if [ "\$1" = "put" ]; then
  cat >"\$PUT_LOG"
  echo "updated reference \$2"
  exit 0
fi
echo "unexpected brain args: \$*" >&2; exit 2
SH
  chmod +x "$bin_dir/brain"
}
make_brain_with_body '{"slug":"closeout-index-demo","body":"## Closeouts, newest first\n\n- closeout-20261003-demo-2115\n- closeout-20261003-demo-1745\n"}'
export PUT_LOG="$tmp/put2.body"
PATH="$bin_dir:$PATH" "$tool" record demo closeout-20261003-demo-2200 >/dev/null
got="$(grep '^- ' "$PUT_LOG" | tr '\n' ' ')"
want="- closeout-20261003-demo-2200 - closeout-20261003-demo-2115 - closeout-20261003-demo-1745 "
[ "$got" = "$want" ] || fail "case2: order wrong: got '$got'"

# ---------------------------------------------------------------- case 3
# Re-recording an already-present slug moves it to the front, no duplicate.
make_brain_with_body '{"slug":"closeout-index-demo","body":"## Closeouts, newest first\n\n- closeout-20261003-demo-2115\n- closeout-20261003-demo-2200\n"}'
export PUT_LOG="$tmp/put3.body"
PATH="$bin_dir:$PATH" "$tool" record demo closeout-20261003-demo-2200 >/dev/null
[ "$(grep -c '^- closeout-20261003-demo-2200$' "$PUT_LOG")" = "1" ] || fail "case3: duplicated"
[ "$(head -1 <(grep '^- ' "$PUT_LOG"))" = "- closeout-20261003-demo-2200" ] || fail "case3: not moved to front"

# ---------------------------------------------------------------- case 4
# --keep truncates the OLDEST, never the newest.
make_brain_with_body '{"slug":"closeout-index-demo","body":"## Closeouts, newest first\n\n- a-one\n- b-two\n- c-three\n"}'
export PUT_LOG="$tmp/put4.body"
PATH="$bin_dir:$PATH" "$tool" record demo d-four --keep 2 >/dev/null
got="$(grep '^- ' "$PUT_LOG" | tr '\n' ' ')"
[ "$got" = "- d-four - a-one " ] || fail "case4: keep wrong: got '$got'"

# ---------------------------------------------------------------- case 5
# LOAD-BEARING. An UNREADABLE index (node error, NOT a not-found payload) must
# refuse with exit 4 and must not call `brain put` at all. A wrong read, never
# an absent one: absent is case 1 and is a legitimate create.
cat >"$bin_dir/brain" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "get" ]; then
  echo "error: service_timeout: node did not respond within 30000ms" >&2
  exit 1
fi
if [ "$1" = "put" ]; then
  echo "PUT-HAPPENED" >>"$PUT_LOG"
  exit 0
fi
exit 2
SH
chmod +x "$bin_dir/brain"
export PUT_LOG="$tmp/put5.body"
: >"$PUT_LOG"
rc=0
PATH="$bin_dir:$PATH" "$tool" record demo closeout-20261003-demo-2200 >/dev/null 2>"$tmp/err5" || rc=$?
[ "$rc" = "4" ] || fail "case5: expected exit 4 on unreadable index, got $rc"
[ ! -s "$PUT_LOG" ] || fail "case5: rewrote the index from a FAILED read -- history truncated"
grep -q 'refusing to write' "$tmp/err5" || fail "case5: refusal printed no reason"

# ---------------------------------------------------------------- case 6
# A not-found-shaped payload for a DIFFERENT slug is not this slug's absence.
cat >"$bin_dir/brain" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "get" ]; then
  printf '{"error":"No reference: some-other-record","hint":"x"}\n'
  exit 1
fi
if [ "$1" = "put" ]; then
  echo "PUT-HAPPENED" >>"$PUT_LOG"
  exit 0
fi
exit 2
SH
chmod +x "$bin_dir/brain"
export PUT_LOG="$tmp/put6.body"
: >"$PUT_LOG"
rc=0
PATH="$bin_dir:$PATH" "$tool" record demo closeout-20261003-demo-2200 >/dev/null 2>&1 || rc=$?
[ "$rc" = "4" ] || fail "case6: a foreign not-found must not read as this slug's absence (got $rc)"
[ ! -s "$PUT_LOG" ] || fail "case6: wrote on a foreign not-found"

# ---------------------------------------------------------------- case 7
# latest prints the newest slug only.
make_brain_with_body '{"slug":"closeout-index-demo","body":"## Closeouts, newest first\n\n- closeout-20261003-demo-2200\n- closeout-20261003-demo-2115\n"}'
got="$(PATH="$bin_dir:$PATH" "$tool" latest demo)"
[ "$got" = "closeout-20261003-demo-2200" ] || fail "case7: latest returned '$got'"
got="$(PATH="$bin_dir:$PATH" "$tool" list demo | tr '\n' ' ')"
[ "$got" = "closeout-20261003-demo-2200 closeout-20261003-demo-2115 " ] || fail "case7: list returned '$got'"

# ---------------------------------------------------------------- case 8
# latest on an absent index exits 3 (caller may bootstrap) and prints no slug.
cat >"$bin_dir/brain" <<'SH'
#!/usr/bin/env bash
printf '{"error":"No reference: closeout-index-demo","hint":"x"}\n'
exit 1
SH
chmod +x "$bin_dir/brain"
rc=0
got="$(PATH="$bin_dir:$PATH" "$tool" latest demo 2>/dev/null)" || rc=$?
[ "$rc" = "3" ] || fail "case8: expected exit 3 on absent index, got $rc"
[ -z "$got" ] || fail "case8: printed a slug on an absent index: '$got'"

# ---------------------------------------------------------------- case 9
# LOAD-BEARING. latest on an UNREADABLE index must exit 4, distinguishably
# from case 8's "no index yet". Collapsing the two sends the caller back to
# guessing slug timestamps, which is the defect this tool exists to remove.
cat >"$bin_dir/brain" <<'SH'
#!/usr/bin/env bash
echo "error: too many concurrent reads" >&2
exit 1
SH
chmod +x "$bin_dir/brain"
rc=0
PATH="$bin_dir:$PATH" "$tool" latest demo >/dev/null 2>&1 || rc=$?
[ "$rc" = "4" ] || fail "case9: unreadable index must exit 4, not 3 (got $rc)"

# ---------------------------------------------------------------- case 10
# An index that exists but retains nothing is not a latest.
make_brain_with_body '{"slug":"closeout-index-demo","body":"## Closeouts, newest first\n\n"}'
rc=0
PATH="$bin_dir:$PATH" "$tool" latest demo >/dev/null 2>&1 || rc=$?
[ "$rc" = "3" ] || fail "case10: empty index must exit 3, got $rc"

# ---------------------------------------------------------------- case 11
# The realistic backpressure shape: a WELL-FORMED JSON error that is not a
# not-found. `service_timeout` / `too many concurrent reads` mean the node is
# BUSY, so the record almost certainly exists; reading that as absence would
# rewrite a full index down to one entry.
cat >"$bin_dir/brain" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "get" ]; then
  printf '{"error":"service_timeout","hint":"node did not respond within 30000ms"}\n'
  exit 1
fi
if [ "$1" = "put" ]; then
  echo "PUT-HAPPENED" >>"$PUT_LOG"
  exit 0
fi
exit 2
SH
chmod +x "$bin_dir/brain"
export PUT_LOG="$tmp/put11.body"
: >"$PUT_LOG"
rc=0
PATH="$bin_dir:$PATH" "$tool" record demo closeout-20261003-demo-2200 >/dev/null 2>&1 || rc=$?
[ "$rc" = "4" ] || fail "case11: a busy-node JSON error must not read as absence (got $rc)"
[ ! -s "$PUT_LOG" ] || fail "case11: rewrote the index on a busy-node error"

# ---------------------------------------------------------------- case 12
# Prose ABOVE the marker is not an entry. The generated banner is prose, and a
# bullet in it parsed as a slug would make `latest` return a word from a
# sentence -- so the caller point-gets a slug that does not exist and reads the
# miss as the closeout being gone. Worse than returning nothing.
make_brain_with_body '{"slug":"closeout-index-demo","body":"Read the newest with:\n\n- latest demo\n- some-prose-bullet\n\n## Closeouts, newest first\n\n- closeout-20261003-demo-2200\n"}'
got="$(PATH="$bin_dir:$PATH" "$tool" list demo | tr '\n' ' ')"
[ "$got" = "closeout-20261003-demo-2200 " ] || fail "case12: prose bullet leaked in: '$got'"

# ---------------------------------------------------------------- case 13
# A body with NO marker is not an index this tool wrote. Refuse rather than
# rewrite: whatever it holds is someone else's, and the write replaces it whole.
export PUT_LOG="$tmp/put13.body"
: >"$PUT_LOG"
make_brain_with_body '{"slug":"closeout-index-demo","body":"hand-written notes nobody meant to lose\n"}'
rc=0
PATH="$bin_dir:$PATH" "$tool" record demo closeout-20261003-demo-2200 >/dev/null 2>&1 || rc=$?
[ "$rc" = "4" ] || fail "case13: a markerless body must be refused, got $rc"
[ ! -s "$PUT_LOG" ] || fail "case13: overwrote a body this tool did not write"

echo "ok: last-stack-closeout-index (13 cases)"
