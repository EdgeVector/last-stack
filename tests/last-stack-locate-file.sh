#!/usr/bin/env bash
# Behavioural test for bin/last-stack-locate-file: the bounded replacement for
# `find <workspace root>` / `Path.rglob` when a helper needs one config file
# (brain papercut-agent-zero-llm-cli-bash-python-heredoc-rglob).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-locate-file"
tmp="$(mktemp -d "${TMPDIR:-${TMP:-${TEMP:-/tmp}}}/last-stack-locate-file-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
# macOS TMPDIR ends in a slash; normalise so string compares against helper output hold.
tmp="$(cd "$tmp" && pwd -P)"

fail() { echo "FAIL last-stack-locate-file: $*" >&2; exit 1; }

[ -x "$BIN" ] || fail "helper must ship executable"

# Fixture: a fake home holding a workspace with the target file at depth 4,
# a decoy inside a pruned target/ tree, and a fixed candidate elsewhere.
home="$tmp/home"
ws="$home/code/edgevector"
mkdir -p "$ws/a/b/c" "$ws/target/deep" "$home/link-target" "$home/elsewhere"
printf 'deep\n' >"$ws/a/b/c/feature_catalog.toml"
printf 'decoy\n' >"$ws/target/deep/feature_catalog.toml"
printf 'candidate\n' >"$home/elsewhere/feature_catalog.toml"
printf 'linked\n' >"$home/link-target/feature_catalog.toml"
ln -s "$home/link-target" "$ws/a/symlinked"

run() { HOME="$home" "$BIN" "$@"; }

# 1. Depth bound: maxdepth 3 misses depth 4; maxdepth 4 finds it.
set +e
out="$(run --name feature_catalog.toml --root "$ws" --maxdepth 3 2>"$tmp/err")"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "depth-4 file must be missed at maxdepth 3, got rc=$rc out=$out"
[ -z "$out" ] || fail "stdout must be empty when not found: $out"
grep -q 'not found' "$tmp/err" || fail "stderr must say not found: $(cat "$tmp/err")"
grep -q 'maxdepth=3' "$tmp/err" || fail "stderr must show the bound it used: $(cat "$tmp/err")"

out="$(run --name feature_catalog.toml --root "$ws" --maxdepth 4)" || fail "depth-4 file must be found at maxdepth 4"
[ "$out" = "$ws/a/b/c/feature_catalog.toml" ] || fail "wrong hit: $out"

# 2. Pruning and symlinks: target/ is skipped, symlinked dirs are not followed.
out="$(run --name feature_catalog.toml --root "$ws" --maxdepth 6 --all)" || fail "--all must find the deep file"
printf '%s' "$out" | grep -q 'target/deep' && fail "target/ must be pruned: $out"
printf '%s' "$out" | grep -q 'symlinked' && fail "symlinks must not be followed: $out"
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 1 ] || fail "--all must list the deep file only: $out"

# 3. Env var wins over candidates and roots.
out="$(PRODUCT_FEATURE_CATALOG="$home/elsewhere/feature_catalog.toml" run --name feature_catalog.toml \
  --env PRODUCT_FEATURE_CATALOG --candidate "$ws/a/b/c/feature_catalog.toml" --root "$ws" --json)" \
  || fail "env path must resolve"
printf '%s' "$out" | jq -e '.source == "env"' >/dev/null || fail "source must be env: $out"
printf '%s' "$out" | jq -e --arg p "$home/elsewhere/feature_catalog.toml" '.found == [$p]' >/dev/null || fail "env hit wrong: $out"

# 4. A dangling env var is reported and skipped; the candidate then wins over the walk.
out="$(PRODUCT_FEATURE_CATALOG="$home/missing.toml" run --name feature_catalog.toml \
  --env PRODUCT_FEATURE_CATALOG --candidate "$home/nope.toml" --candidate "$home/elsewhere/feature_catalog.toml" \
  --root "$ws" --maxdepth 4 --json)" || fail "candidate must resolve"
printf '%s' "$out" | jq -e '.source == "candidate"' >/dev/null || fail "source must be candidate: $out"
printf '%s' "$out" | jq -e '.checked.env.exists == false' >/dev/null || fail "dangling env must be recorded: $out"
printf '%s' "$out" | jq -e '.checked.candidates[0].exists == false and .checked.candidates[1].exists == true' >/dev/null \
  || fail "candidate order must be recorded: $out"
printf '%s' "$out" | jq -e '.checked.roots == []' >/dev/null || fail "roots must not be walked once a candidate hits: $out"

# 5. The home directory is refused as a root.
set +e
run --name x --root "$home" >/dev/null 2>"$tmp/err"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "home root must be refused with exit 2, got $rc"
grep -q 'refusing the home directory' "$tmp/err" || fail "refusal must be explained: $(cat "$tmp/err")"
set +e
run --name x --root "~" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "~ root must be refused with exit 2, got $rc"

# 6. A time budget stops the walk and says so.
out="$(run --name never.toml --root "$ws" --maxdepth 6 --budget-ms 1 --json)" && fail "a miss must exit 1"
printf '%s' "$out" | jq -e '.found == []' >/dev/null || fail "budget run must find nothing: $out"
printf '%s' "$out" | jq -e 'has("elapsed_ms") and has("budget_exhausted")' >/dev/null || fail "summary must carry timing fields: $out"

# 7. A glob name works; a missing root is recorded, not fatal.
out="$(run --name 'feature_*.toml' --root "$home/absent" --root "$ws" --maxdepth 4)" || fail "glob name must resolve"
[ "$out" = "$ws/a/b/c/feature_catalog.toml" ] || fail "glob hit wrong: $out"

# 8. Help contract: --help and -h exit 0 on stdout, nothing on stderr; bad usage exits 2.
help_err="$("$BIN" --help 2>&1 >/dev/null)" || fail "--help must exit 0"
[ -z "$help_err" ] || fail "--help must not write to stderr: $help_err"
"$BIN" -h | grep -q -- '--maxdepth' || fail "-h must print the usage"
set +e
"$BIN" --root "$ws" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "missing --name must exit 2, got $rc"

echo "PASS last-stack-locate-file"
