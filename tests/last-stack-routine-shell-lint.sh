#!/usr/bin/env bash
# Fixture test for bin/last-stack-routine-shell-lint, the Claude hook that
# wraps it, and the Codex routine zsh->bash entry snippet.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
LINT="$ROOT/bin/last-stack-routine-shell-lint"
HOOK="$ROOT/hooks/routine-shell-lint.sh"
SNIPPET="$ROOT/lib/routine-shell/codex-routine-bash.zsh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/shell-lint-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fail=0
expect() {
  # expect <want-rc> <shell> <label> ; command text on stdin
  local want="$1" shell="$2" label="$3" got
  set +e
  "$LINT" --shell "$shell" --quiet
  got=$?
  set -e
  if [ "$got" != "$want" ]; then
    echo "FAIL [$label] shell=$shell want rc=$want got rc=$got" >&2
    fail=1
  fi
}

# The suite HANGS instead of failing when $LINT cannot start. Found by a
# mutation probe that moved a regex variable below its first use, so the lint
# died at source time under `set -u`: every expect case then returns rc=1,
# which should be ~30 instant FAIL lines, and instead the suite ran past 90s
# with EMPTY stdout while stderr repeated the unbound-variable message. The
# probe sat for over ten minutes and was killed, so it produced no verdict at
# all -- and a CI shard would burn its ~2803s deadline the same way, showing
# the operator a timeout rather than the error already in stderr.
#
# The blocking case is not yet identified (expect feeds a heredoc, which is a
# file and cannot block), so this does not diagnose the hang. It removes the
# class: refuse to run the suite at all against a binary that cannot answer a
# trivial command.
# Brain: papercut-routine-shell-lint-fixture-suite-hangs-instead-of-failing-when-the-lint-binary-cannot-start-20261004
if ! printf 'echo hi' | "$LINT" --shell bash --quiet >/dev/null 2>"$tmp/startup.err"; then
  echo "FAIL [startup] $LINT exits non-zero on a trivial command; the suite cannot run against it" >&2
  sed -n '1,5p' "$tmp/startup.err" >&2
  exit 1
fi

# --- spin-wait ---------------------------------------------------------------
expect 2 bash spin-basic <<'EOF'
while ! grep -q done f; do read -t 20 < /dev/zero; done
EOF
expect 2 bash spin-flags <<'EOF'
timeout 590 bash -c 'while true; do read -r -t 5 x </dev/zero 2>/dev/null; done'
EOF
expect 0 bash sleep-ok <<'EOF'
while ! grep -q done f; do sleep 30; done
EOF
expect 0 bash read-stdin-ok <<'EOF'
while IFS= read -r slug; do echo "$slug"; done < slugs.txt
EOF
expect 0 bash dd-dev-zero-ok <<'EOF'
dd if=/dev/zero of=blob bs=1k count=1
EOF

# --- usage completeness ------------------------------------------------------
# usage() printed a fixed LINE RANGE (`sed -n '2,36p'`), which went stale the
# moment the header grew: --help silently stopped at zsh-mapfile, dropping
# zsh-word-split, home-root-scan, the escape-hatch paragraph and the ENTIRE
# Usage/Exit section -- 13 of 16 rules documented, 0 occurrences of "Usage:".
# A rule nobody can read from --help is a rule agents keep breaking, so pin
# this structurally rather than trusting the next range edit. Same defect and
# same awk fix as bin/last-stack-lint-bin-authoring already carries.
help_out="$tmp/help.txt"
"$LINT" --help >"$help_out" 2>"$tmp/help.err"
[ -s "$tmp/help.err" ] && { echo "FAIL [usage] --help wrote to stderr" >&2; fail=1; }
grep -q '^Usage:' "$help_out" || { echo "FAIL [usage] --help must print the Usage section" >&2; fail=1; }
grep -q 'shell-lint-ok:' "$help_out" || { echo "FAIL [usage] --help must print the escape hatch" >&2; fail=1; }
grep -q '^Exit:' "$help_out" || { echo "FAIL [usage] --help must print the exit codes" >&2; fail=1; }
while IFS= read -r rule; do
  [ -n "$rule" ] || continue
  grep -q "^  $rule " "$help_out" \
    || { echo "FAIL [usage] --list-rules names $rule but --help does not document it" >&2; fail=1; }
done < <("$LINT" --list-rules)

# --- stat-local-zulu ---------------------------------------------------------
# BSD `stat -t` renders %F/%T in the LOCAL zone and emits a trailing Z as a
# LITERAL character, so the value is in the exact shape every UTC stamp on this
# fleet uses and is 25200s in the past. Always OLDER, so it manufactures stalls
# and never hides one: on 2026-10-03 a 13-minute-old log read as 7 hours stale
# and nearly became a p1 "the refresh agent is dead" finding.
expect 2 bash stat-zulu-short <<'EOF'
m=$(stat -f '%Sm' -t '%FT%TZ' -- "$f")
EOF
expect 2 bash stat-zulu-long <<'EOF'
stat -f %Sm -t '%Y-%m-%dT%H:%M:%SZ' f
EOF
expect 2 bash stat-zulu-double-quoted <<'EOF'
stat -t "%FT%TZ" -f '%Sm' f
EOF
# TZ=UTC makes the value correct and is not refused (it IS the live spelling in
# bin/last-stack-north-star-dashboard-run).
expect 0 bash stat-zulu-tz-utc-ok <<'EOF'
TZ=UTC stat -f '%Sm' -t '%Y-%m-%dT%H:%M:%SZ' "$f"
EOF
# %Z is a real strftime conversion printing the zone NAME: honest, not this bug.
expect 0 bash stat-zulu-zone-name-ok <<'EOF'
stat -f '%Sm' -t '%FT%T%Z' f
EOF
# Both prescribed correct forms. The second is the exact text the deny message
# prints, so this pins that the advice does not trip the rule that gives it.
expect 0 bash stat-zulu-epoch-ok <<'EOF'
age_s=$(( $(date +%s) - $(stat -f %m -- "$f") ))
EOF
expect 0 bash stat-zulu-date-u-r-ok <<'EOF'
stamp="$(date -u -r "$(stat -f %m -- "$f")" +%FT%TZ)"
EOF
# A format that does not end in Z is not this rule.
expect 0 bash stat-zulu-no-suffix-ok <<'EOF'
stat -f '%Sm' -t '%FT%T' f
EOF
# No `stat` on the line: another tool's -t flag must not match.
expect 0 bash stat-zulu-other-tool-ok <<'EOF'
lastgit status -t 'xZ'
EOF
expect 0 bash stat-zulu-hatch <<'EOF'
stat -f '%Sm' -t '%FT%TZ' f  # shell-lint-ok: rendering for a human who is told the zone
EOF

