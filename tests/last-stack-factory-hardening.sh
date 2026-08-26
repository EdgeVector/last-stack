#!/usr/bin/env bash
# Smoke tests for factory-hardening tools (no destructive live actions).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

bash -n "$ROOT/bin/last-stack-lastdb-pressure"
bash -n "$ROOT/bin/last-stack-why-stopped"
bash -n "$ROOT/bin/last-stack-why-stopped-loom"
bash -n "$ROOT/bin/last-stack-whats-wrong-loom"
bash -n "$ROOT/bin/last-stack-whats-wrong-routine"
bash -n "$ROOT/bin/last-stack-canary-red-loom"
bash -n "$ROOT/bin/last-stack-canary-red-heal-routine"
bash -n "$ROOT/bin/last-stack-fold-ci-health"
bash -n "$ROOT/bin/last-stack-generator-preflight"
bash -n "$ROOT/bin/last-stack-kanban-file-pr"
[ -x "$ROOT/bin/last-stack-kanban-file-pr" ] || chmod +x "$ROOT/bin/last-stack-kanban-file-pr"
python3 -m py_compile "$ROOT/bin/last-stack-kanban-decision-check"
grep -q 'last-stack-kanban-decision-check' "$ROOT/bin/last-stack-kanban-file-pr" \
  || fail "file-pr missing last-stack-kanban-decision-check"
grep -q 'last-stack-kanban-file-pr' "$ROOT/routines/milestone-driver.md" \
  || fail "milestone-driver missing last-stack-kanban-file-pr"
grep -q 'last-stack-kanban-decision-check' "$ROOT/routines/milestone-driver.md" \
  || fail "milestone-driver missing last-stack-kanban-decision-check"
grep -q 'last-stack-kanban-file-pr' "$ROOT/routines/dogfood-rotate.md" \
  || fail "dogfood-rotate missing last-stack-kanban-file-pr"
grep -q 'last-stack-kanban-file-pr' "$ROOT/routines/kanban-validate.md" \
  || fail "kanban-validate missing last-stack-kanban-file-pr"
grep -q 'last-stack-kanban-file-pr' "$ROOT/routines/kanban-watch.md" \
  || fail "kanban-watch missing last-stack-kanban-file-pr for Kind:pr filing"
grep -q 'block-status deferred' "$ROOT/routines/kanban-watch.md" \
  || fail "kanban-watch missing deferred park for hollow Kind:pr"
bash -n "$ROOT/bin/last-stack-why-stopped-routine"
bash -n "$ROOT/bin/last-stack-lastdb-ops-offenders"
bash -n "$ROOT/bin/last-stack-lastdb-ops-offenders-routine"

# Pressure probe: should produce a level line (cool or hot) against live node, or exit 2 if CLI missing
set +e
out="$("$ROOT/bin/last-stack-lastdb-pressure" 2>/dev/null)"
rc=$?
set -e
case "$rc" in
  0|1|2) ;;
  *) fail "lastdb-pressure unexpected exit $rc" ;;
esac
if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then
  printf '%s\n' "$out" | grep -q 'LAST_STACK_LASTDB_PRESSURE level=' \
    || fail "missing pressure line: $out"
fi

# Generator preflight: exit 0 or 75 only
set +e
"$ROOT/bin/last-stack-generator-preflight" test-fixture >/tmp/gen-pre.$$ 2>&1
grc=$?
set -e
case "$grc" in
  0|75) ;;
  *) fail "generator-preflight exit $grc: $(cat /tmp/gen-pre.$$)" ;;
esac
rm -f /tmp/gen-pre.$$

# why-stopped --json should classify something
set +e
wout="$("$ROOT/bin/last-stack-why-stopped" --json --quiet 2>/dev/null)"
wrc=$?
set -e
[ "$wrc" -eq 0 ] || fail "why-stopped exit $wrc"
printf '%s\n' "$wout" | grep -q 'classes' || fail "why-stopped json missing classes: $wout"

# fold-ci-health: 0 or 1
set +e
"$ROOT/bin/last-stack-fold-ci-health" >/dev/null 2>&1
frc=$?
set -e
case "$frc" in
  0|1) ;;
  *) fail "fold-ci-health exit $frc" ;;
esac

# Prompts mention backpressure / lifecycle
grep -q 'last-stack-generator-preflight' "$ROOT/routines/north-star-driver.md" \
  || fail "north-star-driver missing generator preflight"
grep -q 'last-stack-generator-preflight' "$ROOT/routines/milestone-driver.md" \
  || fail "milestone-driver missing generator preflight"
grep -q 'Papercut lifecycle' "$ROOT/routines/papercut-reconciler.md" \
  || fail "papercut-reconciler missing lifecycle section"
grep -q 'class-a-heal-timeout' "$ROOT/routines/kanban-pickup.md" \
  || fail "kanban-pickup missing timeout polish"
[ -f "$ROOT/routines/why-stopped.md" ] || fail "why-stopped prompt missing"
grep -q 'last-stack-why-stopped-loom' "$ROOT/routines/why-stopped.md" \
  || fail "why-stopped prompt missing loom hook"
[ -f "$ROOT/routines/whats-wrong.md" ] || fail "whats-wrong prompt missing"
grep -q 'last-stack-whats-wrong-loom' "$ROOT/routines/whats-wrong.md" \
  || fail "whats-wrong prompt missing loom hook"
[ -f "$ROOT/routines/lastdb-canary-red-heal.md" ] || fail "canary-red-heal prompt missing"
grep -q 'last-stack-canary-red-loom' "$ROOT/routines/lastdb-canary-red-heal.md" \
  || fail "canary-red-heal prompt missing loom hook"
[ -x "$ROOT/bin/last-stack-feature-prove-routine" ] || fail "feature-prove installer missing"
[ -x "$ROOT/bin/last-stack-fleet-performance-routine" ] || fail "fleet-performance installer missing"
[ -f "$ROOT/routines/fleet-performance.md" ] || fail "fleet-performance prompt missing"
grep -qi 'routines route' "$ROOT/routines/fleet-performance.md" \
  || fail "fleet-performance prompt missing no-route rule"
grep -q 'sop-routines-registry-canonical' "$ROOT/routines/fleet-performance.md" \
  || fail "fleet-performance prompt missing canonical-registry SOP"
grep -q 'ROUTINES_HOME' "$ROOT/routines/fleet-performance.md" \
  || fail "fleet-performance prompt missing live registry path"
grep -q 'New releases — working well' "$ROOT/routines/morning-sync.md" \
  || fail "morning-sync prompt missing new-releases live-proof section"
grep -q 'not-on-this-machine-yet' "$ROOT/routines/morning-sync.md" \
  || fail "morning-sync new-releases section missing host-track lag verdict"
grep -q 'New releases — working well' "$ROOT/skills/morning-sync/SKILL.md" \
  || fail "morning-sync skill missing new-releases live-proof section"

printf 'ok: factory-hardening smoke passed\n'
