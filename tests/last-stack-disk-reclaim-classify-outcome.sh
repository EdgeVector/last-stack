#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="$ROOT/bin/last-stack-disk-reclaim-classify-outcome"

sample="$("$bin" \
  reclaimed_gb=0 \
  worktrees_pruned=0 \
  backups_pruned=0 \
  lastdb_copies_pruned=0 \
  ports_reaped=0 \
  kept_dirty=2 \
  kept_unique=19 \
  kept_outside=17 \
  remove_failed=3 \
  remove_failed_reason=main_worktree \
  backup_remove_failed=5 \
  backup_remove_failed_reason=operation_not_permitted \
  backup_lsof_inconclusive=0 \
  copy_remove_failed=0 \
  final_free=237Gi)"
case "$sample" in
  noop*"retained_main_worktree=3"*"backup_retained_permission_denied=5"*"actionable_remove_failed=0"*) ;;
  *)
    echo "expected retained disk-reclaim sample to classify as noop, got: $sample" >&2
    exit 1
    ;;
esac

real_failure="$("$bin" \
  reclaimed_gb=0 \
  worktrees_pruned=0 \
  backups_pruned=0 \
  lastdb_copies_pruned=0 \
  remove_failed=1 \
  remove_failed_reason=git_worktree_remove_failed \
  final_free=237Gi)"
case "$real_failure" in
  error*"actionable_remove_failed=1"*) ;;
  *)
    echo "expected real remove failure to stay actionable, got: $real_failure" >&2
    exit 1
    ;;
esac

reclaimed="$("$bin" \
  reclaimed_gb=12 \
  worktrees_pruned=1 \
  backups_pruned=0 \
  lastdb_copies_pruned=0 \
  remove_failed=0 \
  final_free=248Gi)"
case "$reclaimed" in
  ok*"reclaimed_gb=12"*"worktrees_pruned=1"*) ;;
  *)
    echo "expected successful reclaim to classify as ok, got: $reclaimed" >&2
    exit 1
    ;;
esac

low_disk="$("$bin" \
  reclaimed_gb=0 \
  worktrees_pruned=0 \
  backups_pruned=0 \
  lastdb_copies_pruned=0 \
  remove_failed=0 \
  low_disk=28Gi \
  final_free=28Gi)"
case "$low_disk" in
  error*"low_disk=28Gi"*) ;;
  *)
    echo "expected low disk to classify as error, got: $low_disk" >&2
    exit 1
    ;;
esac

echo "ok last-stack-disk-reclaim-classify-outcome"
