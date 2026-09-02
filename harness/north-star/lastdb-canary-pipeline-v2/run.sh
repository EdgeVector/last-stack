#!/usr/bin/env bash
# north-star-slug: north-star-lastdb-canary-pipeline-v2
# Terminal proof for the LastDB canary pipeline v2 contract.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=harness/north-star/common.sh
. "$ROOT/harness/north-star/common.sh"

SLUG=north-star-lastdb-canary-pipeline-v2
MODE="$(ns_mode)"
PIPELINE="${LAST_STACK_CANARY_PIPELINE:-$ROOT/bin/last-stack-canary-pipeline}"
REPORT_DIR="$(ns_proof_dir)"
REPORT="$REPORT_DIR/$SLUG.md"
REPORT_TMP=""
FINALIZED=0

write_report_atomic() {
  local verdict="$1" body="$2" tmp
  mkdir -p "$REPORT_DIR"
  tmp="$(mktemp "$REPORT_DIR/.${SLUG}.XXXXXX")" || return 1
  REPORT_TMP="$tmp"
  if ! {
    printf '%s\n' "$verdict"
    printf '\n# North Star proof — %s\n\n' "$SLUG"
    printf 'Generated: %s\n\n' "$(ns_now)"
    printf '%s\n' "$body"
  } >"$tmp"; then
    rm -f "$tmp"
    REPORT_TMP=""
    return 1
  fi
  if ! mv "$tmp" "$REPORT"; then
    rm -f "$tmp"
    REPORT_TMP=""
    return 1
  fi
  REPORT_TMP=""
  printf 'PROOF_REPORT=%s\n' "$REPORT"
  printf 'PROOF_VERDICT=%s\n' "$verdict"
}

on_exit() {
  local rc=$? first=""
  [ -z "$REPORT_TMP" ] || rm -f "$REPORT_TMP"
  if [ "$FINALIZED" -ne 1 ]; then
    [ ! -f "$REPORT" ] || first="$(sed -n '1p' "$REPORT")"
    if [ "$first" != FAIL ]; then
      write_report_atomic FAIL "The proof stopped before it produced a complete verdict." >/dev/null 2>&1 || true
    fi
  fi
  exit "$rc"
}

trap on_exit EXIT
trap 'exit 130' HUP INT TERM

# A prior PASS must not survive a failed or interrupted run.
write_report_atomic FAIL "The proof started but did not complete." >/dev/null

fail() {
  local body="$1"
  write_report_atomic FAIL "$body" || true
  FINALIZED=1
  exit 1
}

evidence_line() {
  local label="$1"
  printf '%s\n' "$proof_out" | awk -v label="$label" '
    $1 == label { count += 1; line = $0 }
    END {
      if (count == 1) {
        print line
        exit 0
      }
      exit 1
    }
  '
}

field_value() {
  local line="$1" name="$2" token
  for token in $line; do
    case "$token" in
      "$name="*) printf '%s\n' "${token#*=}"; return 0 ;;
    esac
  done
  return 1
}

require_field() {
  local label="$1" line="$2" name="$3" expected="$4" actual
  actual="$(field_value "$line" "$name")" || fail "$body\n\nMissing field: $label $name."
  [ "$actual" = "$expected" ] || fail "$body\n\nInvalid field: $label $name=$actual; expected $expected."
}

require_real_value() {
  local label="$1" line="$2" name="$3" actual
  actual="$(field_value "$line" "$name")" || fail "$body\n\nMissing live field: $label $name."
  case "$actual" in
    ""|0|unknown|UNKNOWN|none|NONE|null|NULL|n/a|N/A|na|NA|placeholder|PLACEHOLDER|dry-run|dryrun|fixture|test|fake|dryrun-*|test-*|fake-*|placeholder-*)
      fail "$body\n\nPlaceholder live field: $label $name=$actual."
      ;;
  esac
}

require_oid() {
  local label="$1" line="$2" name="$3" actual
  require_real_value "$label" "$line" "$name"
  actual="$(field_value "$line" "$name")"
  case "$actual" in
    *[!0-9a-fA-F]*) fail "$body\n\nInvalid Git OID: $label $name=$actual." ;;
  esac
  [ "${#actual}" -ge 7 ] || fail "$body\n\nShort Git OID: $label $name=$actual."
}

case "$MODE" in
  live|offline) ;;
  *) fail "Invalid proof mode: $MODE." ;;
esac

[ -x "$PIPELINE" ] || fail "Missing canary pipeline command: $PIPELINE."

if [ "$MODE" = live ]; then
  proof_args=(proof --live --dry-run)
else
  proof_args=(proof --dry-run)
fi

set +e
proof_out="$("$PIPELINE" "${proof_args[@]}" 2>&1)"
proof_rc=$?
set -e

body="$(printf '%s\n\nMode: %s\nCommand: %s %s\nExit status: %s\n\n%s\n%s\n%s' \
  'LastDB canary pipeline v2 terminal proof.' "$MODE" "$PIPELINE" "${proof_args[*]}" "$proof_rc" \
  '```text' "$proof_out" '```')"

[ "$proof_rc" -eq 0 ] || fail "$body"

labels='BOOT_LEDGER OBSERVATIONS VERDICT RECONCILER HEAL_QUEUE CHANNELS LOOM DRY_RUN TEST_SUITE'
for label in $labels; do
  if ! line="$(evidence_line "$label")"; then
    fail "$body\n\nThe output must contain exactly one $label evidence line."
  fi
  require_field "$label" "$line" result ok
  case "$label" in
    BOOT_LEDGER) boot_line="$line" ;;
    VERDICT) verdict_line="$line" ;;
    CHANNELS) channels_line="$line" ;;
    LOOM) loom_line="$line" ;;
    DRY_RUN) dry_run_line="$line" ;;
  esac
done

require_field VERDICT "$verdict_line" sep-0830 window-open
require_field VERDICT "$verdict_line" sep-0831 'red:restart[guard-memory]'
require_field VERDICT "$verdict_line" sep-0901 red:status_latency
require_field DRY_RUN "$dry_run_line" no_primary_mutation 1
require_field DRY_RUN "$dry_run_line" stable_mutation false

if [ "$MODE" = live ]; then
  require_oid BOOT_LEDGER "$boot_line" source_oid
  require_oid BOOT_LEDGER "$boot_line" installed_oid
  require_real_value LOOM "$loom_line" graph_version
  require_real_value LOOM "$loom_line" graph_hash
  graph_hash="$(field_value "$loom_line" graph_hash)"
  [ "${#graph_hash}" -ge 12 ] || fail "$body\n\nShort Loom graph hash: $graph_hash."
  require_real_value CHANNELS "$channels_line" live_build
  require_real_value CHANNELS "$channels_line" stable_build
fi

if [ "$MODE" = live ]; then
  verdict=PASS
else
  verdict=PASS-OFFLINE
fi
write_report_atomic "$verdict" "$body" || exit 1
FINALIZED=1
