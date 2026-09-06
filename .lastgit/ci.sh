#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

# Sandboxed macOS runners cannot write Python's default user cache directory.
# Keep bytecode compilation inside this gate's disposable temp space so every
# Python helper is checked without depending on host-home permissions.
CI_PYTHON_CACHE="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-ci-pycache.XXXXXX")"
export PYTHONPYCACHEPREFIX="$CI_PYTHON_CACHE"

# Tests drive real bin/ scripts, and several of those append a fleet heartbeat.
# Without an override the appender resolves its default from the install root it
# runs under, so a suite run from a checkout whose logs/ points at
# ~/.local/state/last-stack/runtime/logs writes fixture rows into the PRODUCTION
# fleet log (aaa111/bbb222 canary-gate rows, 264 of them over 21h). Every fleet
# reader then consumes fixtures as real routine state. Sandbox the whole suite
# here, but never override a test that already set its own path.
if [ -z "${LAST_STACK_HEARTBEATS_FILE:-}" ]; then
  CI_HEARTBEATS_FILE="$(mktemp "${TMPDIR:-/tmp}/last-stack-ci-heartbeats.XXXXXX")"
  export LAST_STACK_HEARTBEATS_FILE="$CI_HEARTBEATS_FILE"
else
  CI_HEARTBEATS_FILE=""
fi
CI_SHARD_LOG_DIR=""
cleanup_ci_temp() {
  rm -rf -- "$CI_PYTHON_CACHE"
  [ -z "$CI_SHARD_LOG_DIR" ] || rm -rf -- "$CI_SHARD_LOG_DIR"
  [ -z "$CI_HEARTBEATS_FILE" ] || rm -f -- "$CI_HEARTBEATS_FILE"
}
trap cleanup_ci_temp EXIT

CI_SHARD_INDEX="${LAST_STACK_CI_SHARD_INDEX:-}"
CI_SHARD_COUNT="${LAST_STACK_CI_SHARD_COUNT:-1}"

