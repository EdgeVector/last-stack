#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

# Sandboxed macOS runners cannot write Python's default user cache directory.
# Keep bytecode compilation inside this gate's disposable temp space so every
# Python helper is checked without depending on host-home permissions.
CI_PYTHON_CACHE="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-ci-pycache.XXXXXX")"
export PYTHONPYCACHEPREFIX="$CI_PYTHON_CACHE"
CI_SHARD_LOG_DIR=""
cleanup_ci_temp() {
  rm -rf -- "$CI_PYTHON_CACHE"
  [ -z "$CI_SHARD_LOG_DIR" ] || rm -rf -- "$CI_SHARD_LOG_DIR"
}
trap cleanup_ci_temp EXIT

CI_SHARD_INDEX="${LAST_STACK_CI_SHARD_INDEX:-}"
CI_SHARD_COUNT="${LAST_STACK_CI_SHARD_COUNT:-1}"

if [ -z "$CI_SHARD_INDEX" ]; then
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

  # Run the global lint passes once. The child shards below run only the test
  # scripts, so they do not repeat these full-tree reads.
  bin/last-stack-lint-machine-leaks --ci

  bin/last-stack-lint-prompts \
    routines/kanban-pickup.md \
    routines/kanban-watch.md \
    routines/pipeline-health.md \
    skills/kanban-agent/SKILL.md \
    instructions/brain-kanban.md \
    instructions/asd-ste100.md

  bin/last-stack-lint-prompts --access-sweep .

  CI_SHARD_COUNT="${LAST_STACK_CI_JOBS:-4}"
  case "$CI_SHARD_COUNT" in
    ''|*[!0-9]*) echo "LAST_STACK_CI_JOBS must be an integer from 1 through 8" >&2; exit 2 ;;
  esac
  if [ "$CI_SHARD_COUNT" -lt 1 ] || [ "$CI_SHARD_COUNT" -gt 8 ]; then
    echo "LAST_STACK_CI_JOBS must be an integer from 1 through 8" >&2
    exit 2
  fi
  if [ "$CI_SHARD_COUNT" -eq 1 ]; then
    CI_SHARD_INDEX=0
  else
    CI_SHARD_LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-ci-shards.XXXXXX")"
    echo "last-stack required CI: test scripts use $CI_SHARD_COUNT bounded shards"
    shard_pids=()
    shard_index=0
    while [ "$shard_index" -lt "$CI_SHARD_COUNT" ]; do
      LAST_STACK_CI_SHARD_INDEX="$shard_index" \
        LAST_STACK_CI_SHARD_COUNT="$CI_SHARD_COUNT" \
        bash "$0" >"$CI_SHARD_LOG_DIR/$shard_index.log" 2>&1 &
      shard_pids+=("$!")
      shard_index=$((shard_index + 1))
    done

    shard_failed=0
    for shard_pid in "${shard_pids[@]}"; do
      if ! wait "$shard_pid"; then shard_failed=1; fi
    done
    shard_index=0
    while [ "$shard_index" -lt "$CI_SHARD_COUNT" ]; do
      cat "$CI_SHARD_LOG_DIR/$shard_index.log"
      shard_index=$((shard_index + 1))
    done
    if [ "$shard_failed" -ne 0 ]; then
      echo "last-stack required CI shard failed" >&2
      exit 1
    fi
    exit 0
  fi
fi

ci_test_index=0
ci_test() {
  local test_slot=$((ci_test_index % CI_SHARD_COUNT))
  ci_test_index=$((ci_test_index + 1))
  [ "$test_slot" -eq "$CI_SHARD_INDEX" ] || return 0
  bash "$@"
}

