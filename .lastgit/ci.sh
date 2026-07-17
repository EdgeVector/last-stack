#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

for script in setup bin/* hooks/*.sh tests/*.sh .lastgit/ci.sh; do
  [ -f "$script" ] || continue
  first_line="$(sed -n '1p' "$script")"
  case "$first_line" in
    *bash*|*sh*) bash -n "$script" ;;
  esac
done

if [ "${LAST_STACK_CI_FULL:-0}" = "1" ]; then
  for test_script in tests/*.sh; do
    bash "$test_script"
  done
  exit 0
fi

# LastGit's native watcher currently gives ci-required a tight foreground
# budget. Keep the required gate focused on prompt/routine contracts that make
# routine agents safe, and leave the exhaustive shell fixture suite available
# through LAST_STACK_CI_FULL=1.
bin/last-stack-lint-prompts \
  routines/kanban-pickup.md \
  routines/kanban-watch.md \
  routines/pipeline-health.md \
  skills/kanban-agent/SKILL.md \
  instructions/brain-kanban.md

bash tests/last-stack-routine-read.sh
bash tests/last-stack-lint-prompts.sh --smoke
