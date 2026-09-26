#!/usr/bin/env bash
# Offline contract for north-star-lastdb-cloud-sync-resume.
# The source check reads a fixture tree, a Fold worktree, or the Fold portal.
# It does not open a LastDB home and it does not re-enable cloud sync.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
RUNNER="$ROOT/bin/last-stack-north-star-proof"
EVALUATOR="$ROOT/bin/last-stack-kanban-done-when-eval"
HARNESS="$ROOT/harness/north-star/north-star-lastdb-cloud-sync-resume/run.sh"
FIXTURE="$ROOT/tests/fixtures/north-star-lastdb-cloud-sync-resume"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cloud-sync-resume-proof-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=../harness/north-star/common.sh
. "$ROOT/harness/north-star/common.sh"

# A report names the exact rule that failed, and this file then deleted $WORK
# one instruction after printing a line that did not carry it. Several
# assertions are a bare `grep -q` under `set -e` and printed NOTHING at all.
# papercut-north-star-proof-test-fail-message-drops-the-report-reason-20260926
on_err() {
  local rc="$1" line="$2" report
  echo "$(basename "$0"): failed at line $line (rc=$rc)" >&2
  for report in "$WORK"/*/*.md "$WORK"/*-report/*.md; do
    [ -f "$report" ] || continue
    grep -q '^Source failures:' "$report" || continue
    printf '  %s: %s\n' "${report#"$WORK"/}" "$(ns_fold_report_failures "$report")" >&2
  done
}
trap 'on_err "$?" "$LINENO"' ERR

fail() {
  echo "last-stack-north-star-proof-cloud-sync-resume: $*" >&2
  exit 1
}

expect_verdict() {
  local file="$1" want="$2" got
  [ -f "$file" ] || fail "missing report $file"
  got="$(sed -n '1p' "$file")"
  [ "$got" = "$want" ] || fail "verdict $(printf '%s' "$got") != $want in $file"
}

bash -n "$HARNESS"
bash -n "$0"

"$RUNNER" --list | grep -qx 'north-star-lastdb-cloud-sync-resume' ||
  fail "--list omits north-star-lastdb-cloud-sync-resume"

write_measured() {
  local path="$1" upload="${2:-5000}" growth="${3:-100}" start="${4:-40}" end="${5:-0}"
  local cleared="${6:-2026-09-23T00:00:00Z}" reenable="${7:-2026-09-23T00:05:00Z}"
  cat >"$path" <<EOF
{
  "schema": "lastdb-cloud-sync-resume-proof.v1",
  "surface": {
    "kind": "cow",
    "primary_home_opened": false,
    "primary_mutated": false,
    "primary_reenabled_by_harness": false,
    "live_cutover": false,
    "home_path": "/tmp/cloud-sync-resume-cow"
  },
  "hash_group": {
    "cow_document_count": 11472142,
    "group_file_count": 4,
    "group_bytes_uploaded": 4096,
    "staging_object_count": 1,
    "cow_proof_verdict": "PASS",
    "promoted": false,
    "source_unchanged": true
  },
  "probe": {
    "upload_bytes": $upload,
    "upload_window_secs": 60,
    "staging_growth_bytes": $growth,
    "backlog_start": $start,
    "backlog_end": $end,
    "degraded": false,
    "window_start": "2026-09-23T00:00:00Z",
    "window_end": "2026-09-23T00:01:00Z"
  },
  "reenable": {
    "situation_slug": "cloud-sync-paused-pending-laststore-redesign-20260719",
    "situation_cleared_at": "$cleared",
    "reenable_at": "$reenable",
    "cleared_by": "Tom",
    "reenable_actor": "Tom"
  },
  "catchup": {
    "staging_depth": 2,
    "staging_cap": 100,
    "primary_sync_lag_bytes": 0,
    "brain_reads": 3,
    "brain_writes": 1,
    "kanban_reads": 3,
    "kanban_writes": 1,
    "lastgit_reads": 3,
    "lastgit_writes": 1
  },
  "file_blob": {
    "upload_bytes": 32,
    "fetch_bytes": 32,
    "canary_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "upload_route": "upload_file_blob",
    "fetch_route": "download_file_blob"
  }
}
EOF
}

cat >"$WORK/booleans.json" <<'EOF'
{
  "schema": "lastdb-cloud-sync-resume-proof.v1",
  "surface": {
    "kind": "cow",
    "primary_home_opened": false,
    "primary_mutated": false,
    "primary_reenabled_by_harness": false,
    "live_cutover": false,
    "home_path": "/tmp/cloud-sync-resume-cow"
  },
  "hash_group": {
    "cow_document_count": true,
    "group_file_count": true,
    "group_bytes_uploaded": true,
    "staging_object_count": true,
    "cow_proof_verdict": "PASS",
    "promoted": false,
    "source_unchanged": true
  },
  "probe": {
    "upload_bytes": true,
    "upload_window_secs": true,
    "staging_growth_bytes": true,
    "backlog_start": true,
    "backlog_end": true,
    "degraded": false,
    "window_start": "2026-09-23T00:00:00Z",
    "window_end": "2026-09-23T00:01:00Z"
  },
  "reenable": {
    "situation_slug": "cloud-sync-paused-pending-laststore-redesign-20260719",
    "situation_cleared_at": "2026-09-23T00:00:00Z",
    "reenable_at": "2026-09-23T00:05:00Z",
    "cleared_by": "Tom",
    "reenable_actor": "Tom"
  },
  "catchup": {
    "staging_depth": true,
    "staging_cap": true,
    "primary_sync_lag_bytes": true,
    "brain_reads": true,
    "brain_writes": true,
    "kanban_reads": true,
    "kanban_writes": true,
    "lastgit_reads": true,
    "lastgit_writes": true
  },
  "file_blob": {
    "upload_bytes": true,
    "fetch_bytes": true,
    "canary_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "upload_route": "upload_file_blob",
    "fetch_route": "download_file_blob"
  }
}
EOF

write_measured "$WORK/good.json"
write_measured "$WORK/slow.json" 100 100
write_measured "$WORK/flat.json" 5000 100 10 10
write_measured "$WORK/early.json" 5000 100 40 0 "2026-09-23T00:05:00Z" "2026-09-23T00:00:00Z"
python3 - "$WORK/good.json" "$WORK/primary.json" <<'PY'
import json
import sys
data = json.loads(open(sys.argv[1], encoding="utf-8").read())
data["surface"]["home_path"] = "/tmp/cloud-sync-resume/.lastdb"
json.dump(data, open(sys.argv[2], "w", encoding="utf-8"))
PY

mkdir -p "$WORK/bin" "$WORK/home/.lastdb"
cat >"$WORK/bin/lastdb" <<EOF
#!/bin/sh
echo called >"$WORK/marker"
exit 99
EOF
cat >"$WORK/bin/brain" <<EOF
#!/bin/sh
echo called >"$WORK/marker"
exit 99
EOF
chmod +x "$WORK/bin/lastdb" "$WORK/bin/brain"
cp "$WORK/good.json" "$WORK/home/.lastdb/evidence.json"

PATH="$WORK/bin:$PATH" \
CLOUD_SYNC_RESUME_SOURCE_DIR="$FIXTURE" \
CLOUD_SYNC_RESUME_PROOF_EVIDENCE_FILE= \
NORTH_STAR_PROOF_DIR="$WORK/absent" \
  "$RUNNER" --offline north-star-lastdb-cloud-sync-resume >"$WORK/absent.out" 2>"$WORK/absent.err" || true
[ ! -e "$WORK/marker" ] || fail "the offline proof called lastdb or brain"
expect_verdict "$WORK/absent/north-star-lastdb-cloud-sync-resume.md" FAIL
grep -q 'Source contract: PASS' "$WORK/absent/north-star-lastdb-cloud-sync-resume.md"
grep -q 'Operational evidence: ABSENT' "$WORK/absent/north-star-lastdb-cloud-sync-resume.md"
grep -q 'The harness did not open a LastDB home.' "$WORK/absent/north-star-lastdb-cloud-sync-resume.md"
grep -q 'The harness did not re-enable primary cloud sync.' "$WORK/absent/north-star-lastdb-cloud-sync-resume.md"
if "$EVALUATOR" --kind validation \
  --predicate "file $WORK/absent/north-star-lastdb-cloud-sync-resume.md matches /^PASS/" \
  >"$WORK/absent-eval.out"; then
  fail "a report without operational evidence satisfied /^PASS/"
fi
grep -q '^pending:' "$WORK/absent-eval.out" || fail "missing-evidence report was not pending"

# An unset evidence variable loads the committed measurement. That file
# records a refused upload and does not claim Situation clearance, so the
# proof stays FAIL.
if PATH="$WORK/bin:$PATH" \
  env -u CLOUD_SYNC_RESUME_PROOF_EVIDENCE_FILE \
  CLOUD_SYNC_RESUME_SOURCE_DIR="$FIXTURE" \
  NORTH_STAR_PROOF_DIR="$WORK/committed" \
  "$RUNNER" --offline north-star-lastdb-cloud-sync-resume \
  >"$WORK/committed.out" 2>"$WORK/committed.err"; then
  fail "the committed measurement was accepted as PASS"
fi
expect_verdict "$WORK/committed/north-star-lastdb-cloud-sync-resume.md" FAIL
grep -F -q "Evidence file: $ROOT/harness/north-star/north-star-lastdb-cloud-sync-resume/measured-evidence.json" \
  "$WORK/committed/north-star-lastdb-cloud-sync-resume.md" ||
  fail "the default evidence path is not measured-evidence.json"
grep -q 'Operational evidence: FAIL' \
  "$WORK/committed/north-star-lastdb-cloud-sync-resume.md"
grep -q 'The hash-group CoW proof verdict is not PASS.' \
  "$WORK/committed/north-star-lastdb-cloud-sync-resume.md"
grep -q 'Tom did not clear the Situation.' \
  "$WORK/committed/north-star-lastdb-cloud-sync-resume.md"
grep -q 'The file-blob canary has no SHA-256 sample.' \
  "$WORK/committed/north-star-lastdb-cloud-sync-resume.md"
if grep -q 'Operational evidence: ABSENT' \
  "$WORK/committed/north-star-lastdb-cloud-sync-resume.md"; then
  fail "the committed measurement was treated as absent"
fi
if grep -q 'Operational evidence: PASS' \
  "$WORK/committed/north-star-lastdb-cloud-sync-resume.md"; then
  fail "the committed measurement passed the operational check"
fi

if PATH="$WORK/bin:$PATH" \
  CLOUD_SYNC_RESUME_SOURCE_DIR="$FIXTURE" \
  CLOUD_SYNC_RESUME_PROOF_EVIDENCE_FILE="$WORK/booleans.json" \
  NORTH_STAR_PROOF_DIR="$WORK/booleans" \
  "$RUNNER" --offline north-star-lastdb-cloud-sync-resume >"$WORK/booleans.out" 2>"$WORK/booleans.err"; then
  fail "a JSON file of booleans was accepted as operational evidence"
fi
expect_verdict "$WORK/booleans/north-star-lastdb-cloud-sync-resume.md" FAIL
grep -q 'Source contract: PASS' "$WORK/booleans/north-star-lastdb-cloud-sync-resume.md"
grep -q 'The evidence lacks measured CoW or ephemeral output.' \
  "$WORK/booleans/north-star-lastdb-cloud-sync-resume.md"

PATH="$WORK/bin:$PATH" \
CLOUD_SYNC_RESUME_SOURCE_DIR="$FIXTURE" \
CLOUD_SYNC_RESUME_PROOF_EVIDENCE_FILE="$WORK/good.json" \
NORTH_STAR_PROOF_DIR="$WORK/good" \
  "$RUNNER" --offline north-star-lastdb-cloud-sync-resume >"$WORK/good.out"
[ ! -e "$WORK/marker" ] || fail "the evidence path called lastdb or brain"
expect_verdict "$WORK/good/north-star-lastdb-cloud-sync-resume.md" PASS-OFFLINE
grep -q 'Operational evidence: PASS' "$WORK/good/north-star-lastdb-cloud-sync-resume.md"
grep -q 'upload_bytes 5000 is above staging_growth_bytes 100' \
  "$WORK/good/north-star-lastdb-cloud-sync-resume.md"
grep -q 'cloud-sync-paused-pending-laststore-redesign-20260719' \
  "$WORK/good/north-star-lastdb-cloud-sync-resume.md"
"$EVALUATOR" --kind validation \
  --predicate "file $WORK/good/north-star-lastdb-cloud-sync-resume.md matches /^PASS/" \
  >"$WORK/good-eval.out"
grep -q '^satisfied:' "$WORK/good-eval.out" || fail "PASS-OFFLINE did not satisfy /^PASS/"

if PATH="$WORK/bin:$PATH" \
  CLOUD_SYNC_RESUME_SOURCE_DIR="$FIXTURE" \
  CLOUD_SYNC_RESUME_PROOF_EVIDENCE_FILE="$WORK/slow.json" \
  NORTH_STAR_PROOF_DIR="$WORK/slow" \
  "$RUNNER" --offline north-star-lastdb-cloud-sync-resume >"$WORK/slow.out" 2>"$WORK/slow.err"; then
  fail "upload throughput that does not exceed staging growth was accepted"
fi
expect_verdict "$WORK/slow/north-star-lastdb-cloud-sync-resume.md" FAIL
grep -q 'Upload throughput does not exceed staging growth.' \
  "$WORK/slow/north-star-lastdb-cloud-sync-resume.md"

if PATH="$WORK/bin:$PATH" \
  CLOUD_SYNC_RESUME_SOURCE_DIR="$FIXTURE" \
  CLOUD_SYNC_RESUME_PROOF_EVIDENCE_FILE="$WORK/flat.json" \
  NORTH_STAR_PROOF_DIR="$WORK/flat" \
  "$RUNNER" --offline north-star-lastdb-cloud-sync-resume >"$WORK/flat.out" 2>"$WORK/flat.err"; then
  fail "a flat backlog was accepted"
fi
expect_verdict "$WORK/flat/north-star-lastdb-cloud-sync-resume.md" FAIL
grep -q 'The backlog does not converge.' "$WORK/flat/north-star-lastdb-cloud-sync-resume.md"

if PATH="$WORK/bin:$PATH" \
  CLOUD_SYNC_RESUME_SOURCE_DIR="$FIXTURE" \
  CLOUD_SYNC_RESUME_PROOF_EVIDENCE_FILE="$WORK/early.json" \
  NORTH_STAR_PROOF_DIR="$WORK/early" \
  "$RUNNER" --offline north-star-lastdb-cloud-sync-resume >"$WORK/early.out" 2>"$WORK/early.err"; then
  fail "a re-enable before Situation clearance was accepted"
fi
expect_verdict "$WORK/early/north-star-lastdb-cloud-sync-resume.md" FAIL
grep -q 'The Situation clearance is not before the re-enable.' \
  "$WORK/early/north-star-lastdb-cloud-sync-resume.md"

if PATH="$WORK/bin:$PATH" \
  CLOUD_SYNC_RESUME_SOURCE_DIR="$FIXTURE" \
  CLOUD_SYNC_RESUME_PROOF_EVIDENCE_FILE="$WORK/primary.json" \
  NORTH_STAR_PROOF_DIR="$WORK/primary-json" \
  "$RUNNER" --offline north-star-lastdb-cloud-sync-resume >"$WORK/primary-json.out" 2>"$WORK/primary-json.err"; then
  fail "evidence that names a LastDB home was accepted"
fi
expect_verdict "$WORK/primary-json/north-star-lastdb-cloud-sync-resume.md" FAIL
grep -q 'The evidence names a LastDB home or a secret.' \
  "$WORK/primary-json/north-star-lastdb-cloud-sync-resume.md"

if PATH="$WORK/bin:$PATH" \
  HOME="$WORK/home" \
  CLOUD_SYNC_RESUME_SOURCE_DIR="$FIXTURE" \
  CLOUD_SYNC_RESUME_PROOF_EVIDENCE_FILE="$WORK/home/.lastdb/evidence.json" \
  NORTH_STAR_PROOF_DIR="$WORK/primary-path" \
  "$RUNNER" --offline north-star-lastdb-cloud-sync-resume >"$WORK/primary-path.out" 2>"$WORK/primary-path.err"; then
  fail "an evidence path under a LastDB home was accepted"
fi
expect_verdict "$WORK/primary-path/north-star-lastdb-cloud-sync-resume.md" FAIL
grep -q 'The harness refuses a LastDB home path.' \
  "$WORK/primary-path/north-star-lastdb-cloud-sync-resume.md"
[ ! -e "$WORK/marker" ] || fail "the primary-path refusal called lastdb or brain"

if PATH="$WORK/bin:$PATH" \
  CLOUD_SYNC_RESUME_SOURCE_DIR="$FIXTURE" \
  CLOUD_SYNC_RESUME_PROOF_EVIDENCE_FILE="$WORK/good.json" \
  CLOUD_SYNC_RESUME_ALLOW_REENABLE=1 \
  NORTH_STAR_PROOF_DIR="$WORK/reenable" \
  "$RUNNER" --offline north-star-lastdb-cloud-sync-resume >"$WORK/reenable.out" 2>"$WORK/reenable.err"; then
  fail "an explicit re-enable request was accepted"
fi
expect_verdict "$WORK/reenable/north-star-lastdb-cloud-sync-resume.md" FAIL
grep -q 'Remove CLOUD_SYNC_RESUME_ALLOW_REENABLE.' \
  "$WORK/reenable/north-star-lastdb-cloud-sync-resume.md"

if PATH="$WORK/bin:$PATH" \
  CLOUD_SYNC_RESUME_SOURCE_DIR="$FIXTURE" \
  CLOUD_SYNC_RESUME_PROOF_EVIDENCE_FILE="$WORK/good.json" \
  NORTH_STAR_PROOF_DIR="$WORK/live" \
  "$RUNNER" --live north-star-lastdb-cloud-sync-resume >"$WORK/live.out" 2>"$WORK/live.err"; then
  fail "live mode was accepted"
fi
expect_verdict "$WORK/live/north-star-lastdb-cloud-sync-resume.md" FAIL
grep -q 'This harness runs in offline mode only.' \
  "$WORK/live/north-star-lastdb-cloud-sync-resume.md"

mkdir -p "$WORK/cheat/vendor/laststore/src"
cp -R "$FIXTURE/fold_db" "$WORK/cheat/fold_db"
cat >"$WORK/cheat/vendor/laststore/src/options.rs" <<'EOF'
fn cheat() {
    let _ = "layout_mode: LayoutMode::HashGroup";
}
EOF
if PATH="$WORK/bin:$PATH" \
  CLOUD_SYNC_RESUME_SOURCE_DIR="$WORK/cheat" \
  NORTH_STAR_PROOF_DIR="$WORK/cheat-report" \
  "$RUNNER" --offline north-star-lastdb-cloud-sync-resume >"$WORK/cheat.out" 2>"$WORK/cheat.err"; then
  fail "a string literal satisfied the hash-group source contract"
fi
expect_verdict "$WORK/cheat-report/north-star-lastdb-cloud-sync-resume.md" FAIL
grep -q 'Source contract: FAIL' "$WORK/cheat-report/north-star-lastdb-cloud-sync-resume.md"
grep -q 'The hash-group default is absent.' \
  "$WORK/cheat-report/north-star-lastdb-cloud-sync-resume.md"

# A linked worktree keeps "gitdir: <path>" in a .git file. The checked-out
# source files are removed so the harness must read HEAD with git -C.
mkdir -p "$WORK/git-seed"
git -C "$WORK/git-seed" init -q -b main
cp -R "$FIXTURE/fold_db" "$FIXTURE/vendor" "$WORK/git-seed/"
git -C "$WORK/git-seed" add fold_db vendor
git -C "$WORK/git-seed" -c user.name=Test -c user.email=test@example.invalid \
  commit -q -m 'fixture'
git -C "$WORK/git-seed" worktree add --quiet --detach "$WORK/fold-wt" HEAD
rm -rf "$WORK/fold-wt/fold_db" "$WORK/fold-wt/vendor"
[ -f "$WORK/fold-wt/.git" ] || fail "the Fold worktree .git entry is not a file"
grep -q '^gitdir: ' "$WORK/fold-wt/.git" ||
  fail "the Fold worktree .git file lacks a gitdir prefix"
[ ! -e "$WORK/fold-wt/vendor/laststore/src/options.rs" ] ||
  fail "the Fold worktree still has a checked-out source file"

PATH="$WORK/bin:$PATH" \
env -u CLOUD_SYNC_RESUME_SOURCE_DIR -u CLOUD_SYNC_RESUME_ALLOW_REENABLE \
  CLOUD_SYNC_RESUME_PROOF_EVIDENCE_FILE= \
  FOLD_REPO="$WORK/fold-wt" \
  NORTH_STAR_PROOF_DIR="$WORK/worktree" \
  "$RUNNER" --offline north-star-lastdb-cloud-sync-resume \
  >"$WORK/worktree.out" 2>"$WORK/worktree.err" || true
expect_verdict "$WORK/worktree/north-star-lastdb-cloud-sync-resume.md" FAIL
grep -q 'Source contract: PASS' "$WORK/worktree/north-star-lastdb-cloud-sync-resume.md" ||
  fail "a Fold worktree .git file did not satisfy the resume contract: $(ns_fold_report_failures "$WORK/worktree/north-star-lastdb-cloud-sync-resume.md")"
grep -q 'Operational evidence: ABSENT' "$WORK/worktree/north-star-lastdb-cloud-sync-resume.md"
grep -F -q "Source label: git:$WORK/fold-wt:HEAD" \
  "$WORK/worktree/north-star-lastdb-cloud-sync-resume.md" ||
  fail "the harness did not load the Fold worktree with git show"
[ ! -e "$WORK/marker" ] || fail "the worktree proof called lastdb or brain"

mkdir -p "$WORK/ev"
git -C "$WORK/git-seed" worktree add --quiet --detach "$WORK/ev/fold" HEAD
rm -rf "$WORK/ev/fold/fold_db" "$WORK/ev/fold/vendor"
[ -f "$WORK/ev/fold/.git" ] ||
  fail "the workspace Fold worktree .git entry is not a file"
grep -q '^gitdir: ' "$WORK/ev/fold/.git" ||
  fail "the workspace Fold worktree .git file lacks a gitdir prefix"

PATH="$WORK/bin:$PATH" \
env -u CLOUD_SYNC_RESUME_SOURCE_DIR -u CLOUD_SYNC_RESUME_ALLOW_REENABLE -u FOLD_REPO \
  CLOUD_SYNC_RESUME_PROOF_EVIDENCE_FILE= \
  EDGEVECTOR_WORKSPACE="$WORK/ev" \
  NORTH_STAR_PROOF_DIR="$WORK/ws-worktree" \
  "$RUNNER" --offline north-star-lastdb-cloud-sync-resume \
  >"$WORK/ws-worktree.out" 2>"$WORK/ws-worktree.err" || true
expect_verdict "$WORK/ws-worktree/north-star-lastdb-cloud-sync-resume.md" FAIL
grep -q 'Source contract: PASS' \
  "$WORK/ws-worktree/north-star-lastdb-cloud-sync-resume.md" ||
  fail "the workspace Fold worktree .git file did not satisfy the resume contract: $(ns_fold_report_failures "$WORK/ws-worktree/north-star-lastdb-cloud-sync-resume.md")"
grep -F -q "Source label: git:$WORK/ev/fold:HEAD" \
  "$WORK/ws-worktree/north-star-lastdb-cloud-sync-resume.md" ||
  fail "the harness did not load the workspace Fold worktree with git show"
[ ! -e "$WORK/marker" ] || fail "the workspace worktree proof called lastdb or brain"

# --- Fold source lanes -------------------------------------------------------
# This is a last-stack gate, so its exit code must be a function of a last-stack
# commit. Grading the Fold portal's CURRENT head broke that: fold merged a
# correct refactor at 2026-09-26T11:24Z and every last-stack PR went red on it,
# and the mirror's HEAD is a branch a registered worktree freezes, so the gate
# graded 26f0f601f while fold's real main was 590ac314e.
# papercut-last-stack-ci-shard-grades-the-live-fold-portal-head-20260926
#
# Reporting lane: the live head. A DRIFT notice, never an exit code.
# Blocking lane: the PINNED oid in harness/north-star/fold-source.pin.
# Every assertion that is about OUR harness rather than about fold's content
# stays blocking in both lanes.
PORTAL="${EDGEVECTOR_WORKSPACE:-$HOME/code/edgevector}/fold/.portal/cache"
if [ -f "$PORTAL" ]; then
  MIRROR="$(tr -d '[:space:]' <"$PORTAL")"
  portal_run() {
    # portal_run <report-dir> [<fold oid>]: grade the portal source.
    local dir="$1" oid="${2:-}"
    PATH="$WORK/bin:$PATH" \
    env -u CLOUD_SYNC_RESUME_SOURCE_DIR -u CLOUD_SYNC_RESUME_ALLOW_REENABLE \
      -u FOLD_REPO \
      CLOUD_SYNC_RESUME_PROOF_EVIDENCE_FILE= \
      NORTH_STAR_FOLD_SOURCE_OID="$oid" \
      NORTH_STAR_PROOF_DIR="$dir" \
      "$RUNNER" --offline north-star-lastdb-cloud-sync-resume \
      >"$dir.out" 2>"$dir.err" || true
  }

  # Reporting lane: the live mirror head.
  portal_run "$WORK/portal-live"
  live_report="$WORK/portal-live/north-star-lastdb-cloud-sync-resume.md"
  ns_fold_drift_report "live fold portal head" \
    "$(ns_fold_rev_label "$MIRROR" HEAD)" "$live_report"
  if ns_fold_source_absent "$live_report"; then
    echo "fold-source-drift: the live fold head is not readable in $MIRROR; skipping the live-lane harness assertions" >&2
  else
    # These hold whatever fold contains: they are properties of THIS harness.
    expect_verdict "$live_report" FAIL
    grep -q 'Operational evidence: ABSENT' "$live_report" ||
      fail "the live portal report lacks Operational evidence: ABSENT: $(ns_fold_report_failures "$live_report")"
    [ ! -e "$WORK/marker" ] || fail "the portal proof called lastdb or brain"
  fi

  # Blocking lane: the pinned oid.
  if PIN="$(ns_fold_source_pin)"; then
    if ns_fold_rev_present "$MIRROR" "$PIN"; then
      portal_run "$WORK/portal-pin" "$PIN"
      pin_report="$WORK/portal-pin/north-star-lastdb-cloud-sync-resume.md"
      expect_verdict "$pin_report" FAIL
      grep -q 'Source contract: PASS' "$pin_report" ||
        fail "pinned fold $PIN lacks Source contract: PASS — fix fold or move harness/north-star/fold-source.pin deliberately: $(ns_fold_report_failures "$pin_report")"
      grep -q 'Operational evidence: ABSENT' "$pin_report" ||
        fail "the pinned portal report lacks Operational evidence: ABSENT: $(ns_fold_report_failures "$pin_report")"
      grep -F -q "Source label: fold-portal:$PIN" "$pin_report" ||
        fail "the report does not name the fold commit it graded: $(grep -F 'Source label:' "$pin_report")"
      [ ! -e "$WORK/marker" ] || fail "the pinned portal proof called lastdb or brain"
    else
      # A pin this mirror cannot resolve is an environment fact, not a
      # last-stack defect. Refusing here would put another repo's fetch
      # state back in this gate's exit code, which is the whole defect.
      # The fixture lanes above still gate the contract; say so loudly.
      echo "fold-source-pin: skip — $PIN is not in $MIRROR; the fixture lanes still gate this contract" >&2
    fi
  else
    fail "harness/north-star/fold-source.pin holds no fold oid"
  fi
fi

echo "PASS last-stack-north-star-proof-cloud-sync-resume"
