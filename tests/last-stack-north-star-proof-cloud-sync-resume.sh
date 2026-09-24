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
env -u CLOUD_SYNC_RESUME_SOURCE_DIR -u CLOUD_SYNC_RESUME_PROOF_EVIDENCE_FILE \
  -u CLOUD_SYNC_RESUME_ALLOW_REENABLE \
  FOLD_REPO="$WORK/fold-wt" \
  NORTH_STAR_PROOF_DIR="$WORK/worktree" \
  "$RUNNER" --offline north-star-lastdb-cloud-sync-resume \
  >"$WORK/worktree.out" 2>"$WORK/worktree.err" || true
expect_verdict "$WORK/worktree/north-star-lastdb-cloud-sync-resume.md" FAIL
grep -q 'Source contract: PASS' "$WORK/worktree/north-star-lastdb-cloud-sync-resume.md" ||
  fail "a Fold worktree .git file did not satisfy the resume contract"
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
env -u CLOUD_SYNC_RESUME_SOURCE_DIR -u CLOUD_SYNC_RESUME_PROOF_EVIDENCE_FILE \
  -u CLOUD_SYNC_RESUME_ALLOW_REENABLE -u FOLD_REPO \
  EDGEVECTOR_WORKSPACE="$WORK/ev" \
  NORTH_STAR_PROOF_DIR="$WORK/ws-worktree" \
  "$RUNNER" --offline north-star-lastdb-cloud-sync-resume \
  >"$WORK/ws-worktree.out" 2>"$WORK/ws-worktree.err" || true
expect_verdict "$WORK/ws-worktree/north-star-lastdb-cloud-sync-resume.md" FAIL
grep -q 'Source contract: PASS' \
  "$WORK/ws-worktree/north-star-lastdb-cloud-sync-resume.md" ||
  fail "the workspace Fold worktree .git file did not satisfy the resume contract"
grep -F -q "Source label: git:$WORK/ev/fold:HEAD" \
  "$WORK/ws-worktree/north-star-lastdb-cloud-sync-resume.md" ||
  fail "the harness did not load the workspace Fold worktree with git show"
[ ! -e "$WORK/marker" ] || fail "the workspace worktree proof called lastdb or brain"

PORTAL="${EDGEVECTOR_WORKSPACE:-$HOME/code/edgevector}/fold/.portal/cache"
if [ -f "$PORTAL" ]; then
  PATH="$WORK/bin:$PATH" \
  env -u CLOUD_SYNC_RESUME_SOURCE_DIR -u CLOUD_SYNC_RESUME_PROOF_EVIDENCE_FILE \
    -u CLOUD_SYNC_RESUME_ALLOW_REENABLE -u FOLD_REPO \
    NORTH_STAR_PROOF_DIR="$WORK/portal" \
    "$RUNNER" --offline north-star-lastdb-cloud-sync-resume >"$WORK/portal.out" 2>"$WORK/portal.err" || true
  expect_verdict "$WORK/portal/north-star-lastdb-cloud-sync-resume.md" FAIL
  grep -q 'Source contract: PASS' "$WORK/portal/north-star-lastdb-cloud-sync-resume.md" ||
    fail "the Fold portal source did not satisfy the resume contract"
  grep -q 'Operational evidence: ABSENT' "$WORK/portal/north-star-lastdb-cloud-sync-resume.md"
  [ ! -e "$WORK/marker" ] || fail "the portal proof called lastdb or brain"
fi

echo "PASS last-stack-north-star-proof-cloud-sync-resume"
