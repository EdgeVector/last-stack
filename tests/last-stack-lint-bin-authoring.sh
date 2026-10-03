#!/usr/bin/env bash
# Behavioural test for bin/last-stack-lint-bin-authoring against a fixture
# tree, then the real tree. The lint exists because a new helper shipped in
# four drafts: a bash wrapper with a Python heredoc, then an rglob over
# ~/.fkanban/worktrees that ran for minutes and timed out
# (brain papercut-agent-zero-llm-cli-bash-python-heredoc-rglob).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
LINT="$ROOT/bin/last-stack-lint-bin-authoring"
tmp="$(mktemp -d "${TMPDIR:-${TMP:-${TEMP:-/tmp}}}/last-stack-lint-bin-authoring-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL last-stack-lint-bin-authoring: $*" >&2; exit 1; }

[ -x "$LINT" ] || fail "linter must ship executable"

fx="$tmp/tree"
mkdir -p "$fx/bin" "$fx/lib" "$fx/hooks" "$fx/skills/demo/scripts" "$fx/config" "$fx/tests/fixtures"

# A bounded shell walk over a workspace root: allowed.
cat >"$fx/bin/good-find" <<'EOF'
#!/usr/bin/env bash
find "$HOME/.fkanban/worktrees" -maxdepth 3 -name feature_catalog.toml
fd --max-depth 2 Cargo.toml ~/code/edgevector
# find ~/code/edgevector -name x   (a comment is not a walk)
EOF

# A depth-free shell walk over a workspace root: hard finding.
cat >"$fx/bin/bad-find" <<'EOF'
#!/usr/bin/env bash
find "$HOME/.fkanban/worktrees" -name feature_catalog.toml
EOF

# A Python recursive walk with no stated bound: hard finding.
cat >"$fx/bin/bad-rglob" <<'EOF'
#!/usr/bin/env python3
from pathlib import Path
for p in (Path.home() / "code/edgevector").rglob("feature_catalog.toml"):
    print(p)
EOF

# The same walk with its bound stated: allowed.
cat >"$fx/skills/demo/scripts/ok-rglob.py" <<'EOF'
#!/usr/bin/env python3
from pathlib import Path
for p in Path("/tmp/scratch").rglob("*.md"):  # walk-ok: scratch dir, three files
    print(p)
EOF

# A glob without ** is one level, not a walk: allowed.
cat >"$fx/lib/one-level.py" <<'EOF'
from pathlib import Path
print(sorted(Path("routines").glob("*.md")))
EOF

# A bash helper that nests a Python program: soft finding, baseline-tracked.
cat >"$fx/bin/nest-old" <<'EOF'
#!/usr/bin/env bash
python3 - <<'PY'
print("old nest")
PY
EOF
cat >"$fx/bin/nest-new" <<'EOF'
#!/usr/bin/env bash
out="$(python3 - <<'PY'
print("new nest")
PY
)"
EOF

# Fixtures are never linted.
cat >"$fx/tests/fixtures/bad.sh" <<'EOF'
find ~/code/edgevector -name x
EOF

baseline="$fx/config/bin-authoring-baseline.tsv"
printf '# path\nbin/nest-old\n' >"$baseline"

# 1. Gate: two hard findings plus one new nest -> exit 1, each named.
set +e
out="$("$LINT" --ci --root "$fx" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "gate should exit 1 on findings, got $rc: $out"
printf '%s' "$out" | grep -q $'find\tbin/bad-find\t2' || fail "missing bad-find finding: $out"
printf '%s' "$out" | grep -q $'walk\tbin/bad-rglob\t3' || fail "missing bad-rglob finding: $out"
printf '%s' "$out" | grep -q '^bin/nest-new$' || fail "missing new nest: $out"
printf '%s' "$out" | grep -q 'bin/good-find' && fail "bounded find must pass: $out"
printf '%s' "$out" | grep -q 'ok-rglob' && fail "walk-ok line must pass: $out"
printf '%s' "$out" | grep -q 'one-level' && fail "single-level glob must pass: $out"
printf '%s' "$out" | grep -q 'nest-old' && fail "baselined nest must not be reported as new: $out"
printf '%s' "$out" | grep -q 'fixtures' && fail "fixtures must not be linted: $out"
printf '%s' "$out" | grep -q 'last-stack-locate-file' || fail "deny text must name the bounded replacement: $out"

