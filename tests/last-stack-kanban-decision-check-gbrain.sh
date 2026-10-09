#!/usr/bin/env bash
# gbrain is retired (won't-undo, Tom 2026-09-25: "the brain is LastDB only
# ... Re-enabling gbrain needs Tom"). This check must refuse every path that
# could select it -- explicit --brain, inherited $BRAIN_BIN, and a stale
# `.primary: gbrain` in ~/.claude/brain-config.json -- before it runs a
# single gbrain subprocess or reads a single fixture file
# (papercut-last-stack-decision-check-old-config-selects-retired-brain-20261009).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-kanban-decision-check"
chmod +x "$BIN"
python3 -m py_compile "$BIN"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$tmp/bin"
calls="$tmp/calls.txt"
: >"$calls"

# A gbrain stub that records whether it was ever invoked. If any refusal
# path below is broken, this stub runs and the "never called" assertion
# catches it -- the whole point is that it must stay silent.
cat >"$tmp/bin/gbrain" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FIXTURE_CALLS"
exit 1
STUB
chmod +x "$tmp/bin/gbrain"

body="$tmp/body.md"
cat >"$body" <<'BODY'
Repo: EdgeVector/fold
Base: main
Kind: pr

## GOAL

De-flake the required gate.

## END STATE

The gate is reliable.
BODY

assert_refused() { # <label> <env-assignment...> -- <extra argv...>
  label="$1"; shift
  : >"$calls"
  env_args=()
  while [ "$1" != "--" ]; do env_args+=("$1"); shift; done
  shift
  out="$tmp/out-$label.json"
  err="$tmp/err-$label.txt"
  rc=0
  env "${env_args[@]}" FIXTURE_CALLS="$calls" python3 "$BIN" \
    --title "De-flake the required gate" --kind pr --column todo \
    "$@" <"$body" >"$out" 2>"$err" || rc=$?
  [ "$rc" -eq 1 ] || fail "$label: expected exit 1, got $rc (stderr: $(cat "$err"))"
  grep -Fq "gbrain is retired" "$err" \
    || fail "$label: refusal message did not name gbrain retirement: $(cat "$err")"
  [ ! -s "$calls" ] || fail "$label: gbrain stub was invoked -- refusal did not block it: $(cat "$calls")"
  [ ! -s "$out" ] || fail "$label: wrote output despite refusing: $(cat "$out")"
}

# 1. Explicit --brain naming a gbrain binary, absolute path.
assert_refused explicit-brain -- --brain "$tmp/bin/gbrain"

# 2. Inherited $BRAIN_BIN naming a gbrain binary, no --brain flag -- the
#    exact shape the papercut measured ("A stale caller or config can select
#    the retired backend").
assert_refused env-brain-bin "BRAIN_BIN=$tmp/bin/gbrain" --

# 3. A bare `gbrain` name (not a path) must refuse too -- the check is on
#    the basename, not on being handed a real stub path.
assert_refused bare-name "BRAIN_BIN=gbrain" --

# 4. A stale `.primary: "gbrain"` in the config, no $BRAIN_BIN override and
#    no explicit --brain -- the config-driven path the papercut named.
cfg="$tmp/brain-config.json"
printf '%s' '{"primary":"gbrain"}' >"$cfg"
assert_refused config-primary "LAST_STACK_BRAIN_CONFIG=$cfg" "BRAIN_BIN=" --

echo "ok last-stack-kanban-decision-check-gbrain refusal (explicit --brain, \$BRAIN_BIN, bare name, config .primary)"

# 5. The legitimate `brain` path is untouched -- it must not trip the same
#    guard just because it shares a prefix check with gbrain.
mkdir -p "$tmp/clear"
printf '%s\n' '[]' >"$tmp/clear/search.json"
out="$tmp/out-brain-ok.json"
rc=0
LAST_STACK_BRAIN_CONFIG="$tmp/missing-config.json" BRAIN_BIN= python3 "$BIN" \
  --brain brain --fixture-dir "$tmp/clear" \
  --title "De-flake the required gate" --kind pr --column todo --json \
  <"$body" >"$out" 2>"$tmp/err-brain-ok.txt" || rc=$?
[ "$rc" -eq 0 ] || fail "plain 'brain' was refused: $(cat "$tmp/err-brain-ok.txt")"
jq -e '.verdict == "clear"' "$out" >/dev/null \
  || fail "plain 'brain' path did not reach a verdict: $(cat "$out")"

echo "ok last-stack-kanban-decision-check-gbrain plain brain unaffected"

# 6. Unit-level: Brain's flavour detection and gbrain addressing still work
#    as plain code (kept only for its own unit tests per the module
#    comment); this is not a claim that the CLI can reach them.
python3 - "$BIN" <<'PY' || fail "flavour detection regressed"
import importlib.machinery, importlib.util, sys
spec = importlib.util.spec_from_loader(
    "dc", importlib.machinery.SourceFileLoader("dc", sys.argv[1])
)
m = importlib.util.module_from_spec(spec)
sys.modules["dc"] = m
spec.loader.exec_module(m)
assert m.Brain("brain", None).gbrain is False, "plain `brain` took the gbrain path"
assert m.Brain("/x/y/gbrain", None).gbrain is True, "absolute gbrain path not detected"
assert m.gbrain_candidate_paths("design-foo") == ["design/design-foo"]
assert m.gbrain_candidate_paths("concepts-foo") == ["wiki/concepts/concepts-foo"]
assert m.gbrain_candidate_paths("already/addressed") == ["already/addressed"]
PY

echo "ok last-stack-kanban-decision-check-gbrain unit (flavour detection, addressing)"
