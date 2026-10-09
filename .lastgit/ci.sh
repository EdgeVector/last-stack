#!/usr/bin/env bash
# Gate of record for EdgeVector/last-stack: syntax check plus the global lint
# passes. The repo carries no tests (deleted 2026-10-09, Tom), so this script
# runs none.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

# Sandboxed macOS runners cannot write Python's default user cache directory.
# Keep bytecode compilation inside this gate's disposable temp space so every
# Python helper is checked without depending on host-home permissions.
CI_PYTHON_CACHE="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-ci-pycache.XXXXXX")"
export PYTHONPYCACHEPREFIX="$CI_PYTHON_CACHE"
cleanup_ci_temp() {
  rm -rf -- "$CI_PYTHON_CACHE"
}
trap cleanup_ci_temp EXIT

for script in setup bin/* lib/*.sh hooks/*.sh .lastgit/ci.sh; do
  [ -f "$script" ] || continue
  first_line="$(sed -n '1p' "$script")"
  case "$first_line" in
    *bash*|*sh*) bash -n "$script" ;;
  esac
done

bin/last-stack-lint-machine-leaks --ci
# No unbounded workspace walk in a helper, no new bash->python heredoc
# nest in bin/ (papercut-agent-zero-llm-cli-bash-python-heredoc-rglob).
bin/last-stack-lint-bin-authoring --ci

bin/last-stack-lint-prompts \
  routines/kanban-pickup.md \
  routines/kanban-watch.md \
  routines/pipeline-health.md \
  skills/kanban-agent/SKILL.md \
  instructions/brain-kanban.md \
  instructions/asd-ste100.md \
  instructions/no-home-root-scan.md \
  instructions/bin-authoring.md

bin/last-stack-lint-prompts --access-sweep .

# config/factory-repair-contract.json pins the sha256 of every bin/ and lib/ file the factory runs, and
# the factory refuses to run a file whose pin is stale (board closeout: factory-contract-refused). The
# repo has no tests, so this is the only check before merge. A failure prints the fix:
# bin/last-stack-factory-repair-contract --refresh, then commit the contract.
bin/last-stack-factory-repair-contract --local --json >/dev/null

echo "ok last-stack CI lint passes"
