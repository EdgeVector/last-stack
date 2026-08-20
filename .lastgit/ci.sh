#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

# Sandboxed macOS runners cannot write Python's default user cache directory.
# Keep bytecode compilation inside this gate's disposable temp space so every
# Python helper is checked without depending on host-home permissions.
CI_PYTHON_CACHE="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-ci-pycache.XXXXXX")"
export PYTHONPYCACHEPREFIX="$CI_PYTHON_CACHE"
trap 'rm -rf "$CI_PYTHON_CACHE"' EXIT

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

# LastDB access-pattern gate over routines/, skills/ AND bin/. The invocation
# above is deliberately five files; bin/ helpers run against the live primary
# and are where a banned read regresses unnoticed. This mode is a grep, so it
# fits the required gate's foreground budget.
bin/last-stack-lint-prompts --access-sweep .

bash tests/last-stack-routine-read.sh
bash tests/last-stack-routine-read-proceed-on-stale.sh
# Reclaim safety belongs in the REQUIRED gate, not only under
# LAST_STACK_CI_FULL=1: this covers a liveness check that once failed OPEN
# (a sandbox denying ps/lsof made every worktree look idle) and a board parse
# that silently returned an empty protect set. Both are silent-data-loss
# shapes, and both were invisible for weeks. Runs in a few seconds.
bash tests/last-stack-reclaim-liveness-and-finished-work.sh
bash tests/last-stack-class-a-heal.sh
bash tests/last-stack-sccache-health.sh
bash tests/last-stack-shell-prelude.sh
bash tests/last-stack-obs-sentry-locator.sh
bash tests/last-stack-install-routines.sh
bash tests/last-stack-routines-registry-host-paths.sh
bash tests/last-stack-feature-prove-routine.sh
bash tests/last-stack-fleet-performance-routine.sh
bash tests/last-stack-why-stopped-routine.sh
bash tests/last-stack-why-stopped-loom.sh
bash tests/last-stack-lastdb-ops-offenders.sh
bash tests/last-stack-lastdb-ops-offenders-routine.sh
bash tests/last-stack-kanban-pickup-workers.sh
bash tests/last-stack-kanban-validate-routine.sh
bash tests/last-stack-pr-reaper-stale-open-heal.sh
bash tests/last-stack-factory-hardening.sh
bash tests/last-stack-factory-health-backlog.sh
bash tests/last-stack-launchagent-stable-path.sh
bash tests/last-stack-todo-rank.sh
bash tests/last-stack-kanban-done-when-eval.sh
bash tests/last-stack-driver-hierarchy.sh
bash tests/last-stack-kanban-file-pr.sh
bash tests/last-stack-kanban-file-pr-host-track-install.sh
bash tests/last-stack-sanitize-structured-fields.sh
bash tests/last-stack-board-closeout-sweep-logic.sh
bash tests/last-stack-card-closeout.sh
bash tests/last-stack-unattached-outcome-heal.sh
bash tests/last-stack-north-star-ledger-sync.sh
bash tests/last-stack-north-star-proof-registry.sh
bash tests/last-stack-north-star-proof-ideal-storage-shape.sh
bash tests/last-stack-org-cloud-membership-dogfood.sh
bash tests/last-stack-dogfood-resource-isolate.sh
bash tests/last-stack-secret-env-run.sh
bash tests/last-stack-ship-feature-milestones.sh
bash tests/last-stack-fix-it-skill.sh
bash tests/last-stack-design-pack.sh
bash tests/last-stack-ship-handoff.sh
bash tests/last-stack-real-human-notify.sh
bash tests/last-stack-lint-prompts.sh --ci
bash tests/last-stack-lastdb-access-watch.sh
bash tests/last-stack-routines-prompt-doctor.sh
bash tests/last-stack-literal-markdown-append.sh
bash tests/last-stack-lint-machine-leaks.sh
bash tests/last-stack-audit-f-prefix-callers.sh
bash tests/last-stack-papercut-reconciler-contract.sh
bash tests/last-stack-papercut-queue.sh
# Producer half of the same pipeline: the reconciler contract above guards the
# only routine that turns papercuts into cards, and nothing guarded the rule
# telling agents to file them in the first place.
bash tests/last-stack-papercut-filing-contract.sh
# Close-out is the last-chance producer for those same papercuts, plus the
# full LastDB report of what the session actually did.
bash tests/last-stack-closeout-skill-contract.sh
bash tests/last-stack-papercut-lifecycle-close.sh
bash tests/last-stack-papercut-lifecycle-helper-run-install.sh
bash tests/last-stack-canary-pipeline.sh
bash tests/last-stack-command-modes.sh
bash tests/last-stack-north-star-portal-resolver.sh
bash tests/last-stack-portal-wt-fetch-detaches-idle-main.sh
bash tests/last-stack-portal-wt-rm-accepts-branch.sh
bash tests/last-stack-portal-wt-start-help.sh
bash tests/last-stack-pickup-zsh-timeout.sh
bash tests/last-stack-portal-live-checkout.sh
bash tests/last-stack-pipeline-deploy-scan.sh
bash tests/last-stack-whats-wrong-loom.sh
bash tests/last-stack-whats-wrong-routine.sh
bash tests/last-stack-forge-dead-trigger.sh
bash tests/last-stack-forge-api.sh
bash tests/last-stack-deploy-gated-closeout.sh
bash tests/last-stack-board-closeout-escalation.sh
bash tests/last-stack-legacy-residue-closeout.sh
bash tests/last-stack-why-shipping-stopped.sh
bash tests/host-track-artifacts.sh
bash tests/host-track-on-channel-unpublished-main.sh
bash tests/host-track-safe-upgrade-probe.sh
bash tests/host-track-canary-soak.sh
bash tests/host-track-soak-red-files-card.sh
bash tests/host-track-local-safe-staleness.sh
bash tests/host-track-deployment-freshness.sh
bash tests/lastseek-host-track.sh
bash tests/host-track-registry-compliance.sh
bash tests/last-stack-fleet-channel-freshness-gate.sh
bash tests/last-stack-artifact-host-track-proof.sh
bash tests/last-stack-artifact-layout.sh
bash tests/last-stack-artifact-layout-mirror-clean.sh
bash tests/last-stack-artifact-routine-freshness.sh
bash tests/last-stack-artifact-one-rule.sh
bash tests/last-stack-post-merge-safe-upgrade.sh
bash tests/last-stack-lastdb-safe-upgrade-launchd-job.sh
bash tests/last-stack-lastdb-safe-upgrade-candidate-class.sh
bash tests/last-stack-lastdb-safe-upgrade-latency-bar.sh
bash tests/last-stack-lastdb-safe-upgrade-cas-probe.sh
bash tests/last-stack-lastdb-write-path-cow-probe.sh
bash tests/last-stack-safe-upgrade-backup-dedup.sh
bash tests/last-stack-safe-upgrade-backup-retention.sh
bash tests/last-stack-lastdb-canary-dogfood.sh
bash tests/last-stack-canary-build-main.sh
bash tests/last-stack-canary-resolve-lastdbd.sh
bash tests/last-stack-lastdb-memory-guard.sh
bash tests/last-stack-generator-shed-gate.sh