# 2. Report mode never fails, and counts every finding.
out="$("$LINT" --report --root "$fx" 2>&1)" || fail "--report must exit 0"
printf '%s' "$out" | grep -q 'hard=2 stat_zulu=0 host_paths=0 nests=2 new_nests=1 retired_nests=0' || fail "report counts wrong: $out"

# 3. Remove the hard findings; the new nest alone still fails the gate.
rm "$fx/bin/bad-find" "$fx/bin/bad-rglob"
set +e
out="$("$LINT" --ci --root "$fx" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "a new nest alone must fail the gate, got $rc: $out"
printf '%s' "$out" | grep -q 'ONE language' || fail "nest deny must say one language: $out"

# 4. Rewriting the baseline admits the nest; then the gate is green.
"$LINT" --write-baseline --root "$fx" >/dev/null
grep -q '^bin/nest-new$' "$baseline" || fail "--write-baseline must record the nest"
grep -q '^bin/nest-old$' "$baseline" || fail "--write-baseline must keep the old nest"
out="$("$LINT" --ci --root "$fx" 2>&1)" || fail "gate must pass once the baseline holds every nest: $out"
printf '%s' "$out" | grep -q '^ok last-stack-lint-bin-authoring hard=0 stat_zulu=0 host_paths=0 nests=2' || fail "pass line wrong: $out"

# 5. A retired nest is reported, never failed: the baseline only shrinks.
rm "$fx/bin/nest-old"
out="$("$LINT" --ci --root "$fx" 2>&1)" || fail "a retired nest must not fail the gate: $out"
printf '%s' "$out" | grep -q 'retired=1' || fail "retired nest must be counted: $out"

# 6. Help exits 0 on stdout with nothing on stderr; a bad flag exits 2.
help_err="$("$LINT" --help 2>&1 >/dev/null)" || fail "--help must exit 0"
[ -z "$help_err" ] || fail "--help must not write to stderr: $help_err"
"$LINT" --help | grep -q 'write-baseline' || fail "--help must print the usage"
set +e
"$LINT" --no-such-flag >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "unknown flag must exit 2, got $rc"

# 7. The real tree is green: no unbounded walk, and no nest outside the baseline.
out="$("$LINT" --ci 2>&1)" || fail "the real tree must pass the gate: $out"

# 8. The argv-token class, on its own fixture tree so the counts above stay readable.
# `ps aux` lists argv to every local account, so an auth header built into a child's
# command line publishes the Forge token machine-wide:
# papercut-forge-git-extraheader-token-visible-in-ps-20260923 (p0) and
# papercut-last-stack-forge-api-token-on-curl-argv-20260924 (p1).
at="$tmp/argv-tree"
mkdir -p "$at/bin" "$at/lib" "$at/config"

# Baselined offender: reported, never failed.
cat >"$at/bin/argv-git-old" <<'EOF'
#!/usr/bin/env bash
exec git -c "http.http://localhost:3300/.extraHeader=Authorization: token $token" "$@"
EOF

# New offender: must fail the gate.
cat >"$at/bin/argv-curl-new" <<'EOF'
#!/usr/bin/env bash
curl -sS -H "Authorization: token $token" "$url"
EOF

# The safe environment form must not match.
cat >"$at/lib/argv-safe-env.sh" <<'EOF'
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0="http.http://localhost:3300/.extraHeader"
export GIT_CONFIG_VALUE_0="Authorization: token $token"
EOF

# The safe curl-config form must not match either.
cat >"$at/lib/argv-safe-curl.sh" <<'EOF'
printf 'header = "Authorization: token %s"\n' "$token" >"$f"
curl -sS -K "$f" "$url"
EOF

