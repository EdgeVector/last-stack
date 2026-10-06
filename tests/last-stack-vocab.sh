#!/usr/bin/env bash
# The user word list is per user. Setup copies it into Claude and Codex.
# A project word stays in the repo file. An older harness block is kept once.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
VOCAB="$ROOT/bin/last-stack-vocab"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

home_for() {
  local scratch
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-vocab.XXXXXX")"
  export HOME="$scratch/home"
  mkdir -p "$HOME/.claude" "$HOME/.codex"
}

ste_file() {
  printf '%s\n' '## notes' 'keep me' '' '<!-- last-stack:asd-ste100:end -->' ''
}

case_markers() {
  local start
  start='<!-- last-stack:user-vocabulary:start (managed by last-stack setup; edits inside are overwritten) -->'
  grep -F -q "$start" "$ROOT/setup" || fail "setup marker drifted"
  grep -F -q "$start" "$VOCAB" || fail "vocab marker drifted"
}

case_add() {
  local claude codex before want
  home_for
  claude="$HOME/.claude/CLAUDE.md"
  codex="$HOME/.codex/AGENTS.md"
  ste_file > "$claude"
  cp "$claude" "$codex"
  "$VOCAB" add schema --means "A schema names the fields and the key." --section database
  grep -q '| schema | A schema names the fields and the key. |' "$claude" \
    || fail "harness missing the new word"
  grep -q '| schema | A schema names the fields and the key. |' "$codex" \
    || fail "codex harness missing the new word"
  "$VOCAB" add schema --means "A schema names the fields." --section database
  grep -q '| schema | A schema names the fields. |' "$claude" \
    || fail "harness did not update the word"
  if grep -q 'A schema names the fields and the key.' "$claude"; then
    fail "old meaning still in the harness"
  fi
  before="$(mktemp)"
  cp "$claude" "$before"
  "$VOCAB" sync
  cmp -s "$claude" "$before" || fail "sync changed the harness with no word change"
  want="$(printf 'database\tschema\tA schema names the fields.')"
  "$VOCAB" list | grep -F -q "$want" || fail "list missed the word"
}

case_project() {
  local repo project claude
  home_for
  claude="$HOME/.claude/CLAUDE.md"
  ste_file > "$claude"
  "$VOCAB" add ship --means "You send a change to main." --section change
  repo="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-vocab-repo.XXXXXX")"
  git -C "$repo" init -q
  (
    cd "$repo"
    "$VOCAB" add widget --means "A project word." --section database --project
  )
  project="$repo/.last-stack/vocabulary.md"
  grep -q '| widget | A project word. |' "$project" || fail "project file missed the word"
  if grep -q '| widget |' "$claude"; then
    fail "project word entered the user harness"
  fi
  grep -q '| ship | You send a change to main. |' "$claude" \
    || fail "user word missing after a project add"
}

case_refuse() {
  home_for
  if "$VOCAB" add nope --means "   " --section database >/dev/null 2>&1; then
    fail "empty meaning was accepted"
  fi
  if "$VOCAB" add nope --means "has a | bar" --section database >/dev/null 2>&1; then
    fail "bar in the meaning was accepted"
  fi
  if [ -f "$HOME/.local/state/last-stack/vocabulary.md" ] \
    && grep -q '| nope |' "$HOME/.local/state/last-stack/vocabulary.md"; then
    fail "refused word was written"
  fi
}