# --- heredoc-backticks -------------------------------------------------------
expect 2 bash heredoc-unquoted-backticks <<'OUTER'
cat > "$f" <<EOF
Closed `papercut-x` after the fix.
EOF
brain append x --type papercut < "$f"
OUTER
expect 0 bash heredoc-quoted-backticks <<'OUTER'
cat > "$f" <<'EOF'
Closed `papercut-x` after the fix. Also read -t 20 < /dev/zero is data here.
EOF
brain append x --type papercut < "$f"
OUTER
expect 0 bash heredoc-dquoted-backticks <<'OUTER'
cat > "$f" <<"EOF"
Closed `papercut-x`.
EOF
OUTER
expect 0 bash heredoc-unquoted-vars-ok <<'OUTER'
cat > "$f" <<EOF
run=$ROUTINES_RUN_DIR slug=$slug
EOF
OUTER
expect 2 bash heredoc-dash-tabs <<'OUTER'
cat <<-EOF
	see `x`
	EOF
OUTER
expect 0 bash herestring-ok <<'OUTER'
jq -r '.slug' <<< "$json"
OUTER
expect 2 bash second-heredoc-on-line <<'OUTER'
paste - - <<'A' 3<<B
`fine`
A
`bad`
B
OUTER
expect 0 bash after-heredoc-command-checked-clean <<'OUTER'
cat <<'EOF'
`x`
EOF
echo ok
OUTER
expect 2 bash after-heredoc-command-checked-bad <<'OUTER'
cat <<'EOF'
text
EOF
while true; do read -t 3 < /dev/zero; done
OUTER

expect 2 bash dquote-body-backticks <<'OUTER'
brain papercut close x --status verified --evidence "ran `kanban ping` ok"
OUTER
expect 0 bash dquote-body-file-ok <<'OUTER'
brain papercut close x --status verified --evidence "$(cat "$f")"
OUTER
expect 0 bash squote-body-backticks-ok <<'OUTER'
brain papercut close x --status verified --evidence 'ran `kanban ping` ok'
OUTER

# --- jq rules ----------------------------------------------------------------
expect 2 bash jq-match-optional-field <<'EOF'
jq -r '.body | match("DONE-WHEN:.*")?.string' card.json
EOF
expect 2 bash jq-capture-optional-field <<'EOF'
jq -r '.body // "" | capture("(?m)^DONE-WHEN:[[:space:]]*(?<p>.*)$")?.p // empty' c.json
EOF
expect 2 bash jq-paren-optional <<'EOF'
jq '(.a)?.b' x.json
EOF
expect 0 bash jq-field-optional-ok <<'EOF'
jq -r '.cards[]?.slug, .a?.b' x.json
EOF
expect 0 bash jq-try-ok <<'EOF'
jq -r 'try (.body | match("DONE-WHEN:.*").string) catch ""' card.json
EOF
expect 2 bash jq-escaped-quote <<'EOF'
jq -r '.[] | "\(.slug) \(.status) \(.severity // \"\")"' sit.json
EOF
expect 0 bash jq-interpolation-ok <<'EOF'
jq -r '.[] | "\(.slug) \(.status) \(.severity)"' sit.json
EOF
expect 0 bash jq-tsv-ok <<'EOF'
jq -r '.[] | [.slug, .status, (.severity // "-")] | @tsv' sit.json
EOF
expect 2 bash jq-dquote-plain-literal <<'EOF'
jq -r "[.slug, .status, (.severity // \"-\")] | @tsv" sit.json
EOF

# --- awk / sed ---------------------------------------------------------------
expect 2 bash awk-match-array <<'EOF'
awk 'match($0,/^DONE-WHEN:[[:space:]]*(.*)$/,m){print m[1]; exit}' body.md
EOF
expect 0 bash awk-match-two-args-ok <<'EOF'
awk 'match($0,/DONE-WHEN:/){print substr($0, RSTART)}' body.md
EOF
expect 2 bash sed-inplace-bare <<'EOF'
sed -i 's/^ tags:/tags:/' body.md
EOF
expect 2 bash sed-inplace-unquoted <<'EOF'
sed -i s/a/b/ body.md
EOF
expect 0 bash sed-inplace-empty-ext-ok <<'EOF'
sed -i '' 's/a/b/' body.md
EOF
expect 0 bash sed-inplace-bak-ok <<'EOF'
sed -i.bak 's/a/b/' body.md
EOF
expect 0 bash sed-n-ok <<'EOF'
sed -n 's/^DONE-WHEN:[[:space:]]*//p' body.md
EOF