if [ -z "$CI_SHARD_INDEX" ]; then
  for script in setup bin/* lib/*.sh hooks/*.sh tests/*.sh .lastgit/ci.sh; do
    [ -f "$script" ] || continue
    first_line="$(sed -n '1p' "$script")"
    case "$first_line" in
      *bash*|*sh*) bash -n "$script" ;;
    esac
  done

  if [ "${LAST_STACK_CI_FULL:-0}" = "1" ]; then
    # Collect failures instead of aborting. `set -e` is active, so this loop
    # used to stop at the FIRST red test and every later test never ran, with
    # nothing said about the skip: the exhaustive suite gave a less complete
    # answer than the sharded gate below, which collects per-shard failures.
    # The unconditional `exit 0` that closed this branch was the second half of
    # the same defect -- it was unreachable only because `set -e` fired first,
    # so any change making the loop tolerant without deleting it would have
    # turned "aborts early" into "reports success no matter what".
    # papercut-last-stack-ci-full-suite-aborts-on-first-failure-and-exits-zero-20260906
    full_failed=""
    full_failed_count=0
    full_ran=0
    for test_script in tests/*.sh; do
      [ -f "$test_script" ] || continue
      echo "ci_test start: $test_script"
      full_ran=$((full_ran + 1))
      if ! bash "$test_script"; then
        full_failed="${full_failed} ${test_script}"
        full_failed_count=$((full_failed_count + 1))
      fi
    done
    if [ "$full_failed_count" -ne 0 ]; then
      echo "last-stack CI full suite: ran=${full_ran} failed=${full_failed_count} scripts:${full_failed}" >&2
      exit 1
    fi
    echo "ok last-stack CI full suite ran=${full_ran}"
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
    instructions/asd-ste100.md \
    instructions/no-home-root-scan.md

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
    failed_shards=""
    shard_index=0
    for shard_pid in "${shard_pids[@]}"; do
      if ! wait "$shard_pid"; then shard_failed=1; failed_shards="${failed_shards} ${shard_index}"; fi
      shard_index=$((shard_index + 1))
    done
    # Passing shards first, failing shards last. lastgit ci status stores a
    # 12KB tail of the concatenated stream; a failing shard in the middle
    # used to vanish behind later PASS lines plus the bare summary.
    shard_index=0
    while [ "$shard_index" -lt "$CI_SHARD_COUNT" ]; do
      case " ${failed_shards} " in
        *" ${shard_index} "*) ;;
        *)
          echo "----- last-stack CI shard ${shard_index} ok -----"
          cat "$CI_SHARD_LOG_DIR/$shard_index.log"
          ;;
      esac
      shard_index=$((shard_index + 1))
    done
    for failed_index in $failed_shards; do
      echo "----- last-stack CI shard ${failed_index} FAILED -----"
      cat "$CI_SHARD_LOG_DIR/$failed_index.log"
    done
    if [ "$shard_failed" -ne 0 ]; then
      echo "last-stack required CI shard failed shards=${failed_shards# }" >&2
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
  echo "ci_test start: $*"
  bash "$@"
}

ci_test tests/last-stack-routine-read.sh
ci_test tests/last-stack-routine-read-proceed-on-stale.sh
ci_test tests/last-stack-ci-sharding.sh
# The other enumeration gap in this same file: LAST_STACK_CI_FULL=1 used to
# abort on the first red test and close with an unconditional exit 0, so the
# exhaustive path was both less complete than the sharded gate and one edit
# away from a permanent false green. Behavioural, against a fixture root. <2s.
ci_test tests/last-stack-ci-full-suite.sh
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
# The close guard holds the one reap that destroys work: a green auto-merge
# CR whose head never reached main. Required, not FULL-only — the defect it
# covers removed CRs from the open inventory, so nothing downstream noticed.
ci_test tests/last-stack-pr-reaper-close-guard.sh
ci_test tests/last-stack-factory-hardening.sh
ci_test tests/last-stack-milestone-driver-snapshot.sh
ci_test tests/last-stack-factory-ready-buffer-activation.sh
ci_test tests/morning-sync-live-human-gate-reconcile.sh
# Sentry issue pagination in the morning digest. Held out of the gate until
# 2026-09-06 because it failed printing nothing at all: it stubbed `fbrain`
# while usage-bugs.sh calls `brain`, so the fake PATH fell through to the live
# primary and the first assertion missed with no message. Hermetic now, ~2s.
ci_test tests/morning-sync-usage-bugs-pagination.sh
ci_test tests/last-stack-factory-health-backlog.sh
ci_test tests/last-stack-factory-health-runway.sh
ci_test tests/last-stack-factory-heal-tick.sh
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
ci_test tests/last-stack-board-closeout-stale-list-row.sh
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
# The probe and flip must bind to one exact digest. This test advances the
# channel after the final probe and proves that the successor starts a new soak.
ci_test tests/host-track-soak-probe-lock.sh
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
ci_test tests/last-stack-papercut-lifecycle-close-aggregate-merges.sh

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

# lastdb-canary-build-main was registered in config/routines-registry/ since
# 2026-08-05 but had no installer, so it never reached the live registry
# (papercut-no-registered-routine-produces-a-lastdb-canary-candidate-20260903).
# These pin the new zero-LLM staleness gate and its seed-if-missing installer.
# Hermetic fixtures, stubbed host-track/prompt/gate paths, no node, no network.
#
# APPENDED (see the shard-stability note above): ci_test shards by list position.
ci_test tests/last-stack-canary-build-main-gate.sh
ci_test tests/last-stack-lastdb-canary-build-main-routine.sh

# Row-count bar: a 0-row candidate against a non-zero baseline is RED.
# APPENDED (see the shard-stability note above): ci_test shards by list position.
ci_test tests/last-stack-safe-upgrade-rowcount-verdict.sh

# One exact Loom candidate must create the fresh DEV photograph receipt.
# APPENDED (see the shard-stability note above): ci_test shards by list position.
ci_test tests/last-stack-lastdb-safe-upgrade-dev-photograph-stamp.sh

# Portal bare mirrors must map remote branches into refs/remotes/origin/*, so a
# plain `git fetch origin` is never refused by a sibling worktree's branch and
# origin/<main> is never a clone-time tip. Hermetic: local bare repos only, no
# node, no network.
# APPENDED (see the shard-stability note above): ci_test shards by list position.
ci_test tests/last-stack-portal-wt-mirror-origin-refspec.sh

# New ci_test entries go at this append-only tail. A mid-list insertion
# renumbers every later shard assignment and has reddened the full gate once
# (papercut-last-stack-ci-sharding-contract-does-not-enforce-append-only-registration).
# A managed command only takes effect if PATH resolves into the active tree.
# install_artifact_links heals a PATH target only when links[] declares it, so
# an undeclared name is never looked at: last-stack ran a 2026-07-22 portal-wt
# for six weeks while `host-track check last-stack` printed ok. ~2s.
ci_test tests/host-track-path-shadow.sh

# A soak must DELAY an install, never prevent it: a channel merging faster than
# the window used to reset started_epoch forever, so the app never installed.
# The bound activates the newest green canary after N abandoned windows. The
# same test pins the other direction — carried soak credit is capped at
# `window - floor`, so a canary parked one second ago can never inherit a
# finished window and activate with no exposure of its own. Hermetic: temp
# stamp dir and fake probes, no node, no network. ~3s.
# APPENDED (see the shard-stability note above): ci_test shards by list position.
ci_test tests/host-track-soak-starve-bound.sh

# The forge is the gate of record for four factory repos, and every helper that
# reaches it resolved its token from the login keychain alone. When that
# keychain locks, `security ... -w` exits 51 SILENTLY and API, push, PR create
# and portal fetch fail together — five routines lost a night to it. Pins the
# resolution order and that no helper keeps a private keychain read. Hermetic:
# stubbed `security`/`lastsecrets` on PATH, no node, no network. ~1s.
# APPENDED (see the shard-stability note above): ci_test shards by list position.
ci_test tests/last-stack-forge-token-fallback.sh

# A failed `wt rm` used to print `try: wt rm <an unrelated live worktree>`. The
# token heuristic drew from the NORMALIZED id, which always contains `kanban`,
# so any same-portal sibling matched and the tool handed back a destructive
# command aimed at another agent's checkout. Pins that a bystander sharing only
# `kanban` is never named, that an ambiguous token names nothing, that a genuine
# near-miss typo IS still surfaced, and that a weak match never renders an
# executable `try: wt rm` line. Hermetic: temp portal + bare cache, no node,
# no network. ~2s.
# APPENDED (see the shard-stability note above): ci_test shards by list position.
ci_test tests/last-stack-portal-wt-rm-suggestion-scope.sh

# DEV photograph failure evidence must stay bounded and must exclude secret
# values, raw snapshot envelopes, object digests, and full CoW paths.
# APPENDED (see the shard-stability note above): ci_test shards by list position.
ci_test tests/last-stack-lastdb-dev-photograph-sanitize-tail.sh

# The CI-log helper answered a question about a commit with a green run while a
# red sibling run existed for the same commit. Measured over fold's complete
# task history: 288 of 4589 heads, and 279 heads carry failures in more than
# one run, so preferring a single failing run would hide almost as many as it
# fixed. Four routines read "Job succeeded" as evidence for a failing commit
# across three weeks. Also pins that a PR number is refused as a run number.
# Hermetic: stubbed `curl` and an on-disk log root, no forge, no network. ~1s.
# APPENDED (see the shard-stability note above): ci_test shards by list position.
ci_test tests/last-stack-forge-ci-log-run-selection.sh

# A shell test must not compare a measured wall clock against a bare literal.
# The number then measures the CI host: two tests went red on consecutive Forge
# runs on 2026-09-06 (PR 19) and a third — the safe-upgrade Loom driver bound,
# 8s against a designed 5s — went red on run 58 and blocked this very PR, while
# every assertion that detects the real defect passed. The class record named
# this lint as its unshipped follow-up. A justified literal opts out inline with
# `# wallclock-bound-ok: <reason>`; six existing bounds now state their slack
# ratio. Hermetic: reads tests/*.sh, runs nothing. ~1s.
# APPENDED (see the shard-stability note above): ci_test shards by list position.
ci_test tests/last-stack-lint-test-wallclock-bounds.sh

# Asking a helper for help must not be reported as a failure. Five helpers
# documented `-h`/`--help` in their own source and still exited 2, so every
# agent harness marked the discovery call `is_error=true`; one class record
# collected five recurrences over twelve days and TWO suites asserted the
# defect as the contract. Executes `--help` only for helpers enrolled in
# config/help-flag-contract.tsv, because a sweep over bin/ would fire
# last-stack-card-closeout, which reads `--help` as a card slug and escalates
# to a --force board move. Hermetic: runs five local helpers' help paths. ~1s.
# APPENDED (see the shard-stability note above): ci_test shards by list position.
ci_test tests/last-stack-help-flag-contract.sh

# --- Registration backfill, 2026-09-06 -------------------------------------
#
# papercut-last-stack-tests-can-land-unregistered-in-required-gate: the gate
# schedules tests through this explicit list, so a new file is discovered by
# nothing. 70 of 251 test files had never run in a required gate (63 of 215 on
# 2026-08-30, so the omission rate held near 29% while the suite grew). Every
# one of the 70 was executed standalone on 2026-09-06 at main 440093ea: 64
# passed. The 60 below are the passing ones that are also hermetic -- they
# sandbox HOME or read nothing outside the repo -- and together they add about
# 252s, roughly 63s per shard at the default four.
#
# The other 10 are recorded in tests/.ci-exempt with the reason each is out,
# and tests/last-stack-ci-test-registration.sh now fails when a test file is
# in neither place. APPENDED at the end: ci_test shards by list POSITION.
ci_test tests/brain-doctor-http-000.sh
ci_test tests/last-stack-active-programs-guard.sh
ci_test tests/last-stack-admin-deliver.sh
ci_test tests/last-stack-attribution-trailers.sh
ci_test tests/last-stack-board-closeout-park-bound.sh
ci_test tests/last-stack-board-drain-report.sh
ci_test tests/last-stack-brain-reference-guard.sh
ci_test tests/last-stack-canary-heal-harness-fence.sh
ci_test tests/last-stack-canary-v2-dogfood-gate.sh
ci_test tests/last-stack-cli-flag-gotchas-docs.sh
ci_test tests/last-stack-cli-preflight.sh
ci_test tests/last-stack-disk-reclaim-backup-retention.sh
ci_test tests/last-stack-dogfood-target-checkout.sh
ci_test tests/last-stack-driver-admission-fixture.sh
ci_test tests/last-stack-factory-health.sh
ci_test tests/last-stack-factory-ready-buffer-controller.sh
ci_test tests/last-stack-feature-portfolio-admission.sh
ci_test tests/last-stack-fkanban-compat-skills.sh
ci_test tests/last-stack-forge-json-jq.sh
ci_test tests/last-stack-forge-runner-lanes.sh
ci_test tests/last-stack-forge-runner-watchdog.sh
ci_test tests/last-stack-gh-pr-queue-state.sh
ci_test tests/last-stack-git-checkout-freshness.sh
ci_test tests/last-stack-host-track-artifact-invariant.sh
ci_test tests/last-stack-install-apps.sh
ci_test tests/last-stack-json-get.sh
ci_test tests/last-stack-lastdb-current.sh
ci_test tests/last-stack-lastdb-dev.sh
ci_test tests/last-stack-lastdb-safe-upgrade-binary-pair.sh
ci_test tests/last-stack-lastdb-safe-upgrade-deadline.sh
ci_test tests/last-stack-lastgit-stuck-merge-heal.sh
ci_test tests/last-stack-loom-exec-latest.sh
ci_test tests/last-stack-mask-secrets.sh
ci_test tests/last-stack-migrate-repo-local-worktrees.sh
ci_test tests/last-stack-milestone-factory-dashboard.sh
ci_test tests/last-stack-papercut-lifecycle-close-budget.sh
ci_test tests/last-stack-park-terminal-validation-todo.sh
ci_test tests/last-stack-portfolio-auto-refill.sh
ci_test tests/last-stack-portfolio-pass-record.sh
ci_test tests/last-stack-post-merge-map-loom.sh
ci_test tests/last-stack-pr-venue.sh
ci_test tests/last-stack-product-feature-ns-reconcile.sh
ci_test tests/last-stack-publish-status.sh
ci_test tests/last-stack-reclaim-keeps-tracked-dist.sh
ci_test tests/last-stack-repo-op-guard.sh
ci_test tests/last-stack-revenant-watch.sh
ci_test tests/last-stack-routine-job-shrink-gate.sh
ci_test tests/last-stack-routine-outcome-classify.sh
ci_test tests/last-stack-safe-upgrade-cli.sh
ci_test tests/last-stack-scrub-github-token-remotes.sh
ci_test tests/last-stack-self-upgrade.sh
ci_test tests/last-stack-session-miner-recent-jsonl.sh
ci_test tests/last-stack-setup-claude-brain-kanban.sh
ci_test tests/last-stack-setup-codex-brain-kanban.sh
ci_test tests/last-stack-setup-no-worktree-symlinks.sh
ci_test tests/last-stack-shared-checkout-guard.sh
ci_test tests/last-stack-ship-pipeline-gap-snapshot.sh
ci_test tests/last-stack-update-check.sh
ci_test tests/last-stack-verify-skill-links.sh
ci_test tests/machine-hygiene-empty-globs.sh

# Sentry credentials must remain usable when the login keychain is locked.
# APPENDED: ci_test shards by list position.
ci_test tests/last-stack-sentry-token-fallback.sh

# The registration guard itself. Kept last, and asserted to be registered by
# tests/last-stack-ci-sharding.sh, so the guard cannot quietly stop running.
ci_test tests/last-stack-ci-test-registration.sh