ci_test tests/last-stack-routine-read.sh
ci_test tests/last-stack-routine-read-proceed-on-stale.sh
ci_test tests/last-stack-ci-sharding.sh
# Reclaim safety belongs in the REQUIRED gate, not only under
# LAST_STACK_CI_FULL=1: this covers a liveness check that once failed OPEN
# (a sandbox denying ps/lsof made every worktree look idle) and a board parse
# that silently returned an empty protect set. Both are silent-data-loss
# shapes, and both were invisible for weeks. Runs in a few seconds.
ci_test tests/last-stack-reclaim-liveness-and-finished-work.sh
# Same family: the guarded scratch-copy deletion (disk-reclaim step 4b) and
# the bare-mktemp ban that keeps every helper usable inside the scheduled
# sandbox (bare mktemp resolves to the sandbox-denied Darwin temp dir).
ci_test tests/last-stack-scratch-reclaim.sh
# Same reclaim family, one layer down: the VM sparse-disk trim runs
# `docker run --privileged --pid=host`. Its guard rails must fail CLOSED (no
# docker, unreachable daemon, non-local image) and must never pull an image
# unattended on a disk-pressure path. Runs in under a second against stubs.
ci_test tests/last-stack-vm-disk-trim.sh
ci_test tests/last-stack-no-bare-mktemp.sh
ci_test tests/last-stack-class-a-heal.sh
ci_test tests/last-stack-sccache-health.sh
ci_test tests/last-stack-shell-prelude.sh
# The Bash PreToolUse guards run on every agent tool call, and a regression
# there denies work fleet-wide rather than failing one run. The merged-stream
# guard produced 97 distinct denials in one 24h window while its only test
# sat behind LAST_STACK_CI_FULL=1. ~4s.
ci_test tests/last-stack-hooks-guards.sh
# The safe-capture helper the guard's deny text now points agents at. If it
# regresses, the deny message advertises a broken escape route on every
# blocked call. Runs in well under a second against local stubs.
ci_test tests/last-stack-json-capture.sh
ci_test tests/last-stack-brain-append-heartbeat.sh
ci_test tests/last-stack-obs-sentry-locator.sh
# sentry-triage Step 2/3 policy. It used to be prose in the prompt, where two
# defects (no sample-event drop, unreachable P3 rule) minted a bad card that
# cost a pickup slot. The policy is executable now, so pin it here. <1s.
ci_test tests/last-stack-sentry-triage-classify.sh
ci_test tests/last-stack-install-routines.sh
ci_test tests/last-stack-routines-registry-host-paths.sh
ci_test tests/last-stack-feature-prove-routine.sh
ci_test tests/last-stack-fleet-performance-routine.sh
ci_test tests/last-stack-why-stopped-routine.sh
ci_test tests/last-stack-why-stopped-loom.sh
ci_test tests/last-stack-routine-observer-why-loom.sh
ci_test tests/last-stack-canary-red-heal-routine.sh
ci_test tests/last-stack-canary-red-loom.sh
ci_test tests/last-stack-canary-loom.sh
ci_test tests/last-stack-lastdb-safe-upgrade-loom-only.sh
# Class A must not fire on class-a-heal wrapper timeout when heal exits 0.
ci_test tests/last-stack-why-stopped-class-a-timeout.sh
ci_test tests/last-stack-lastdb-ops-offenders.sh
ci_test tests/last-stack-lastdb-ops-offenders-routine.sh
ci_test tests/last-stack-kanban-pickup-workers.sh
ci_test tests/last-stack-kanban-pickup-gate.sh
# last-stack ci-required is forge run --all, not a per-repo ci watch.
# Pickup kept filing last-stack watcher cards because pgrep missed the fleet
# supervisor. Pin the classifier in the required gate.
ci_test tests/last-stack-lastgit-ci-coverage.sh
# Poison park must hydrate bodies via keyed show; list projections have none.
ci_test tests/last-stack-park-stuck-merge-poison-cards.sh
ci_test tests/last-stack-pickup-work-policy.sh
ci_test tests/last-stack-routines-kanban-pickup.sh
ci_test tests/last-stack-kanban-validate-routine.sh
ci_test tests/last-stack-pr-reaper-stale-open-heal.sh
ci_test tests/last-stack-factory-hardening.sh
ci_test tests/last-stack-factory-ready-buffer-activation.sh
ci_test tests/morning-sync-live-human-gate-reconcile.sh
ci_test tests/last-stack-factory-health-backlog.sh
ci_test tests/last-stack-launchagent-stable-path.sh
ci_test tests/last-stack-todo-rank.sh
ci_test tests/last-stack-kanban-done-when-eval.sh
ci_test tests/last-stack-driver-hierarchy.sh
ci_test tests/last-stack-milestone-slice-satisfaction.sh
ci_test tests/last-stack-feature-delivery-effective-flow-proof.sh
ci_test tests/last-stack-kanban-file-pr.sh
ci_test tests/last-stack-kanban-file-pr-host-track-install.sh
ci_test tests/last-stack-kanban-decision-check.sh
ci_test tests/last-stack-sanitize-structured-fields.sh
ci_test tests/last-stack-board-closeout-sweep-logic.sh
ci_test tests/last-stack-board-closeout-sweep.sh
ci_test tests/last-stack-board-closeout-merge-proof-guard.sh
ci_test tests/last-stack-board-closeout-evidence-freshness.sh
ci_test tests/last-stack-loom-reaper.sh
ci_test tests/last-stack-card-reaper-run.sh
ci_test tests/last-stack-card-closeout.sh
ci_test tests/last-stack-skill-frontmatter-yaml.sh
ci_test tests/last-stack-routines-host-track-post-install.sh
ci_test tests/last-stack-unattached-outcome-heal.sh
ci_test tests/last-stack-north-star-ledger-sync.sh
ci_test tests/last-stack-north-star-proof-registry.sh
ci_test tests/last-stack-north-star-proof-canary-pipeline-v2.sh
ci_test tests/last-stack-north-star-proof-uuid-hash-group.sh
ci_test tests/last-stack-north-star-proof-io-free.sh
ci_test tests/last-stack-north-star-proof-delete-returns-bytes.sh
ci_test tests/last-stack-north-star-proof-ideal-storage-shape.sh
ci_test tests/last-stack-north-star-proof-exemem-cloud-account.sh
ci_test tests/last-stack-org-cloud-membership-dogfood.sh
ci_test tests/last-stack-org-cloud-offline-artifact-fixture.sh
ci_test tests/last-stack-dogfood-resource-isolate.sh
ci_test tests/last-stack-secret-env-run.sh
ci_test tests/last-stack-ship-feature-milestones.sh
ci_test tests/last-stack-fix-it-skill.sh
ci_test tests/last-stack-incident-analysis-skill.sh
ci_test tests/last-stack-design-pack.sh
ci_test tests/last-stack-ship-handoff.sh
ci_test tests/last-stack-real-human-notify.sh
ci_test tests/last-stack-lint-prompts.sh --ci
ci_test tests/last-stack-lastdb-access-watch.sh
ci_test tests/last-stack-routines-prompt-doctor.sh
ci_test tests/last-stack-routine-prompt-outcome-contract.sh
ci_test tests/last-stack-literal-markdown-append.sh
ci_test tests/last-stack-lint-machine-leaks.sh
ci_test tests/last-stack-audit-f-prefix-callers.sh
ci_test tests/last-stack-papercut-reconciler-contract.sh
ci_test tests/last-stack-papercut-queue.sh
# Producer half of the same pipeline: the reconciler contract above guards the
# only routine that turns papercuts into cards, and nothing guarded the rule
# telling agents to file them in the first place.
ci_test tests/last-stack-papercut-filing-contract.sh
# Close-out is the last-chance producer for those same papercuts, plus the
# full LastDB report of what the session actually did.
ci_test tests/last-stack-closeout-skill-contract.sh
ci_test tests/last-stack-papercut-lifecycle-close.sh
ci_test tests/last-stack-papercut-lifecycle-helper-run-install.sh
ci_test tests/last-stack-pipeline-stuck-papercut-file.sh
ci_test tests/last-stack-canary-pipeline.sh
ci_test tests/last-stack-soak-heal-loom.sh
ci_test tests/last-stack-ship-soak-loom.sh
ci_test tests/last-stack-ship-soak-host-track-install.sh
ci_test tests/last-stack-command-modes.sh
ci_test tests/last-stack-north-star-portal-resolver.sh
ci_test tests/last-stack-portal-wt-fetch-detaches-idle-main.sh
ci_test tests/last-stack-portal-wt-rm-accepts-branch.sh
ci_test tests/last-stack-portal-wt-start-help.sh
ci_test tests/last-stack-pickup-zsh-timeout.sh
ci_test tests/last-stack-portal-live-checkout.sh
ci_test tests/last-stack-pipeline-health-gate.sh
ci_test tests/last-stack-canary-soak-watch-gate.sh
ci_test tests/last-stack-pipeline-deploy-scan.sh
ci_test tests/last-stack-whats-wrong-loom.sh
# The shared LastDB retry matcher decides whether a routine survives node
# backpressure. A silent narrowing of it turns every transient 503 into a
# red routine, so the fixture belongs in the required gate, not the
# LAST_STACK_CI_FULL suite. It runs in about a second (no node, no sleep).
ci_test tests/last-stack-lastdb-retry.sh
ci_test tests/last-stack-whats-wrong-routine.sh
ci_test tests/last-stack-forge-dead-trigger.sh
ci_test tests/last-stack-forge-api.sh
# Consumer half of the same wrapper contract: the merge probe is the only
# caller whose failure mode was a SILENT wrong answer (every Forgejo PR read
# as unmerged for days because a bad --jq call was hidden by 2>/dev/null).
ci_test tests/last-stack-card-closeout-merge-probe.sh
ci_test tests/last-stack-deploy-gated-closeout.sh
ci_test tests/last-stack-board-closeout-escalation.sh
ci_test tests/last-stack-legacy-residue-closeout.sh
ci_test tests/last-stack-why-shipping-stopped.sh
ci_test tests/host-track-artifacts.sh
ci_test tests/host-track-on-channel-unpublished-main.sh
ci_test tests/host-track-safe-upgrade-probe.sh
ci_test tests/host-track-canary-soak.sh
ci_test tests/host-track-soak-red-files-card.sh
ci_test tests/host-track-local-safe-staleness.sh
ci_test tests/host-track-deployment-freshness.sh
ci_test tests/lastseek-host-track.sh
ci_test tests/host-track-registry-compliance.sh
# Soak gate correctness: min_checks counting, one-incident heal keying across
# digests, post-flip rollback. A regression here silently flips a bad binary
# onto PATH fleet-wide — same silent-cutover family as the tests above.
ci_test tests/host-track-soak-gate.sh
# The other half of the same gate: what `host-track status` REPORTS about it.
# The check counter alone reads as over-satisfied for most of a soak window,
# so a soaking canary renders as a stuck promotion and costs someone a hunt.
# Pins that the reported window is the one `soak_watch_one` applies, not the
# stamp's own copy.
ci_test tests/host-track-soak-wall-clock.sh
ci_test tests/last-stack-fleet-channel-freshness-gate.sh
ci_test tests/last-stack-artifact-host-track-proof.sh
ci_test tests/last-stack-artifact-layout.sh
ci_test tests/last-stack-artifact-layout-mirror-clean.sh
ci_test tests/last-stack-artifact-routine-freshness.sh
ci_test tests/last-stack-artifact-one-rule.sh
ci_test tests/last-stack-post-merge-safe-upgrade.sh
ci_test tests/last-stack-post-merge-convergence.sh
ci_test tests/last-stack-lastdb-safe-upgrade-launchd-job.sh
ci_test tests/last-stack-lastdb-safe-upgrade-live-socket-health.sh
ci_test tests/last-stack-lastdb-safe-upgrade-candidate-class.sh
ci_test tests/last-stack-lastdb-safe-upgrade-latency-bar.sh
ci_test tests/last-stack-lastdb-safe-upgrade-cas-probe.sh
ci_test tests/last-stack-lastdb-write-path-cow-probe.sh
ci_test tests/last-stack-safe-upgrade-backup-dedup.sh
ci_test tests/last-stack-safe-upgrade-backup-retention.sh
ci_test tests/last-stack-lastdb-safe-upgrade-owner-lock.sh
ci_test tests/last-stack-lastdb-canary-dogfood.sh
ci_test tests/last-stack-canary-build-main.sh
ci_test tests/last-stack-canary-resolve-lastdbd.sh
ci_test tests/last-stack-dogfood-rotate-gate.sh
ci_test tests/last-stack-dogfood-rotate-routine.sh
ci_test tests/last-stack-lastdb-memory-guard.sh
ci_test tests/last-stack-host-memory-guards.sh
ci_test tests/last-stack-generator-shed-gate.sh