expect 2 bash date-nanos <<'EOF'
start_ms=$(date +%s%3N); kanban ping; end_ms=$(date +%s%3N)
EOF
expect 0 bash gdate-nanos-ok <<'EOF'
start_ms=$(gdate +%s%3N)
EOF
expect 0 bash date-iso-ok <<'EOF'
date -u +%Y-%m-%dT%H:%M:%SZ
EOF

expect 2 bash printf-dash-double <<'EOF'
printf '--- %s ---\n' "$slug"
EOF
expect 2 bash printf-dash-item <<'EOF'
printf "- %s\n" "$slug"
EOF
expect 0 bash printf-dash-safe <<'EOF'
printf '%s\n' '- item'; printf -- '- %s\n' "$slug"
EOF
expect 2 bash bin-mktemp <<'EOF'
f=$(/bin/mktemp "$TMPDIR/x.XXXXXX")
EOF
expect 0 bash usr-bin-and-bin-sh-ok <<'EOF'
f=$(/usr/bin/mktemp); /bin/sh -c 'echo ok'; /bin/date -u; ls ~/.local/bin/jq-helper
EOF

# --- zsh-only rules ----------------------------------------------------------
expect 2 zsh zsh-status-assign <<'EOF'
for pr in 1 2; do status=$(curl -s x); echo "$status"; done
EOF
expect 2 zsh zsh-status-read <<'EOF'
while IFS=$'\t' read -r slug status title; do echo "$slug"; done < rows.tsv
EOF
expect 0 bash bash-status-ok <<'EOF'
status=$(curl -s x); echo "$status"
EOF
expect 0 zsh zsh-status-word-ok <<'EOF'
routines status --json > s.json; jq -r '.status' s.json; git status --short
EOF
expect 2 zsh zsh-status-after-do <<'EOF'
for pr in 1 2; do status=$(curl -s x); done
EOF
expect 2 zsh zsh-status-line-start <<'EOF'
status="$(git rev-parse HEAD)"
EOF
expect 0 zsh zsh-status-in-grep-alternation-ok <<'EOF'
brain get x --type papercut | grep -n -i 'duplicate of\|status=\|done' | head
EOF
expect 0 zsh zsh-status-in-dquoted-arg-ok <<'EOF'
brain papercut close x --status verified --evidence "outcome.txt says status=ok"
EOF
expect 0 zsh zsh-status-key-in-url-ok <<'EOF'
last-stack-forge-api 'repos/o/r/pulls?status=open&limit=5' --jq '.[] | .number'
EOF
expect 2 zsh zsh-mapfile <<'EOF'
mapfile -t slugs < slugs.txt
EOF
expect 0 bash bash-mapfile-ok <<'EOF'
mapfile -t slugs < slugs.txt
EOF

expect 2 zsh zsh-word-split-scalar <<'EOF'
FILES="a.rs b.rs c.rs"; for rel in $FILES; do echo "$rel"; done
EOF
expect 2 zsh zsh-word-split-braced <<'EOF'
for rel in ${FILES}; do echo "$rel"; done
EOF
expect 2 zsh zsh-word-split-before-do-on-next-line <<'EOF'
for slug in $slugs
do
  echo "$slug"
done
EOF
expect 0 bash bash-word-split-ok <<'EOF'
FILES="a.rs b.rs c.rs"; for rel in $FILES; do echo "$rel"; done
EOF
expect 0 zsh zsh-word-split-array-ok <<'EOF'
FILES=(a.rs b.rs c.rs); for rel in "${FILES[@]}"; do echo "$rel"; done
EOF
expect 0 zsh zsh-word-split-array-unquoted-ok <<'EOF'
FILES=(a.rs b.rs c.rs); for rel in ${FILES[@]}; do echo "$rel"; done
EOF
expect 0 zsh zsh-word-split-quoted-ok <<'EOF'
for rel in "$FILES"; do echo "$rel"; done
EOF
expect 0 zsh zsh-word-split-cmdsub-ok <<'EOF'
for rel in $(git diff --name-only); do echo "$rel"; done
EOF
expect 0 zsh zsh-word-split-literal-ok <<'EOF'
for rel in a.rs b.rs c.rs; do echo "$rel"; done
EOF
expect 0 zsh zsh-word-split-glob-ok <<'EOF'
for rel in *.rs; do echo "$rel"; done
EOF
expect 0 zsh zsh-word-split-positional-ok <<'EOF'
for arg in "$@"; do echo "$arg"; done
EOF