# A stated exception passes; a comment is not a call site.
cat >"$at/bin/argv-hatch" <<'EOF'
#!/usr/bin/env bash
# curl -H "Authorization: token $t" is what this used to do.
curl -sS -H "Authorization: token $token" "$url"  # argv-token-ok: probes the leak itself
EOF

printf '# path\nbin/argv-git-old\n' >"$at/config/forge-token-argv-baseline.tsv"

set +e
out="$("$LINT" --ci --root "$at" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "a new argv auth header must fail the gate, got $rc: $out"
printf '%s' "$out" | grep -q '^bin/argv-curl-new$' || fail "missing new argv site: $out"
printf '%s' "$out" | grep -q 'argv-git-old' && fail "baselined argv site must not be reported as new: $out"
printf '%s' "$out" | grep -q 'argv-safe-env' && fail "GIT_CONFIG_VALUE env form must pass: $out"
printf '%s' "$out" | grep -q 'argv-safe-curl' && fail "curl -K config form must pass: $out"
printf '%s' "$out" | grep -q 'argv-hatch' && fail "argv-token-ok line must pass: $out"
printf '%s' "$out" | grep -q 'last_stack_forge_export_git_config' || fail "deny text must name the safe git form: $out"
printf '%s' "$out" | grep -q 'last_stack_forge_curl_auth_config' || fail "deny text must name the safe curl form: $out"

# Admitting it into the baseline turns the gate green; removing it is only reported.
"$LINT" --write-baseline --root "$at" >/dev/null
grep -q '^bin/argv-curl-new$' "$at/config/forge-token-argv-baseline.tsv" \
  || fail "--write-baseline must record the argv site"
out="$("$LINT" --ci --root "$at" 2>&1)" || fail "gate must pass once the baseline holds every argv site: $out"
printf '%s' "$out" | grep -q 'argv_tokens=2 argv_baseline=2 argv_retired=0' || fail "argv pass line wrong: $out"
rm "$at/bin/argv-git-old"
out="$("$LINT" --ci --root "$at" 2>&1)" || fail "a retired argv site must not fail the gate: $out"
printf '%s' "$out" | grep -q 'argv_retired=1' || fail "retired argv site must be counted: $out"

# 9. The two helpers the p0/p1 papercuts name must stay OUT of the argv baseline.
# They are the reason this class exists; a regression in either one is a fresh leak.
#
# This covers the one path case 7 above cannot see. A reintroduced leak that is
# NOT baselined already fails the real-tree gate there; baselining it is what
# makes that gate pass, so accepting either of these two into the baseline is the
# only way the leak comes back quietly. Nothing to check when there is no
# baseline file -- the healthy state, since zero argv sites are accepted today --
# and the `[ -f ]` guard is load-bearing for a second reason: a bare grep on the
# absent path wrote "No such file or directory" to stderr on every gate run,
# which reads like a broken check and costs the next reader a detour.
real_argv_baseline="$ROOT/config/forge-token-argv-baseline.tsv"
if [ -f "$real_argv_baseline" ]; then
  for helper in bin/last-stack-forge-git bin/last-stack-forge-api; do
    grep -qx "$helper" "$real_argv_baseline" \
      && fail "$helper must not be baselined: it is the converted reference implementation"
  done
fi

# 10. The stat-local-zulu class, on its own fixture tree.
# BSD `stat -t` renders %F/%T in the LOCAL zone and emits a trailing Z as a
# LITERAL character, so the helper writes local time wearing a UTC marker --
# 25200s in the past on this host. It parses, sorts and compares cleanly against
# a real ...Z stamp, and the error is one-directional (always OLDER), so it
# manufactures stalls and never hides one. Measured twice: six recorded
# recurrences in last-stack-north-star-dashboard-run
# (papercut-north-star-dashboard-html-mtime-zulu-is-local, fixed instance-only
# 2026-09-23 with NO guard), then the class recurred in agent shell on
# 2026-10-03 and nearly became a p1 "the refresh agent is dead" finding
# (papercut-stat-t-format-prints-local-time-with-a-literal-z-...-20261003).
sz="$tmp/stat-zulu-tree"
mkdir -p "$sz/bin" "$sz/lib"

