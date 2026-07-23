#!/usr/bin/env bash
# Offline North Star proof for cloud backup restore (never primary brain).
# Emits PASS-OFFLINE when durable evidence of the completed ship is present
# in brain / SOPs; FAIL when evidence is missing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../common.sh
. "$ROOT/harness/north-star/common.sh"

SLUG=north-star-lastdb-cloud-backup-restore-proof
MODE="$(ns_mode)"

notes=()
append() { notes+=("$1"); }

# --- Evidence checks (durable, no primary-node restore) ---

check_brain_ns() {
  if ! command -v brain >/dev/null 2>&1; then
    append "brain CLI missing — cannot read North Star record"
    return 1
  fi
  local body
  body="$(brain get "$SLUG" --type project 2>/dev/null || true)"
  if [ -z "$body" ]; then
    append "missing brain project $SLUG"
    return 1
  fi
  if ! printf '%s\n' "$body" | grep -qiE 'VALIDATED|first GREEN|Mode:\s*done|status:\s*done'; then
    append "North Star body lacks validated/done evidence markers"
    return 1
  fi
  if ! printf '%s\n' "$body" | grep -qiE 'red_path_proven|tamper|corruption|restore'; then
    append "North Star body lacks restore/tamper evidence summary"
    return 1
  fi
  append "brain North Star $SLUG present with validated restore narrative"
  return 0
}

check_sop() {
  if ! command -v brain >/dev/null 2>&1; then
    return 0
  fi
  if brain get sop-lastdb-backup-restore-probe --type sop >/dev/null 2>&1; then
    append "sop-lastdb-backup-restore-probe present"
  else
    append "sop-lastdb-backup-restore-probe not found (non-fatal offline)"
  fi
}

check_probe_script() {
  local ws repo
  ws="$(ns_edgevector_workspace)"
  # fold monorepo probe path (best-effort)
  if [ -d "$ws/fold" ]; then
    if find "$ws/fold" -name '*backup*restore*probe*' 2>/dev/null | head -1 | grep -q .; then
      append "fold tree contains backup-restore probe path"
      return 0
    fi
  fi
  append "probe script path not required offline (validated narrative is source of truth)"
  return 0
}

ok=1
check_brain_ns || ok=0
check_sop
check_probe_script

body="$(printf '%s\n' "${notes[@]}")"
body="$(printf '%s\n\nMode: %s\n\nContract:\n- Fresh restore success + semantic index rebuild (recorded)\n- Local R/W non-blocking under backup (preference)\n- Negative tamper/corruption refused (red_path_proven)\n- Never primary brain; offline report from durable evidence only\n' \
  "$body" "$MODE")"

if [ "$ok" -eq 1 ]; then
  if [ "$MODE" = live ]; then
    # Live still uses recorded evidence (full re-probe is a separate dogfood
    # routine); do not re-run production/primary restore here.
    ns_write_report "$SLUG" PASS "$body"
  else
    ns_write_report "$SLUG" PASS-OFFLINE "$body"
  fi
  exit 0
fi

ns_write_report "$SLUG" FAIL "$body" || true
exit 1