# --- mktemp-suffix ------------------------------------------------------------
# BSD mktemp substitutes a run of X's only at the END of the template. The suffix
# form creates the LITERAL name, so the first call succeeds and every later call
# with that template fails until someone deletes it -- measured 2026-10-03, see
# papercut-mktemp-same-template-collides-within-one-second-20260925. Both
# recorded instances were written as agent commands, which is this guard's surface.
expect 2 bash mktemp-suffix-json <<'EOF'
f=$(mktemp "$TMPDIR/card.XXXXXX.json")
EOF
expect 2 bash mktemp-suffix-recorded-instance <<'EOF'
out=$(mktemp "${TMPDIR:-/tmp}/cardx.XXXXXX.json")
EOF
expect 2 bash mktemp-suffix-unquoted <<'EOF'
mktemp /tmp/card.XXXXXX.json
EOF
expect 2 bash mktemp-suffix-after-flags <<'EOF'
mktemp -t card.XXXXXX.json
EOF
expect 2 zsh mktemp-suffix-dir-form <<'EOF'
D=$(mktemp -d "$TMPDIR/probe.XXXXXX.d")
EOF
expect 0 bash mktemp-x-at-end-ok <<'EOF'
f=$(mktemp "${TMPDIR:-/tmp}/card.XXXXXX")
EOF
expect 0 bash mktemp-dir-x-at-end-ok <<'EOF'
D=$(mktemp -d "$TMPDIR/probe.XXXXXX")
EOF
expect 0 bash mktemp-unquoted-x-at-end-ok <<'EOF'
mktemp /tmp/card.XXXXXX
EOF
# The matcher is scoped to mktemp's own argument token: the character class cannot
# cross a space or a quote, so an unrelated X run elsewhere on the line is not a
# match. A whole-line matcher would reject this, which is the false-positive class
# that makes a fleet-wide guard worse than none.
expect 0 bash mktemp-unrelated-xxx-after-ok <<'EOF'
D=$(mktemp -d "$T/x.XXXXXX") && echo XXXy
EOF
expect 0 bash mktemp-unrelated-xxx-before-ok <<'EOF'
echo XXXy; mktemp -d "$T/a.XXXXXX"
EOF
expect 0 bash mktemp-no-template-ok <<'EOF'
mktemp -d
EOF
# An UNQUOTED template inside $( ) ends at the closing paren, not at a quote. The
# first draft of this rule excluded only whitespace and quotes after the X run, so
# it rejected both of these -- and both are correct, shipped agent prose
# (routines/lastdb-refcount-audit.md, skills/app-identity-dogfood/SKILL.md). The
# repo's own hooks-guards test is what caught it. Shell punctuation after the X run
# means the run IS at the end.
expect 0 bash mktemp-unquoted-cmdsub-ok <<'EOF'
work="$(mktemp -d /private/tmp/lastdb-refcount-audit.XXXXXX)"
EOF
expect 0 bash mktemp-unquoted-cmdsub-bare-ok <<'EOF'
WORK=$(mktemp -d /tmp/appident-dogfood.XXXXXX)
EOF
expect 0 bash mktemp-semicolon-after-ok <<'EOF'
tmp=$(mktemp -d "$TMPDIR/x.XXXXXX"); echo "$tmp"
EOF
expect 0 bash mktemp-pipe-after-ok <<'EOF'
mktemp -d $TMPDIR/x.XXXXXX | head -1
EOF
expect 0 bash mktemp-suffix-escape <<'EOF'
f=$(mktemp "$T/c.XXXXXX.json")  # shell-lint-ok: deliberate literal path
EOF

# --- home-root-scan -----------------------------------------------------------
expect 2 bash home-root-find-path-first <<'EOF'
find "$HOME" -maxdepth 4 -name "feature_catalog.toml"
EOF
expect 2 bash home-root-find-unquoted <<'EOF'
find $HOME -maxdepth 4 -name x
EOF
expect 2 bash home-root-find-tilde <<'EOF'
find ~ -maxdepth 2
EOF
expect 2 bash home-root-du-flags-first <<'EOF'
du -sh "$HOME" 2>/dev/null
EOF
expect 2 bash home-root-downloads-direct <<'EOF'
ls -la ~/Downloads
EOF
expect 2 bash home-root-desktop-direct <<'EOF'
du -sh "$HOME/Desktop" 2>/dev/null
EOF
expect 0 bash home-root-scoped-code-ok <<'EOF'
find "$HOME/code" -maxdepth 4 -name "*.toml"
EOF
expect 0 bash home-root-scoped-dotdirs-ok <<'EOF'
find "$HOME/.routines" "$HOME/.last-stack" "$HOME/.fkanban" -maxdepth 4 -name x
EOF
expect 0 bash home-root-unrelated-home-mention-ok <<'EOF'
if [ -d "$HOME/code" ]; then find "$workspace" -maxdepth 3 -name x; fi
EOF
# The matcher used to model a command as `<scanner> <flags...> <path>`, and
# was wrong in BOTH directions because real commands are not that shape.
# Brain: papercut-home-root-scan-matcher-assumes-scanner-flags-path-so-it-rejects-a-quoted-pattern-and-misses-grep-r-home-20261004
#
# False POSITIVE: the home token was wrapped in an OPTIONAL quote on each
# side, so an UNBALANCED opening quote was accepted and a quoted REGEX
# PATTERN containing the home path read as a path argument -- the `|` that
# follows an alternation satisfied the trailing [;&|)] as if it were a pipe.
# The files are named explicitly; nothing is walked. Hit three times in one
# agent pass. The negative fixtures must carry the `|`, because without it
# the branch is never reached (an absent value proves nothing).
expect 0 bash home-root-dquoted-pattern-named-files-ok <<'EOF'
grep -nE "$HOME|~/" a.sh b.sh
EOF
expect 0 bash home-root-squoted-pattern-named-files-ok <<'EOF'
grep -nE '$HOME|needle' a.sh
EOF
expect 0 bash home-root-pattern-naming-scoped-path-ok <<'EOF'
grep -rn "$HOME/code" a.sh
EOF
#
# False NEGATIVE, and the costlier half: grep/rg/ag take their pattern
# POSITIONALLY, so the natural spelling of the hazard put a non-flag token
# between the scanner and the path and the flags-only regex never saw it.
# A recursive grep of $HOME is exactly what raises the macOS TCC prompt and
# blocks an unattended run until a human clicks it. All four of these PASSED
# before 2026-10-04 while `find "$HOME" -name x` was correctly rejected.
expect 2 bash home-root-grep-r-pattern-then-home <<'EOF'
grep -rn needle "$HOME"
EOF
expect 2 bash home-root-grep-r-pattern-then-tilde <<'EOF'
grep -rn needle ~
EOF
expect 2 bash home-root-rg-pattern-then-home <<'EOF'
rg -n needle "$HOME"
EOF
expect 2 bash home-root-rg-no-flags-then-home <<'EOF'
rg needle "$HOME"
EOF
expect 2 bash home-root-grep-squoted-pattern-then-home <<'EOF'
grep -rn 'need le' "$HOME"
EOF
# The widening must not reach a BOUNDED path, which is the whole point of the
# guard's advice line.
expect 0 bash home-root-grep-r-pattern-scoped-ok <<'EOF'
grep -rn needle "$HOME/code"
EOF
expect 0 bash home-root-rg-maxdepth-scoped-ok <<'EOF'
rg --max-depth 2 needle "$HOME/code"
EOF
expect 0 bash home-root-grep-named-files-ok <<'EOF'
grep -n needle a.sh b.sh
EOF

