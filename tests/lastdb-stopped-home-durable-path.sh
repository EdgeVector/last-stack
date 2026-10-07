#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
SCRIPT="$ROOT/skills/lastdb-safe-upgrade/scripts/stopped-home-copy.sh"
bash -n "$SCRIPT"
# shellcheck source=../skills/lastdb-safe-upgrade/scripts/stopped-home-copy.sh
. "$SCRIPT"

# Use a worktree fixture because the legacy /private/tmp rule must not
# accept this path before the durable STATE rule runs.
TEST_ROOT="$(mktemp -d "$ROOT/.durable-stopped-copy-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
fake_home="$TEST_ROOT/owner"
live_home="$TEST_ROOT/live"
parent="$fake_home/.local/state/last-stack/cloud-rescue/source-copies"
mkdir -p "$live_home" "$parent"
chmod 700 "$parent"
copy="$parent/primary-only"
claim_script="$ROOT/skills/lastdb-safe-upgrade/scripts/claim-stopped-copy-waiver.py"
decision=decision-2026-10-06-cloud-sync-rescue-risk-acceptance
waiver_claim() {
  local path="$1"
  shift
  HOME="$fake_home" python3 "$claim_script" --home "$live_home" \
    --pid 1234 --start-ts 5678 --copy-path "$path" \
    --decision-slug "$decision" "$@"
}

(
  HOME="$fake_home"
  validate_copy_path "$copy" "$live_home"
) || { echo 'FAIL: case durable-private-path' >&2; exit 1; }
waiver_claim "$copy" \
  || { echo 'FAIL: case durable-waiver-claim' >&2; exit 1; }
jq -e --arg path "$copy" '.copy_path == $path' \
  "$live_home/.cloud_backup_unproved_flush_claim" >/dev/null \
  || { echo 'FAIL: case durable-waiver-path' >&2; exit 1; }
waiver_claim "$copy" --release \
  || { echo 'FAIL: case durable-waiver-release' >&2; exit 1; }

chmod 755 "$parent"
if (
  HOME="$fake_home"
  validate_copy_path "$copy" "$live_home"
) >"$TEST_ROOT/mode.out" 2>&1; then
  echo 'FAIL: case durable-private-mode' >&2; exit 1
fi
grep -Fq 'copy-parent-not-private' "$TEST_ROOT/mode.out" \
  || { echo 'FAIL: case durable-private-mode-reason' >&2; exit 1; }
if waiver_claim "$copy" >"$TEST_ROOT/claim-mode.out" 2>&1; then
  echo 'FAIL: case durable-waiver-private-mode' >&2; exit 1
fi
chmod 700 "$parent"

if (
  HOME="$fake_home"
  stat() {
    if [ "$1" = -f ] && [ "$2" = %u ] && [ "$3" = "$parent" ]; then
      printf '%s\n' "$(( $(id -u) + 1 ))"
    else
      command stat "$@"
    fi
  }
  validate_copy_path "$copy" "$live_home"
) >"$TEST_ROOT/owner.out" 2>&1; then
  echo 'FAIL: case durable-owner' >&2; exit 1
fi
grep -Fq 'copy-parent-not-private' "$TEST_ROOT/owner.out" \
  || { echo 'FAIL: case durable-owner-reason' >&2; exit 1; }

if (
  HOME="$fake_home"
  stat() {
    if [ "$1" = -f ] && [ "$2" = %d ] && [ "$3" = "$parent" ]; then
      printf '0\n'
    else
      command stat "$@"
    fi
  }
  validate_copy_path "$copy" "$live_home"
) >"$TEST_ROOT/device.out" 2>&1; then
  echo 'FAIL: case durable-other-device' >&2; exit 1
fi
grep -Fq 'copy-on-other-device' "$TEST_ROOT/device.out" \
  || { echo 'FAIL: case durable-other-device-reason' >&2; exit 1; }

other="$fake_home/.local/state/last-stack/cloud-rescue/other"
mkdir -p "$other"
chmod 700 "$other"
if (
  HOME="$fake_home"
  validate_copy_path "$other/copy" "$live_home"
) >"$TEST_ROOT/other.out" 2>&1; then
  echo 'FAIL: case durable-unapproved-parent' >&2; exit 1
