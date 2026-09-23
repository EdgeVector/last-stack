#!/usr/bin/env bash
# The decision gate must read the store that actually holds the corpus.
#
# gbrain has been the primary knowledge store since 2026-09-06. Censused on
# 2026-09-22 with `brain reindex --list-index --dry-run`, the LastDB brain this
# check defaults to holds design=1, decision=3, preference=2, sop=2 — against
# gbrain's ~12,910 pages. The gate was honouring a corpus of six records and
# returning `verdict: honor` on everything else. It only surfaced because an
# unrelated index-marker error made it fail loudly.
#
# Driven against a STUB gbrain, so this asserts the calling convention and the
# normalisation without a live node.
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

# Stub gbrain. Addresses pages as <dir>/<slug>; `wiki/concepts` for concepts,
# matching the live store. `search` speaks gbrain's shape: one row per CHUNK,
# addressed slug, `chunk_text` rather than `snippet`, and `--types a,b`.
cat >"$tmp/bin/gbrain" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FIXTURE_CALLS"
verb="$1"; shift
case "$verb" in
  get)
    case "$1" in
      design/design-flaky-gate-policy)
        printf 'type: design\ntitle: flaky gate policy\n---\nA required gate must be reliable.\n' ;;
      wiki/concepts/concepts-gate-reliability)
        printf 'type: concept\ntitle: gate reliability\n---\nGate reliability is measured on main.\n' ;;
      preference/preference-deflake-assert-cause)
        printf 'type: preference\ntitle: assert the cause\n---\nA repetition run proves nothing.\n' ;;
      *) exit 1 ;;
    esac
    ;;
  search)
    # Two chunks of ONE page, plus two other pages. The bare-slug dedup must
    # collapse the duplicate; an addressed-slug dedup would not.
    cat <<'JSON'
[
 {"slug":"design/design-flaky-gate-policy","type":"design","title":"flaky gate policy","chunk_text":"chunk one","score":0.9},
 {"slug":"design/design-flaky-gate-policy","type":"design","title":"flaky gate policy","chunk_text":"chunk two","score":0.8},
 {"slug":"wiki/concepts/concepts-gate-reliability","type":"design","title":"gate reliability","chunk_text":"c","score":0.7},
 {"slug":"preference/preference-deflake-assert-cause","type":"preference","title":"assert the cause","chunk_text":"p","score":0.6}
]
JSON
    ;;
  *) exit 2 ;;
esac
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

out="$tmp/out.json"
FIXTURE_CALLS="$calls" python3 "$BIN" \
  --brain "$tmp/bin/gbrain" \
  --title "De-flake the required gate" --kind pr --column todo --json \
  <"$body" >"$out" 2>"$tmp/err" || fail "gbrain-backed check exited non-zero: $(cat "$tmp/err")"

# 1. The gate ran and reached a verdict.
jq -e '.verdict == "honor"' "$out" >/dev/null || fail "expected verdict=honor, got $(jq -r .verdict "$out")"

# 2. Slugs are presented BARE. Invariants and the printed stamp are written in
#    bare-slug vocabulary; an addressed slug would silently match nothing.
jq -e '.slugs | index("design-flaky-gate-policy")' "$out" >/dev/null \
  || fail "search slug was not normalised to its bare form: $(jq -c .slugs "$out")"
jq -e '[.slugs[] | select(test("/"))] | length == 0' "$out" >/dev/null \
  || fail "an addressed slug leaked into the result: $(jq -c .slugs "$out")"

# 3. Two chunks of one page collapse to one candidate.
jq -e '[.slugs[] | select(. == "design-flaky-gate-policy")] | length == 1' "$out" >/dev/null \
  || fail "duplicate chunks of one page were not deduped"

# 4. Every candidate was actually point-got THROUGH gbrain addressing. This is
#    the assertion that fails if the prefix map is wrong: a record that cannot
#    be addressed reads as absent, and the invariants only fire on GOT slugs.
jq -e '.records | length >= 3 and all(.[]; .got == true)' "$out" >/dev/null \
  || fail "not every candidate resolved: $(jq -c '[.records[]|{slug,got}]' "$out")"

# 5. Concepts live at wiki/concepts, not concept/. A single flat <type>/<slug>
#    map would miss them.
grep -Fq 'get wiki/concepts/concepts-gate-reliability' "$calls" \
  || fail "concept was not addressed under wiki/concepts: $(cat "$calls")"

# 6. gbrain takes ONE comma-separated --types, not repeated --type. Passing the
#    brain shape exits non-zero with `unknown flag --type`, which the gate
#    would report as a brain failure and fail closed on.
grep -Eq 'search .* --types [a-z,]+ ' "$calls" \
  || fail "search did not use gbrain's --types shape: $(cat "$calls")"
grep -Eq 'search .* --type ' "$calls" \
  && fail "search used the brain --type shape against gbrain: $(cat "$calls")"

# 7. The brain path is untouched: a non-gbrain bin name must not take the
#    gbrain branch. Fixture mode short-circuits the CLI, so assert the flavour
#    directly.
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

echo "ok last-stack-kanban-decision-check-gbrain"

# 8. The default follows ~/.claude/brain-config.json `.primary` — the switch
#    the workspace already uses — rather than hard-coding gbrain. A hard-coded
#    default would keep reading gbrain after the cutover is reverted, which is
#    today's bug mirrored.
cfg="$tmp/brain-config.json"
check_default() { # <config-json-or-empty> <expected>
  if [ -n "$1" ]; then printf '%s' "$1" >"$cfg"; else rm -f "$cfg"; fi
  got="$(LAST_STACK_BRAIN_CONFIG="$cfg" BRAIN_BIN= python3 - "$BIN" <<'PY'
import importlib.machinery, importlib.util, os, sys
os.environ.pop("BRAIN_BIN", None)
spec = importlib.util.spec_from_loader("dc2", importlib.machinery.SourceFileLoader("dc2", sys.argv[1]))
m = importlib.util.module_from_spec(spec); sys.modules["dc2"] = m; spec.loader.exec_module(m)
print(m.default_brain_bin())
PY
)"
  [ "$got" = "$2" ] || fail "default_brain_bin: config=${1:-<absent>} expected $2, got $got"
}
check_default '{"primary":"gbrain"}' gbrain
check_default '{"primary":"brain"}' brain
check_default '{"primary":"something-else"}' brain
check_default '{ not json' brain
check_default '' brain

# $BRAIN_BIN still wins over the config.
got="$(LAST_STACK_BRAIN_CONFIG="$cfg" BRAIN_BIN=my-brain python3 - "$BIN" <<'PY'
import importlib.machinery, importlib.util, sys
spec = importlib.util.spec_from_loader("dc3", importlib.machinery.SourceFileLoader("dc3", sys.argv[1]))
m = importlib.util.module_from_spec(spec); sys.modules["dc3"] = m; spec.loader.exec_module(m)
print(m.default_brain_bin())
PY
)"
[ "$got" = "my-brain" ] || fail "\$BRAIN_BIN did not win over the config: got $got"

echo "ok last-stack-kanban-decision-check-gbrain default resolution"