expect 2 bash home-root-while-do-find <<'EOF'
while true; do find "$HOME" -maxdepth 2 -name x; break; done
EOF
expect 2 bash home-root-if-then-du <<'EOF'
if true; then du -sh "$HOME"; fi
EOF
expect 2 bash home-root-for-do-find <<'EOF'
for d in a b; do find "$HOME" -maxdepth 2 -name x; done
EOF
expect 0 bash home-root-then-du-scoped-ok <<'EOF'
if true; then du -sh "$HOME/code"; fi
EOF
expect 0 bash home-root-todo-word-not-do-keyword-ok <<'EOF'
todo find "$HOME/code" -maxdepth 2 -name x
EOF
expect 0 bash home-root-prose-mention-ok <<'EOF'
echo "the file was not found in Downloads"
EOF
expect 0 bash home-root-shell-lint-ok-escape <<'EOF'
find "$HOME" -maxdepth 2  # shell-lint-ok: auditing top-level layout
EOF
expect 0 bash home-root-home-scan-ok-escape <<'EOF'
find "$HOME" -maxdepth 4 \( -path "$HOME/Desktop" -o -path "$HOME/Downloads" \) -prune -o -print 2>/dev/null  # home-scan-ok: full audit
EOF

# --- piped-count-false-zero ---------------------------------------------------
# A pipeline whose PRODUCER is a path under $HOME, feeding a filter that
# collapses the stream to a count or a boolean. When the path does not exist the
# producer exits 127, stdout is EMPTY, and grep -c answers 0 -- the same answer
# as "the symbol is absent". The error is one-directional: a missing producer
# can only LOWER the count, so the shape manufactures "the fix never shipped"
# and can never manufacture "it shipped".
#
# Measured 2026-10-03: the preceding papercut-resolver pass prescribed
#   bash ~/.local/bin/last-stack-routine-shell-lint --list-rules | grep -c stat-local-zulu
# as the proof PR 212 installed and recorded "it reads 0 before this change --
# measured, not predicted". That path has never existed; the rule WAS installed
# and the resolved tree answered 6. Both the baseline and the post-fix reading
# came from the same absent producer, so they agreed at 0 and the before/after
# table looked like a clean negative baseline.
expect 2 bash piped-count-exact-recorded-case <<'EOF'
bash ~/.local/bin/last-stack-routine-shell-lint --list-rules | grep -c stat-local-zulu
EOF
# The canary-tree form that resolver protocol items 29 and 135 prescribe, on a
# path item 45 separately documents as intermittently absent while host-track
# re-stages it. Those two notes combine into exactly this defect.
expect 2 bash piped-count-canary-strings <<'EOF'
strings ~/.host-track/apps/loom/canary/dist/loom | grep -c newSymbol
EOF
# The path IS the command (no executor word).
expect 2 bash piped-count-bare-path-producer <<'EOF'
~/.local/bin/host-track status | grep -c main_unpublished
EOF
expect 2 bash piped-count-wc-l-sink <<'EOF'
bash "$HOME/.last-stack/bin/last-stack-why-stopped" --json | wc -l
EOF
expect 2 bash piped-count-grep-q-sink <<'EOF'
"${HOME}/.local/state/last-stack/artifacts/current/bin/x" --flag | grep -q sym
EOF
expect 2 bash piped-count-after-semicolon <<'EOF'
cd /tmp; bash $HOME/.last-stack/bin/x --y | grep -c sym
EOF
# THE PRESCRIBED FIX FORM. The deny message prints this, so the rule must not
# refuse the advice it gives (the stat-local-zulu block pins the same property).
expect 0 bash piped-count-fix-form-rc-capture-ok <<'EOF'
bash "$HOME/.local/bin/x" --flag > out 2> err; echo "rc=$?"; grep -c sym out
EOF
# Counting from a resolved FILE is the other prescribed form: a missing file
# makes grep itself exit 2 and say so, where a missing producer says nothing.
expect 0 bash piped-count-file-arg-ok <<'EOF'
grep -c sym "$(readlink -f ~/.last-stack/bin/last-stack-routine-shell-lint)"
EOF
# A producer resolved from PATH is not this rule: jq, git, rg and a PATH command
# name do not come and go with delivery state.
expect 0 bash piped-count-path-producer-ok <<'EOF'
jq -r '.rows[].slug' /tmp/f.json | grep -c foo
EOF
expect 0 bash piped-count-host-track-on-path-ok <<'EOF'
host-track status | grep -c main_unpublished
EOF
# A $HOME path as some OTHER command's argument is not a $HOME producer.
expect 0 bash piped-count-home-path-as-argument-ok <<'EOF'
rg -n 'sym' ~/.last-stack/bin | wc -l
EOF
expect 0 bash piped-count-git-c-home-repo-ok <<'EOF'
git -C ~/code/edgevector/last-stack log --oneline | wc -l
EOF
expect 0 bash piped-count-ls-worktrees-ok <<'EOF'
ls ~/.fkanban/worktrees/ | wc -l
EOF
# cat/head/tail of a DATA file under $HOME is a different hazard (read the rc)
# and is common and legitimate, so the executor list excludes it deliberately.
expect 0 bash piped-count-cat-data-file-ok <<'EOF'
cat ~/.last-stack/logs/routine-heartbeats.log | grep -c ERROR
EOF
# A non-counting sink keeps the stream, so a missing producer shows up.
expect 0 bash piped-count-jq-sink-ok <<'EOF'
bash ~/.local/bin/x --flag | jq -r .
EOF
# System paths are excluded on purpose: CLAUDE.md tells agents to call
# /usr/bin/grep, and /usr/bin, /bin and /opt/homebrew do not move with a deploy.
expect 0 bash piped-count-usr-bin-producer-ok <<'EOF'
/usr/bin/grep -rn sym /opt/homebrew/bin | wc -l
EOF
expect 0 bash piped-count-shell-lint-ok-escape <<'EOF'
bash ~/.local/bin/x --list | grep -c sym   # shell-lint-ok: [ -x ] asserted on the line above
EOF
# This rule is NOT the home-root scanner, so it must not inherit that rule's
# older escape phrase. home-scan-ok silences home-root-scan only.
expect 2 bash piped-count-home-scan-ok-does-not-silence <<'EOF'
bash ~/.local/bin/x --list | grep -c sym   # home-scan-ok: unrelated
EOF

