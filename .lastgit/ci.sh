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
bin/last-stack-lint-machine-leaks --ci

bin/last-stack-lint-prompts \
  routines/kanban-pickup.md \
  routines/kanban-watch.md \
  routines/pipeline-health.md \
  skills/kanban-agent/SKILL.md \
  instructions/brain-kanban.md

bash tests/last-stack-routine-read.sh
bash tests/last-stack-class-a-heal.sh
bash tests/last-stack-factory-hardening.sh
bash tests/last-stack-todo-rank.sh
bash tests/last-stack-kanban-done-when-eval.sh
bash tests/last-stack-driver-hierarchy.sh
bash tests/last-stack-north-star-ledger-sync.sh
bash tests/last-stack-ship-feature-milestones.sh
bash tests/last-stack-lint-prompts.sh --smoke
bash tests/last-stack-lint-machine-leaks.sh
bash tests/last-stack-audit-f-prefix-callers.sh
bash tests/last-stack-papercut-reconciler-contract.sh
bash tests/last-stack-papercut-lifecycle-close.sh
bash tests/last-stack-canary-pipeline.sh
bash tests/last-stack-command-modes.sh
bash tests/last-stack-north-star-portal-resolver.sh
bash tests/last-stack-mini-cutover-health.sh
bash tests/last-stack-pipeline-deploy-scan.sh
bash tests/last-stack-deploy-gated-closeout.sh
bash tests/last-stack-legacy-residue-closeout.sh
bash tests/last-stack-why-shipping-stopped.sh
bash tests/host-track-artifacts.sh
bash tests/host-track-registry-compliance.sh
bash tests/last-stack-artifact-host-track-proof.sh
bash tests/last-stack-artifact-layout.sh
bash tests/last-stack-artifact-layout-mirror-clean.sh
bash tests/last-stack-artifact-routine-freshness.sh
bash tests/last-stack-artifact-one-rule.sh
bash tests/last-stack-post-merge-safe-upgrade.sh
bash tests/last-stack-lastdb-safe-upgrade-candidate-class.sh
bash tests/last-stack-safe-upgrade-backup-dedup.sh
bash tests/last-stack-lastdb-canary-dogfood.sh
bash tests/last-stack-canary-build-main.sh