# The defect, in both format spellings.
cat >"$sz/bin/stat-lie-short" <<'EOF'
#!/usr/bin/env bash
mtime="$(stat -f '%Sm' -t '%FT%TZ' -- "$f")"
EOF
cat >"$sz/bin/stat-lie-long" <<'EOF'
#!/usr/bin/env bash
mtime="$(stat -f %Sm -t '%Y-%m-%dT%H:%M:%SZ' "$f")"
EOF

# TZ=UTC makes the value correct: must pass. This is the live spelling in
# bin/last-stack-north-star-dashboard-run, so a false positive here would turn
# the real-tree gate red.
cat >"$sz/bin/stat-tz-utc" <<'EOF'
#!/usr/bin/env bash
mtime="$(TZ=UTC stat -f '%Sm' -t '%Y-%m-%dT%H:%M:%SZ' "$f")"
EOF

# %Z is a real strftime conversion (it prints the zone NAME, honestly), not
# this defect: must pass.
cat >"$sz/lib/stat-zone-name.sh" <<'EOF'
mtime="$(stat -f '%Sm' -t '%FT%T%Z' "$f")"
EOF

# The two prescribed correct forms must pass. The second is the exact string
# the deny text prints, so this also pins that the advice does not trip the
# guard that prints it.
cat >"$sz/lib/stat-correct.sh" <<'EOF'
age_s=$(( $(date +%s) - $(stat -f %m -- "$f") ))
stamp="$(date -u -r "$(stat -f %m -- "$f")" +%FT%TZ)"
EOF

# A stated exception passes, and a comment is not a call site.
cat >"$sz/bin/stat-hatch" <<'EOF'
#!/usr/bin/env bash
# stat -f '%Sm' -t '%FT%TZ' is the shape this refuses.
printf '%s\n' "$(stat -f '%Sm' -t '%FT%TZ' "$f")"  # stat-zulu-ok: renders for a human who is told the zone
EOF

set +e
out="$("$LINT" --ci --root "$sz" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "a literal-Z stat format must fail the gate, got $rc: $out"
printf '%s' "$out" | grep -q $'stat-zulu\tbin/stat-lie-short\t2' || fail "missing short-format finding: $out"
printf '%s' "$out" | grep -q $'stat-zulu\tbin/stat-lie-long\t2' || fail "missing long-format finding: $out"
printf '%s' "$out" | grep -q 'stat-tz-utc' && fail "TZ=UTC form must pass: $out"
printf '%s' "$out" | grep -q 'stat-zone-name' && fail "honest %Z conversion must pass: $out"
printf '%s' "$out" | grep -q 'stat-correct' && fail "the prescribed date -u -r form must pass: $out"
printf '%s' "$out" | grep -q 'stat-hatch' && fail "stat-zulu-ok line must pass: $out"
printf '%s' "$out" | grep -q 'date -u -r' || fail "deny text must name the correct form: $out"
# The shared hard bucket's FAIL text is hard-coded to "unbounded walk(s)", so a
# stat finding routed there would be MISREPORTED. It has its own bucket and its
# own message; pin that the walk wording never appears for a stat-only tree.
printf '%s' "$out" | grep -q 'unbounded walk' && fail "a stat finding must not be reported as a walk: $out"
printf '%s' "$out" | grep -q 'LITERAL Z' || fail "deny text must name the defect: $out"

# Report mode counts them and never fails.
out="$("$LINT" --report --root "$sz" 2>&1)" || fail "--report must exit 0"
printf '%s' "$out" | grep -q 'hard=0 stat_zulu=2' || fail "stat_zulu report count wrong: $out"

# There is no baseline for this class: it is a HARD finding, so removing the
# two offenders is the only way to green. Unlike a nest, it cannot be accepted.
rm "$sz/bin/stat-lie-short" "$sz/bin/stat-lie-long"
out="$("$LINT" --ci --root "$sz" 2>&1)" || fail "gate must pass once the literal-Z formats are gone: $out"
printf '%s' "$out" | grep -q 'stat_zulu=0' || fail "pass line must carry stat_zulu=0: $out"