# --- escape hatch and usage --------------------------------------------------
expect 0 bash escape-hatch <<'EOF'
sed -i 's/a/b/' f   # shell-lint-ok: GNU sed on the PC
EOF
if "$LINT" --shell fish </dev/null 2>/dev/null; then
  echo "FAIL [bad-shell] want usage error" >&2; fail=1
fi
msg="$(printf '%s\n' "jq '(.a)?.b' x" | "$LINT" 2>&1 || true)"
case "$msg" in
  *"rule=jq-optional-call"*"Do NOT file a papercut"*) ;;
  *) echo "FAIL [message] rejection text lacks rule id or no-refile line: $msg" >&2; fail=1 ;;
esac

# --- Claude hook -------------------------------------------------------------
hook_json() {
  jq -n --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}' \
    | LAST_STACK_ROUTINE_SHELL_LINT="$LINT" "$HOOK"
}
out="$(hook_json 'while true; do read -t 5 < /dev/zero; done')"
if ! printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null; then
  echo "FAIL [hook-deny] got: $out" >&2; fail=1
fi
out="$(hook_json 'status=$(git rev-parse HEAD)')"
if ! printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("zsh-status")' >/dev/null; then
  echo "FAIL [hook-zsh-mode] got: $out" >&2; fail=1
fi
out="$(hook_json 'echo ok')"
if [ -n "$out" ]; then
  echo "FAIL [hook-allow] want no output, got: $out" >&2; fail=1
fi
out="$(hook_json 'find "$HOME" -maxdepth 4 -name x')"
if ! printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("home-root-scan")' >/dev/null; then
  echo "FAIL [hook-home-root-scan] got: $out" >&2; fail=1
fi
out="$(printf 'not json' | LAST_STACK_ROUTINE_SHELL_LINT="$LINT" "$HOOK")"
if [ -n "$out" ]; then
  echo "FAIL [hook-fail-open] want no output on bad input, got: $out" >&2; fail=1
fi
out="$(jq -n '{tool_name: "Bash", tool_input: {command: "echo ok"}}' \
  | LAST_STACK_ROUTINE_SHELL_LINT="$tmp/missing" "$HOOK")"
if [ -n "$out" ]; then
  echo "FAIL [hook-missing-lint] want fail-open, got: $out" >&2; fail=1
fi

