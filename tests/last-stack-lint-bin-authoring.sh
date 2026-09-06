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
printf '%s' "$out" | grep -q 'hard=2 nests=2 new_nests=1 retired_nests=0' || fail "report counts wrong: $out"

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
printf '%s' "$out" | grep -q '^ok last-stack-lint-bin-authoring hard=0 nests=2' || fail "pass line wrong: $out"

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

echo "PASS last-stack-lint-bin-authoring"
