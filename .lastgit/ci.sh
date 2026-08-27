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
  instructions/brain-kanban.md \
  instructions/asd-ste100.md

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
# Same family: the guarded scratch-copy deletion (disk-reclaim step 4b) and
# the bare-mktemp ban that keeps every helper usable inside the scheduled
# sandbox (bare mktemp resolves to the sandbox-denied Darwin temp dir).
bash tests/last-stack-scratch-reclaim.sh
# Same reclaim family, one layer down: the VM sparse-disk trim runs
# `docker run --privileged --pid=host`. Its guard rails must fail CLOSED (no
# docker, unreachable daemon, non-local image) and must never pull an image
# unattended on a disk-pressure path. Runs in under a second against stubs.
bash tests/last-stack-vm-disk-trim.sh
bash tests/last-stack-no-bare-mktemp.sh
bash tests/last-stack-class-a-heal.sh
bash tests/last-stack-sccache-health.sh
bash tests/last-stack-shell-prelude.sh
# The Bash PreToolUse guards run on every agent tool call, and a regression
# there denies work fleet-wide rather than failing one run. The merged-stream
# guard produced 97 distinct denials in one 24h window while its only test
# sat behind LAST_STACK_CI_FULL=1. ~4s.
bash tests/last-stack-hooks-guards.sh
# The safe-capture helper the guard's deny text now points agents at. If it
# regresses, the deny message advertises a broken escape route on every
# blocked call. Runs in well under a second against local stubs.
bash tests/last-stack-json-capture.sh
bash tests/last-stack-brain-append-heartbeat.sh
bash tests/last-stack-obs-sentry-locator.sh
# sentry-triage Step 2/3 policy. It used to be prose in the prompt, where two
# defects (no sample-event drop, unreachable P3 rule) minted a bad card that
# cost a pickup slot. The policy is executable now, so pin it here. <1s.
bash tests/last-stack-sentry-triage-classify.sh
bash tests/last-stack-install-routines.sh
bash tests/last-stack-routines-registry-host-paths.sh
bash tests/last-stack-feature-prove-routine.sh
bash tests/last-stack-fleet-performance-routine.sh
bash tests/last-stack-why-stopped-routine.sh
bash tests/last-stack-why-stopped-loom.sh
bash tests/last-stack-canary-red-heal-routine.sh
bash tests/last-stack-canary-red-loom.sh
bash tests/last-stack-canary-loom.sh
# Class A must not fire on class-a-heal wrapper timeout when heal exits 0.
bash tests/last-stack-why-stopped-class-a-timeout.sh
bash tests/last-stack-lastdb-ops-offenders.sh
bash tests/last-stack-lastdb-ops-offenders-routine.sh
bash tests/last-stack-kanban-pickup-workers.sh
bash tests/last-stack-kanban-pickup-gate.sh
# last-stack ci-required is forge run --all, not a per-repo ci watch.
# Pickup kept filing last-stack watcher cards because pgrep missed the fleet
# supervisor. Pin the classifier in the required gate.
bash tests/last-stack-lastgit-ci-coverage.sh
# Poison park must hydrate bodies via keyed show; list projections have none.
bash tests/last-stack-park-stuck-merge-poison-cards.sh
bash tests/last-stack-pickup-work-policy.sh
bash tests/last-stack-routines-kanban-pickup.sh
bash tests/last-stack-kanban-validate-routine.sh
bash tests/last-stack-pr-reaper-stale-open-heal.sh
bash tests/last-stack-factory-hardening.sh
bash tests/morning-sync-live-human-gate-reconcile.sh
bash tests/last-stack-factory-health-backlog.sh
bash tests/last-stack-launchagent-stable-path.sh
bash tests/last-stack-todo-rank.sh
bash tests/last-stack-kanban-done-when-eval.sh
bash tests/last-stack-driver-hierarchy.sh
bash tests/last-stack-kanban-file-pr.sh
bash tests/last-stack-kanban-file-pr-host-track-install.sh
bash tests/last-stack-kanban-decision-check.sh
bash tests/last-stack-sanitize-structured-fields.sh
bash tests/last-stack-board-closeout-sweep-logic.sh
bash tests/last-stack-board-closeout-sweep.sh
bash tests/last-stack-board-closeout-merge-proof-guard.sh
bash tests/last-stack-board-closeout-evidence-freshness.sh
bash tests/last-stack-card-reaper-run.sh
bash tests/last-stack-card-closeout.sh
bash tests/last-stack-skill-frontmatter-yaml.sh
bash tests/last-stack-routines-host-track-post-install.sh
bash tests/last-stack-unattached-outcome-heal.sh
bash tests/last-stack-north-star-ledger-sync.sh
bash tests/last-stack-north-star-proof-registry.sh
bash tests/last-stack-north-star-proof-io-free.sh
bash tests/last-stack-north-star-proof-ideal-storage-shape.sh
bash tests/last-stack-north-star-proof-exemem-cloud-account.sh
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
bash tests/last-stack-pipeline-stuck-papercut-file.sh
bash tests/last-stack-canary-pipeline.sh
bash tests/last-stack-soak-heal-loom.sh
bash tests/last-stack-ship-soak-loom.sh
bash tests/last-stack-ship-soak-host-track-install.sh
bash tests/last-stack-command-modes.sh
bash tests/last-stack-north-star-portal-resolver.sh
bash tests/last-stack-portal-wt-fetch-detaches-idle-main.sh
bash tests/last-stack-portal-wt-rm-accepts-branch.sh
bash tests/last-stack-portal-wt-start-help.sh
bash tests/last-stack-pickup-zsh-timeout.sh
bash tests/last-stack-portal-live-checkout.sh
bash tests/last-stack-pipeline-deploy-scan.sh
bash tests/last-stack-whats-wrong-loom.sh
# The shared LastDB retry matcher decides whether a routine survives node
# backpressure. A silent narrowing of it turns every transient 503 into a
# red routine, so the fixture belongs in the required gate, not the
# LAST_STACK_CI_FULL suite. It runs in about a second (no node, no sleep).
bash tests/last-stack-lastdb-retry.sh
bash tests/last-stack-whats-wrong-routine.sh
bash tests/last-stack-forge-dead-trigger.sh
bash tests/last-stack-forge-api.sh
# Consumer half of the same wrapper contract: the merge probe is the only
# caller whose failure mode was a SILENT wrong answer (every Forgejo PR read
# as unmerged for days because a bad --jq call was hidden by 2>/dev/null).
bash tests/last-stack-card-closeout-merge-probe.sh
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
# Soak gate correctness: min_checks counting, one-incident heal keying across
# digests, post-flip rollback. A regression here silently flips a bad binary
# onto PATH fleet-wide — same silent-cutover family as the tests above.
bash tests/host-track-soak-gate.sh
bash tests/last-stack-fleet-channel-freshness-gate.sh
bash tests/last-stack-artifact-host-track-proof.sh
bash tests/last-stack-artifact-layout.sh
bash tests/last-stack-artifact-layout-mirror-clean.sh
bash tests/last-stack-artifact-routine-freshness.sh
bash tests/last-stack-artifact-one-rule.sh
bash tests/last-stack-post-merge-safe-upgrade.sh
bash tests/last-stack-post-merge-convergence.sh
bash tests/last-stack-lastdb-safe-upgrade-launchd-job.sh
bash tests/last-stack-lastdb-safe-upgrade-live-socket-health.sh
bash tests/last-stack-lastdb-safe-upgrade-candidate-class.sh
bash tests/last-stack-lastdb-safe-upgrade-latency-bar.sh
bash tests/last-stack-lastdb-safe-upgrade-cas-probe.sh
bash tests/last-stack-lastdb-write-path-cow-probe.sh
bash tests/last-stack-safe-upgrade-backup-dedup.sh
bash tests/last-stack-safe-upgrade-backup-retention.sh
bash tests/last-stack-lastdb-canary-dogfood.sh
bash tests/last-stack-canary-build-main.sh
bash tests/last-stack-canary-resolve-lastdbd.sh
bash tests/last-stack-dogfood-rotate-gate.sh
bash tests/last-stack-dogfood-rotate-routine.sh
bash tests/last-stack-lastdb-memory-guard.sh
bash tests/last-stack-host-memory-guards.sh
bash tests/last-stack-generator-shed-gate.sh

# Reclaim live-guard fixture. This one is in the REQUIRED gate, not the
# LAST_STACK_CI_FULL suite, because the failure it catches destroys a
# developer's build outputs under an in-flight build -- and the guard is a set
# of predicates (live cwd, live exec image under target/, fresh build marker,
# disk-pressure floor) that a later edit can silently narrow. It runs in about
# four seconds: it skips lsof and board reads, injects the live paths, and uses
# `sleep` as the fixture process, so it fits the foreground budget.
bash tests/last-stack-worktree-reclaim.sh
bash tests/last-stack-disk-reclaim-stripped-path.sh