# ---------------------------------------------------------------------------
# Rule 5: a host-state default that bypasses the file's own host_path() helper.
#
# Scope is the point of the rule: it fires only on files that DEFINE host_path(,
# so adopting the helper opts a program in and an unrelated helper can never be
# flagged. The negative cases below are what make that claim testable.
# papercut-load-collector-alert-rules-read-real-host-state-with-no-hermetic-switch-so-each-new-rule-breaks-the-count-fixtures-20261003
hp="$tmp/host-path-tree"
mkdir -p "$hp/bin"

# An adopter with the defect, in both spellings that occur in real code: the
# default on the same line, and the default on the continuation line.
cat >"$hp/bin/adopter-leaks" <<'PY_EOF'
#!/usr/bin/env python3
import os
HOME = os.path.expanduser("~")
def host_path(env_name, default):
    return os.environ.get(env_name) or default
SAME_LINE = os.environ.get("APP_PLIST", os.path.join(HOME, "Library/LaunchAgents/x.plist"))
NEXT_LINE = os.environ.get(
    "APP_LOG", os.path.join(HOME, ".routines/daemon/routinesd.err.log"))
GOOD = host_path("APP_CACHE", os.path.join(HOME, ".local/state/cache"))
HATCH = os.environ.get("APP_DIR", os.path.join(HOME, ".local/state/d"))  # host-path-ok: a writable dir, not a read
PY_EOF

# A NON-adopter with byte-identical defaults. It must stay silent: a program
# that has not adopted the switch is out of scope, and a rule that flagged this
# would fire on most helpers in bin/.
cat >"$hp/bin/non-adopter" <<'PY_EOF'
#!/usr/bin/env python3
import os
HOME = os.path.expanduser("~")
SAME_LINE = os.environ.get("APP_PLIST", os.path.join(HOME, "Library/LaunchAgents/x.plist"))
PY_EOF
chmod +x "$hp/bin/adopter-leaks" "$hp/bin/non-adopter"

set +e
out="$("$LINT" --ci --root "$hp" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "a host-state default bypassing host_path must fail the gate, got $rc: $out"
printf '%s' "$out" | grep -q $'bin/adopter-leaks\t6' || fail "missing same-line finding: $out"
printf '%s' "$out" | grep -q $'bin/adopter-leaks\t7' || fail "missing continuation-line finding: $out"
printf '%s' "$out" | grep -q 'non-adopter' && fail "a file that has not adopted host_path is out of scope: $out"
printf '%s' "$out" | grep -q 'APP_CACHE' && fail "a host_path() call must pass: $out"
printf '%s' "$out" | grep -q 'APP_DIR' && fail "a host-path-ok line must pass: $out"
# Same concern the stat-zulu block pins: the shared hard bucket's FAIL text says
# "unbounded walk(s)", so a rule-5 finding routed there would be MISREPORTED and
# send the reader looking for a walk. It has its own bucket and message.
printf '%s' "$out" | grep -q 'unbounded walk' && fail "a host-path finding must not be reported as a walk: $out"
printf '%s' "$out" | grep -q 'host_path(' || fail "deny text must name the correct form: $out"

out="$("$LINT" --report --root "$hp" 2>&1)" || fail "--report must exit 0"
printf '%s' "$out" | grep -q 'host_paths=2' || fail "host_paths report count wrong: $out"

# HARD, so there is no baseline: routing them through the helper is the only
# way to green.
sed -i '' 's/^SAME_LINE = os\.environ\.get(/SAME_LINE = host_path(/' "$hp/bin/adopter-leaks"
sed -i '' 's/^NEXT_LINE = os\.environ\.get(/NEXT_LINE = host_path(/' "$hp/bin/adopter-leaks"
out="$("$LINT" --ci --root "$hp" 2>&1)" || fail "gate must pass once both go through host_path: $out"
printf '%s' "$out" | grep -q 'host_paths=0' || fail "pass line must carry host_paths=0: $out"

echo "PASS last-stack-lint-bin-authoring"