case_legacy() {
  local claude vocab
  home_for
  claude="$HOME/.claude/CLAUDE.md"
  cat > "$claude" <<'EOF'
## notes
keep me

<!-- last-stack:asd-ste100:end -->

<!-- last-stack:tom-vocabulary:start (managed by last-stack setup; edits inside are overwritten) -->
## Tom vocabulary

The living list is brain `preference-tom-vocabulary`.

## Database words

| Word | Meaning |
|---|---|
| LegacyProbeWord | A word from the old block. |

## Change words

| Word | Meaning |
|---|---|
| LegacyChangeWord | A change word from the old block. |

<!-- last-stack:tom-vocabulary:end -->
EOF
  "$ROOT/setup" --host claude > /dev/null
  grep -q 'LegacyProbeWord' "$claude" || fail "legacy word was dropped"
  grep -q 'LegacyChangeWord' "$claude" || fail "legacy change word was dropped"
  grep -q 'last-stack:user-vocabulary:start' "$claude" \
    || fail "user-vocabulary block missing after migration"
  if grep -q 'last-stack:tom-vocabulary:start' "$claude"; then
    fail "legacy marker remained"
  fi
  grep -q 'keep me' "$claude" || fail "user notes were dropped"
  vocab="$HOME/.local/state/last-stack/vocabulary.md"
  grep -q 'LegacyProbeWord' "$vocab" || fail "legacy word was not stored"
  if grep -q 'preference-tom-vocabulary' "$vocab"; then
    fail "old brain pointer was stored as the word list"
  fi
}

case_inject() {
  local claude
  home_for
  claude="$HOME/.claude/CLAUDE.md"
  printf '%s\n' '## notes' 'keep me' > "$claude"
  "$ROOT/setup" --host claude > /dev/null
  grep -q 'last-stack:user-vocabulary:start' "$claude" \
    || fail "user-vocabulary block missing from CLAUDE.md"
  grep -q 'Claude, Codex, and Grok read this same block' "$claude" \
    || fail "Claude is not named in the vocabulary block"
  grep -q 'keep me' "$claude" || fail "user notes were dropped"
}

case_uninstall() {
  local claude
  home_for
  claude="$HOME/.claude/CLAUDE.md"
  printf '%s\n' '## notes' 'keep me' > "$claude"
  "$ROOT/setup" --host claude > /dev/null
  "$ROOT/setup" --uninstall > /dev/null
  if grep -q 'last-stack:user-vocabulary:start' "$claude"; then
    fail "uninstall left the user-vocabulary block"
  fi
  grep -q 'keep me' "$claude" || fail "uninstall dropped user notes"
}

run_probes() {
  local probe
  probe="$ROOT/bin/last-stack-mutation-probe"
  (
    cd "$ROOT"
    "$probe" --name vocab-drop-setup-append \
      --target setup \
      --patch "python3 tests/probes/vocab-drop-setup-append.py" \
      --test "bash tests/last-stack-vocab.sh inject" \
      --expect-red-on 'FAIL: user-vocabulary block missing from CLAUDE.md'
    "$probe" --name vocab-drop-uninstall \
      --target bin/last-stack-uninstall \
      --patch "python3 tests/probes/vocab-drop-uninstall.py" \
      --test "bash tests/last-stack-vocab.sh uninstall" \
      --expect-red-on 'FAIL: uninstall left the user-vocabulary block'
    "$probe" --name vocab-drop-harness-write \
      --target bin/last-stack-vocab \
      --patch "python3 tests/probes/vocab-drop-harness-write.py" \
      --test "bash tests/last-stack-vocab.sh add" \
      --expect-red-on 'FAIL: harness missing the new word'
    "$probe" --name vocab-drop-migrate \
      --target setup \
      --patch "python3 tests/probes/vocab-drop-migrate.py" \
      --test "bash tests/last-stack-vocab.sh legacy" \
      --expect-red-on 'FAIL: legacy word was dropped'
    "$probe" --name vocab-project-leak \
      --target bin/last-stack-vocab \
      --patch "python3 tests/probes/vocab-project-leak.py" \
      --test "bash tests/last-stack-vocab.sh project" \
      --expect-red-on 'FAIL: project word entered the user harness'
  )
}

case "${1:-all}" in
  all)
    case_markers
    case_add
    case_project
    case_refuse
    case_legacy
    case_inject
    case_uninstall
    run_probes
    ;;
  markers) case_markers ;;
  add) case_add ;;
  project) case_project ;;
  refuse) case_refuse ;;
  legacy) case_legacy ;;
  inject) case_inject ;;
  uninstall) case_uninstall ;;
  probes) run_probes ;;
  *) fail "unknown case $1" ;;
esac

echo "ok last-stack-vocab ${1:-all}"
