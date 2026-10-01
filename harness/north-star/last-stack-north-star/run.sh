#!/usr/bin/env bash
# north-star-slug: north-star-last-stack-north-star
# Terminal proof for the Last Stack launchd and routine-registry contracts.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../common.sh
. "$ROOT/harness/north-star/common.sh"

SLUG=last-stack-north-star
MODE="$(ns_mode)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-north-star-proof.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

finish() {
  local verdict="$1" body="$2"
  if ns_write_report "$SLUG" "$verdict" "$body"; then
    exit 0
  fi
  exit 1
}

case "$MODE" in
  offline|live) ;;
  *) finish FAIL "The proof mode is invalid: $MODE." ;;
esac

for command_name in bash plutil jq; do
  if ! ns_require_cmd "$command_name"; then
    finish FAIL "The proof needs the missing command: $command_name."
  fi
done

if [ ! -x /usr/libexec/PlistBuddy ]; then
  finish FAIL "The proof needs /usr/libexec/PlistBuddy."
fi

agent_source="$ROOT/lib/last-stack-launchd-agent.sh"
registry_source="$ROOT/bin/last-stack-routines-registry-env"
stable_test="$ROOT/tests/last-stack-launchagent-stable-path.sh"
commit_test="$ROOT/tests/last-stack-launchd-agent-commit-plist.sh"

for required_file in "$agent_source" "$registry_source" "$stable_test" "$commit_test"; do
  if [ ! -f "$required_file" ]; then
    finish FAIL "The proof input is absent: $required_file."
  fi
done

run_test() {
  local name="$1" script="$2" output_file="$TMP/$1.out" rc
  set +e
  bash "$script" >"$output_file" 2>&1
  rc=$?
  set -e
  printf '%s\t%s\t%s\n' "$name" "$rc" "$output_file" >>"$TMP/results.tsv"
}

run_registry_probe() {
  local probe_home="$TMP/install-smoke-home"
  local stable_root="$TMP/stable-root"
  local inherited_registry="$TMP/inherited-routines"
  local prompt="$stable_root/routines/north-star-proof.md"

  mkdir -p "$(dirname "$prompt")" "$inherited_registry/registry"
  printf '%s\n' '# throwaway routine prompt' >"$prompt"

  HOME="$probe_home" \
  LAST_STACK_ROOT="$stable_root" \
  ROUTINES_HOME="$inherited_registry" \
  ROOT="$ROOT" \
  bash -c '
    set -euo pipefail
    . "$ROOT/bin/last-stack-routines-registry-env"
    last_stack_registry_paths_init
    [ "$ROUTINES_HOME" = "$HOME/.routines" ]
    [ "$REG_STABLE_ROOT" = "$LAST_STACK_ROOT" ]
    chosen="$(last_stack_registry_prompt_path north-star-proof.md "$ROOT/routines/north-star-proof.md")"
    [ "$chosen" = "$LAST_STACK_ROOT/routines/north-star-proof.md" ]
    case "$chosen" in
      */.lastdb/*|*/.folddb/*) exit 1 ;;
    esac
    printf "ROUTINES_HOME=%s\nREG_STABLE_ROOT=%s\nPROMPT=%s\n" \
      "$ROUTINES_HOME" "$REG_STABLE_ROOT" "$chosen"
  '
}

run_test stable-launchd-path "$stable_test"
run_test commit-plist "$commit_test"

set +e
run_registry_probe >"$TMP/registry-run.out" 2>&1
registry_rc=$?
set -e

body="Last Stack North Star terminal proof.

Mode: $MODE.
The proof uses throwaway HOME and plist paths. It sets the launchd domain to
none in the product tests. It does not open a LastDB home or call launchctl.

Product source:
- launchd helper: $agent_source
- routine registry helper: $registry_source

Focused product tests:"

failed=0
while IFS=$'\t' read -r name rc output_file; do
  [ -n "$name" ] || continue
  if [ "$rc" -eq 0 ]; then
    body="$body
- $name: PASS"
  else
    failed=1
    body="$body
- $name: FAIL (rc=$rc)
  $(cat "$output_file")"
  fi
done <"$TMP/results.tsv"

if [ "$registry_rc" -eq 0 ]; then
  body="$body
- routine registry path probe: PASS
  $(cat "$TMP/registry-run.out")"
else
  failed=1
  body="$body
- routine registry path probe: FAIL (rc=$registry_rc)
  $(cat "$TMP/registry-run.out")"
fi

if [ "$failed" -ne 0 ]; then
  finish FAIL "$body"
fi

if [ "$MODE" = live ]; then
  finish PASS "$body"
fi
finish PASS-OFFLINE "$body"