# Reclaim live-guard fixture. This one is in the REQUIRED gate, not the
# LAST_STACK_CI_FULL suite, because the failure it catches destroys a
# developer's build outputs under an in-flight build -- and the guard is a set
# of predicates (live cwd, live exec image under target/, fresh build marker,
# disk-pressure floor) that a later edit can silently narrow. It runs in about
# four seconds: it skips lsof and board reads, injects the live paths, and uses
# `sleep` as the fixture process, so it fits the foreground budget.
ci_test tests/last-stack-worktree-reclaim.sh
ci_test tests/last-stack-disk-reclaim-stripped-path.sh

# The install-smoke bounds. This file was written for a canary that kept dying
# mute at the agent tool's 600s foreground cap, and it was reachable only under
# LAST_STACK_CI_FULL=1 — so nothing in the required gate held those bounds in
# place. It is pure helper behaviour plus wiring greps; a few seconds.
#
# APPENDED, deliberately. ci_test assigns a shard by list POSITION, so inserting
# a test anywhere else renumbers every test after it into a different shard and
# re-pairs concurrent neighbours. Doing that here moved
# tests/last-stack-canary-pipeline.sh into a shard where it failed under load.
# New tests go at the end.
ci_test tests/llms-txt-install-smoke-bounded.sh