fi
grep -Fq 'copy-parent-not-approved' "$TEST_ROOT/other.out" \
  || { echo 'FAIL: case durable-unapproved-parent-reason' >&2; exit 1; }
if waiver_claim "$other/copy" >"$TEST_ROOT/claim-other.out" 2>&1; then
  echo 'FAIL: case durable-waiver-unapproved-parent' >&2; exit 1
fi

: >"$copy"
if (
  HOME="$fake_home"
  validate_copy_path "$copy" "$live_home"
) >"$TEST_ROOT/existing.out" 2>&1; then
  echo 'FAIL: case durable-existing-copy' >&2; exit 1
fi
grep -Fq 'copy-path-exists' "$TEST_ROOT/existing.out" \
  || { echo 'FAIL: case durable-existing-copy-reason' >&2; exit 1; }
if waiver_claim "$copy" >"$TEST_ROOT/claim-existing.out" 2>&1; then
  echo 'FAIL: case durable-waiver-existing-copy' >&2; exit 1
fi
unlink "$copy"

linked_home="$TEST_ROOT/linked-owner"
mkdir -p "$linked_home/.local/state/last-stack"
ln -s "$fake_home/.local/state/last-stack/cloud-rescue" \
  "$linked_home/.local/state/last-stack/cloud-rescue"
if (
  HOME="$linked_home"
  validate_copy_path \
    "$linked_home/.local/state/last-stack/cloud-rescue/source-copies/copy" \
    "$live_home"
) >"$TEST_ROOT/link.out" 2>&1; then
  echo 'FAIL: case durable-symlink-ancestor' >&2; exit 1
fi
grep -Fq 'copy-parent-not-canonical' "$TEST_ROOT/link.out" \
  || { echo 'FAIL: case durable-symlink-ancestor-reason' >&2; exit 1; }
if waiver_claim \
  "$linked_home/.local/state/last-stack/cloud-rescue/source-copies/copy" \
  >"$TEST_ROOT/claim-link.out" 2>&1; then
  echo 'FAIL: case durable-waiver-symlink-ancestor' >&2; exit 1
fi
if HOME="$linked_home" python3 "$claim_script" --home "$live_home" \
  --pid 1234 --start-ts 5678 \
  --copy-path "$linked_home/.local/state/last-stack/cloud-rescue/source-copies/copy" \
  --decision-slug "$decision" >"$TEST_ROOT/claim-linked-home.out" 2>&1; then
  echo 'FAIL: case durable-waiver-canonical-parent' >&2; exit 1
fi

if (
  HOME="$fake_home"
  validate_copy_path "$copy" "$fake_home"
) >"$TEST_ROOT/nested.out" 2>&1; then
  echo 'FAIL: case durable-under-primary-home' >&2; exit 1
fi
grep -Fq 'copy-under-home' "$TEST_ROOT/nested.out" \
  || { echo 'FAIL: case durable-under-primary-home-reason' >&2; exit 1; }
if HOME="$fake_home" python3 "$claim_script" --home "$fake_home" \
  --pid 1234 --start-ts 5678 --copy-path "$copy" \
  --decision-slug "$decision" >"$TEST_ROOT/claim-nested.out" 2>&1; then
  echo 'FAIL: case durable-waiver-under-primary-home' >&2; exit 1
fi

temp_copy="/private/tmp/lastdb-durable-compat-$$-$RANDOM"
validate_copy_path "$temp_copy" "$live_home" \
  || { echo 'FAIL: case legacy-temp-copy' >&2; exit 1; }
waiver_claim "$temp_copy" \
  || { echo 'FAIL: case legacy-temp-waiver-claim' >&2; exit 1; }
waiver_claim "$temp_copy" --release \
  || { echo 'FAIL: case legacy-temp-waiver-release' >&2; exit 1; }

printf 'DURABLE-PATH-GATE: private exact STATE parent, canonical path, same owner and device\n'