# --- Codex routine entry snippet (zsh -c -> bash, via ~/.zshenv) -------------
if command -v zsh >/dev/null 2>&1; then
  zdot="$tmp/zdot"
  mkdir -p "$zdot"
  printf '. %q\n' "$SNIPPET" > "$zdot/.zshenv"
  run_z() {
    # run_z <env...> -- <command>
    local envs=()
    while [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" ZDOTDIR="$zdot" \
      LAST_STACK_ROUTINE_SHELL_LINT="$LINT" "${envs[@]}" /bin/zsh -c "$1"
  }

  # Two of the cases below feed the snippet a DELIBERATE HAZARD, because that
  # is what the lint is supposed to reject. The snippet FAILS OPEN when the
  # lint cannot answer -- correct policy, since a missing lint must not block
  # every routine command -- and then the hazard RUNS.
  #
  # Measured 2026-10-04 against a lint stub that exits 1 at startup, the shape
  # a careless edit to the regex block produces:
  #
  #   snippet-lint-reject     `while true; do read -t 1 < /dev/zero; done`
  #                           spins a core forever. rc 124 at an 8s bound.
  #   snippet-home-root-scan  walks $HOME and reaches the TCC-protected
  #                           folders (`/Users/<u>/Pictures/Photos
  #                           Library.photoslibrary: Operation not permitted`).
  #                           rc 124 at an 8s bound. On an interactive host
  #                           that is the macOS privacy dialog that BLOCKS
  #                           until a human clicks -- the exact harm this rule
  #                           exists to prevent, produced by the test for it.
  #
  # That is the hang this suite used to show as empty stdout past 90s, and a
  # CI shard burns its whole ~2803s deadline on it. The startup guard at the
  # top of this file removes the common cause; this removes the mechanism.
  #
  # Two details that are not optional:
  #  * The bound must resolve under a routinesd PATH
  #    (/usr/gnu/bin:/usr/local/bin:/bin:/usr/bin:.), which has NEITHER
  #    gtimeout NOR timeout and DOES have /usr/bin/perl. So the perl arm is
  #    the production arm, not the fallback.
  #  * `perl -e alarm` bounds the DIRECT CHILD only, and a grandchild keeps
  #    the write end of a `$(...)` pipe open, so the caller blocks for the
  #    full run anyway. Output therefore goes to a FILE and is read back --
  #    never captured with a command substitution. Residual, stated rather
  #    than hidden: on the perl arm the alarm reaches `env`, not the zsh under
  #    it, so a spinning grandchild can outlive the bound. The suite still
  #    reports correctly and does not block; `gtimeout`/`timeout` kill the
  #    whole process group and leave nothing behind, which is why they are
  #    preferred when present.
  # Brain: papercut-routine-shell-lint-fixture-suite-hangs-instead-of-failing-when-the-lint-binary-cannot-start-20261004
  # The seconds are appended at call time, so a single case can tighten the
  # bound without rebuilding the array.
  Z_BOUND_SECS="${LAST_STACK_SHELL_LINT_TEST_BOUND:-20}"
  z_bounder=()
  if command -v gtimeout >/dev/null 2>&1; then z_bounder=(gtimeout)
  elif command -v timeout >/dev/null 2>&1; then z_bounder=(timeout)
  elif command -v perl >/dev/null 2>&1; then z_bounder=(perl -e 'alarm shift; exec @ARGV')
  fi
  [ "${#z_bounder[@]}" -gt 0 ] || { echo "FAIL [bound] no gtimeout, timeout or perl; a hazard fixture would run unbounded" >&2; exit 1; }

  # run_z_bounded <env...> -- <command>
  # Writes merged output to $tmp/hazard.out, sets z_rc, z_out and z_bounded.
  # Reports nothing: the self-check below WANTS the bound to fire, so the
  # verdict belongs to the caller.
  run_z_bounded() {
    local envs=()
    while [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    z_rc=0
    z_bounded=0
    # The bounder goes OUTSIDE `env -i`: the inner PATH is deliberately
    # restricted to /usr/bin:/bin:/usr/sbin:/sbin to model a routine shell, so
    # a bounder named inside it resolves to `env: gtimeout: No such file or
    # directory` (rc 127) and bounds nothing. This test caught that on its
    # first run.
    "${z_bounder[@]}" "$Z_BOUND_SECS" \
      env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" ZDOTDIR="$zdot" \
      LAST_STACK_ROUTINE_SHELL_LINT="${Z_LINT:-$LINT}" "${envs[@]}" \
      /bin/zsh -c "$1" > "$tmp/hazard.out" 2>&1 || z_rc=$?
    z_out="$(cat "$tmp/hazard.out")"
    case "$z_rc" in 124|142|137) z_bounded=1 ;; esac
    return 0
  }

  # hazard_case <label> <env...> -- <command>
  # The one callers use. A bound that fires is reported as the lint having
  # failed open, never as a slow test.
  #
  # This FAIL arm is deliberately double-protected: with it removed, each
  # caller's own `[ "$z_rc" = 2 ]` still fails, because a bounded run returns
  # 124/142/137. The arm exists for the DIAGNOSIS, not for the verdict -- it
  # is the difference between `want 2, got 124` and a line naming the
  # mechanism. A mutation probe of it is therefore green, and that is correct
  # rather than a weak guard.
  #
  # The bound itself IS single-protected, and probing it is the one case in
  # this file where `--expect-red-on` must be omitted: remove the bound and
  # the suite does not fail with an assertion, it stops producing output at
  # all. The probe needs an externally bounded --test and reads `test_rc=124`
  # as its verdict.
  hazard_case() {
    local label="$1"; shift
    run_z_bounded "$@"
    if [ "$z_bounded" = 1 ]; then
      echo "FAIL [$label] the hazard fixture RAN and was stopped by the ${Z_BOUND_SECS}s bound (rc=$z_rc); the lint failed open instead of rejecting it" >&2
      fail=1
    fi
  }
  routine_env=(DRIVEN_BY=routine CODEX_THREAD_ID=test-thread)

  got="$(run_z "${routine_env[@]}" -- 'echo "${BASH_VERSION:+bash}${ZSH_VERSION:+zsh}"')"
  [ "$got" = bash ] || { echo "FAIL [snippet-bash] want bash, got '$got'" >&2; fail=1; }

  got="$(run_z "${routine_env[@]}" -- 'status=7; echo "s=$status"')"
  [ "$got" = "s=7" ] || { echo "FAIL [snippet-status] want s=7, got '$got'" >&2; fail=1; }

  got="$(run_z "${routine_env[@]}" -- 'spec="fold 2147"; set -- $spec; echo "$1|$2"')"
  [ "$got" = "fold|2147" ] || { echo "FAIL [snippet-wordsplit] got '$got'" >&2; fail=1; }

  set +e
  run_z "${routine_env[@]}" -- 'exit 5' ; rc=$?
  set -e
  [ "$rc" = 5 ] || { echo "FAIL [snippet-exit-code] want 5, got $rc" >&2; fail=1; }

  # The bound's own arm is only reachable with a lint that fails open, which
  # is exactly the state the two cases below are protecting against. Left
  # untested it is coverage that cannot fail, so exercise it here against a
  # stub that accepts everything -- the real lint is untouched, and the
  # fixture is the same spinner, held to 3 seconds.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/permissive-lint"
  chmod +x "$tmp/permissive-lint"
  Z_LINT="$tmp/permissive-lint" Z_BOUND_SECS=3 \
    run_z_bounded "${routine_env[@]}" -- 'while true; do read -t 1 < /dev/zero; done'
  [ "$z_bounded" = 1 ] || {
    echo "FAIL [bound-self-check] a fail-open lint let the spinner run and the bound did NOT stop it (rc=$z_rc)" >&2
    fail=1
  }

  hazard_case snippet-lint-reject "${routine_env[@]}" -- 'while true; do read -t 1 < /dev/zero; done'
  [ "$z_rc" = 2 ] || { echo "FAIL [snippet-lint-reject] want 2, got $z_rc: $z_out" >&2; fail=1; }

  # The gap this rule closes: a Codex routine command (not a Claude Code
  # Bash tool call, so hooks/no-home-root-scan.sh never runs) that scans the
  # home root must still be rejected, by the shared lint alone.
  hazard_case snippet-home-root-scan "${routine_env[@]}" -- 'find "$HOME" -maxdepth 4 -name x'
  [ "$z_rc" = 2 ] && printf '%s' "$z_out" | grep -q 'rule=home-root-scan' \
    || { echo "FAIL [snippet-home-root-scan] want rc=2 rule=home-root-scan, got $z_rc: $z_out" >&2; fail=1; }

  got="$(run_z -- 'echo "${ZSH_VERSION:+zsh}"')"
  [ "$got" = zsh ] || { echo "FAIL [snippet-not-routine] want zsh, got '$got'" >&2; fail=1; }

  got="$(run_z DRIVEN_BY=routine -- 'echo "${ZSH_VERSION:+zsh}"')"
  [ "$got" = zsh ] || { echo "FAIL [snippet-not-codex] want zsh, got '$got'" >&2; fail=1; }

  got="$(run_z "${routine_env[@]}" LAST_STACK_ROUTINE_SHELL=zsh -- 'echo "${ZSH_VERSION:+zsh}"')"
  [ "$got" = zsh ] || { echo "FAIL [snippet-opt-out] want zsh, got '$got'" >&2; fail=1; }

  got="$(run_z "${routine_env[@]}" CLAUDECODE=1 -- 'echo "${ZSH_VERSION:+zsh}"')"
  [ "$got" = zsh ] || { echo "FAIL [snippet-claude] want zsh, got '$got'" >&2; fail=1; }

  # Codex wrapper form: outer zsh execs an inner zsh -c; the inner one
  # (which reads .zshenv again) is the one that becomes bash.
  got="$(run_z "${routine_env[@]}" -- "exec '/bin/zsh' -c 'status=4; echo \"w=\$status \${BASH_VERSION:+bash}\"'")"
  [ "$got" = "w=4 bash" ] || { echo "FAIL [snippet-codex-wrapper] got '$got'" >&2; fail=1; }
  set +e
  run_z "${routine_env[@]}" -- "exec '/bin/zsh' -c 'cat <<'\"'\"'EOF'\"'\"'
sed -i 's/a/b/' f is only text here
EOF'" >/dev/null 2>&1; rc=$?
  set -e
  [ "$rc" = 0 ] || { echo "FAIL [snippet-wrapper-heredoc-data] want 0, got $rc" >&2; fail=1; }

  # A zsh script file has no -c string and stays zsh.
  printf 'echo "${ZSH_VERSION:+zsh}"\n' > "$tmp/script.zsh"
  got="$(env -i HOME="$HOME" PATH=/usr/bin:/bin ZDOTDIR="$zdot" "${routine_env[@]}" /bin/zsh "$tmp/script.zsh")"
  [ "$got" = zsh ] || { echo "FAIL [snippet-script] want zsh, got '$got'" >&2; fail=1; }
fi

# --- setup: managed ~/.zshenv block is idempotent and last ------------------
(
  set -e
  eval "$(sed -n '/^strip_managed_md_block()/,/^}/p' "$ROOT/setup")"
  eval "$(sed -n "/^RSZ_START=/p;/^RSZ_END=/p" "$ROOT/setup")"
  eval "$(sed -n '/^install_routine_shell_zshenv()/,/^}/p' "$ROOT/setup")"
  SOURCE_ROOT="$ROOT"
  ZDOTDIR="$tmp/setup-z"
  mkdir -p "$ZDOTDIR"
  printf 'export PATH="/x/bin:$PATH"\n' > "$ZDOTDIR/.zshenv"
  install_routine_shell_zshenv >/dev/null
  printf 'export LATER=1\n' >> "$ZDOTDIR/.zshenv"
  install_routine_shell_zshenv >/dev/null
  [ "$(grep -c 'codex-routine-bash.zsh' "$ZDOTDIR/.zshenv")" = 1 ]
  [ "$(tail -n 1 "$ZDOTDIR/.zshenv")" = "$RSZ_END" ]
  grep -q '^export PATH="/x/bin:$PATH"$' "$ZDOTDIR/.zshenv"
  grep -q '^export LATER=1$' "$ZDOTDIR/.zshenv"
) || { echo "FAIL [setup-zshenv] block not idempotent or not last" >&2; fail=1; }

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "ok last-stack-routine-shell-lint"