# Review-ref extraction for the papercut lifecycle closer. The parser feeds live
# `lastgit cr view` / forge API calls, so a prose-greedy or punctuation-keeping
# regex spends every reconciler pass on 404s against refs that do not exist.
# Stubbed venues, no network, under a second.
#
# APPENDED (see the note above): ci_test shards by list position.
ci_test tests/last-stack-papercut-lifecycle-close-ref-extraction.sh

# Socket self-identification for the lastdb-safe-upgrade skill. Unlabelled curl
# traffic lands in the client=unknown row of `lastdb ops`, and an upgrade probe
# that cannot be named is an offender nobody can rule out during a slow node.
# Static grep over joined continuation lines; no node, milliseconds.
#
# APPENDED (see the note above): ci_test shards by list position.
ci_test tests/last-stack-lastdb-safe-upgrade-client-header.sh

# The north-star dashboard refresh and its durable-status wrapper. Both scripts
# landed with cr-mtfv3lau-fa2b but were never named here, so required CI only
# lint-checked them (the tests/*.sh globs above are shellcheck and `bash -n`, not
# execution). That left the silent-exit fix ungated: an edit to
# bin/last-stack-north-star-dashboard-run could restore a mute exit and still
# merge green. Both are hermetic — fake generators, a temp status file, no
# network, no brain write — and finish in a few seconds.
#
# APPENDED (see the note above): ci_test shards by list position.
ci_test tests/last-stack-north-star-dashboard.sh
ci_test tests/last-stack-north-star-dashboard-run.sh

# Durable sentinel receipts gate every primary cutover.
# APPENDED (see the note above): ci_test shards by list position.
ci_test tests/last-stack-lastdb-safe-upgrade-skill.sh

# The tracker gate is fixture-only and finishes in under one second.
#
# APPENDED (see the shard-stability note above): ci_test shards by list position.
ci_test tests/last-stack-north-star-proof-no-scan-access.sh
