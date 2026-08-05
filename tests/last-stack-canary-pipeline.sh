#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
CLI="$ROOT/bin/last-stack-canary-pipeline"
chmod +x "$CLI"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-canary-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

state_dir="$tmp/state"

out="$("$CLI" --state-dir "$state_dir" --json create cand-a --version 0.23.2 --source nightly)"
[ "$(printf '%s\n' "$out" | jq -r '.state')" = "candidate_found" ]
[ "$(printf '%s\n' "$out" | jq -r '.version')" = "0.23.2" ]

if "$CLI" --state-dir "$state_dir" create cand-a >"$tmp/canary-dup.out" 2>"$tmp/canary-dup.err"; then
  echo "expected duplicate create to fail" >&2
  exit 1
fi
grep -q 'candidate already exists' "$tmp/canary-dup.err"

"$CLI" --state-dir "$state_dir" advance cand-a dogfood_started --note dogfood >/dev/null
"$CLI" --state-dir "$state_dir" advance cand-a dogfood_green >/dev/null
"$CLI" --state-dir "$state_dir" advance cand-a soak_started >/dev/null
"$CLI" --state-dir "$state_dir" advance cand-a soak_green >/dev/null
out="$("$CLI" --state-dir "$state_dir" --json advance cand-a promote_prepare)"
[ "$(printf '%s\n' "$out" | jq -r '.state')" = "promote_prepare" ]

out="$("$CLI" --state-dir "$state_dir" --json read cand-a)"
[ "$(printf '%s\n' "$out" | jq -r '.state')" = "promote_prepare" ]
[ "$(wc -l <"$state_dir/ledger.jsonl" | tr -d ' ')" = "6" ]

if "$CLI" --state-dir "$state_dir" advance cand-a promote_prepare >"$tmp/canary-repeat.out" 2>"$tmp/canary-repeat.err"; then
  echo "expected duplicate transition to fail" >&2
  exit 1
fi
grep -q 'duplicate transition' "$tmp/canary-repeat.err"

if "$CLI" --state-dir "$state_dir" advance cand-a dogfood_started >"$tmp/canary-regress.out" 2>"$tmp/canary-regress.err"; then
  echo "expected regressing transition to fail" >&2
  exit 1
fi
grep -q 'invalid transition' "$tmp/canary-regress.err"

"$CLI" --state-dir "$state_dir" create cand-b >/dev/null
if "$CLI" --state-dir "$state_dir" advance cand-b soak_started >"$tmp/canary-skip.out" 2>"$tmp/canary-skip.err"; then
  echo "expected skipped transition to fail" >&2
  exit 1
fi
grep -q 'invalid transition' "$tmp/canary-skip.err"

"$CLI" --state-dir "$state_dir" advance cand-b dogfood_started >/dev/null
"$CLI" --state-dir "$state_dir" advance cand-b dogfood_red >/dev/null
if "$CLI" --state-dir "$state_dir" advance cand-b soak_started >"$tmp/canary-red.out" 2>"$tmp/canary-red.err"; then
  echo "expected red terminal transition to fail" >&2
  exit 1
fi
grep -q 'allowed: none' "$tmp/canary-red.err"

if "$CLI" --state-dir "$state_dir" read missing >"$tmp/canary-missing.out" 2>"$tmp/canary-missing.err"; then
  echo "expected missing read to fail" >&2
  exit 1
fi
grep -q 'candidate not found' "$tmp/canary-missing.err"

out="$("$CLI" --state-dir "$state_dir" --json list)"
[ "$(printf '%s\n' "$out" | jq -r 'length')" = "2" ]
[ "$(printf '%s\n' "$out" | jq -r '.[] | select(.candidate=="cand-b") | .state')" = "dogfood_red" ]

proof_out="$tmp/proof.out"
"$CLI" proof --dry-run >"$proof_out"
grep -q 'DOGFOOD .*result=ok.*no_primary_mutation=1' "$proof_out"
grep -q 'SOAK .*status=soak_green.*no_primary_mutation=1' "$proof_out"
grep -q 'PROMOTE_READY .*status=ready.*no_primary_mutation=1' "$proof_out"
grep -q 'CANARY_PIPELINE_PROOF result=ok dry_run=1' "$proof_out"
grep -q 'stable_mutation=false' "$proof_out"
promote_path="$(awk -F 'promote_output=' '/CANARY_PIPELINE_PROOF/ {print $2}' "$proof_out" | awk '{print $1}')"
test -r "$promote_path"
grep -q 'Candidate SHA: `dryrun-canary-sha`' "$promote_path"
grep -q 'Automation pushed stable tag: `false`' "$promote_path"
if grep -q "$HOME/.lastdb" "$proof_out"; then
  echo "dry-run proof unexpectedly referenced the primary LastDB home" >&2
  exit 1
fi

mismatch_dir="$tmp/mismatch"
"$CLI" --state-dir "$mismatch_dir" dogfood --dry-run --sha sha-a --observed-sha sha-b >/dev/null
if LAST_STACK_CANARY_LAUNCHD_CHECK_CMD=pass \
  LAST_STACK_CANARY_MEMORY_CHECK_CMD=pass \
  LAST_STACK_CANARY_BOARD_CHECK_CMD=pass \
  LAST_STACK_CANARY_SITUATION_CHECK_CMD=pass \
  LAST_STACK_CANARY_SOAK_HOURS=0 \
  LAST_STACK_CANARY_LIVE_VERSION_CMD=pass \
  "$CLI" --state-dir "$mismatch_dir" soak-watch --dry-run --sha sha-a >"$tmp/mismatch.out"; then
  echo "expected SHA mismatch to mark soak_red" >&2
  exit 1
fi
grep -q 'status=soak_red' "$tmp/mismatch.out"
grep -q 'sha_mismatch' "$mismatch_dir/ledger.jsonl"

green_dir="$tmp/green"
LAST_STACK_CANARY_LAUNCHD_CHECK_CMD=pass \
LAST_STACK_CANARY_MEMORY_CHECK_CMD=pass \
LAST_STACK_CANARY_BOARD_CHECK_CMD=pass \
LAST_STACK_CANARY_SITUATION_CHECK_CMD=pass \
LAST_STACK_CANARY_SOAK_HOURS=0 \
LAST_STACK_CANARY_LIVE_VERSION_CMD=pass \
  "$CLI" --state-dir "$green_dir" dogfood --dry-run --sha sha-green >/dev/null
LAST_STACK_CANARY_LAUNCHD_CHECK_CMD=pass \
LAST_STACK_CANARY_MEMORY_CHECK_CMD=pass \
LAST_STACK_CANARY_BOARD_CHECK_CMD=pass \
LAST_STACK_CANARY_SITUATION_CHECK_CMD=pass \
LAST_STACK_CANARY_SOAK_HOURS=0 \
LAST_STACK_CANARY_LIVE_VERSION_CMD=pass \
  "$CLI" --state-dir "$green_dir" soak-watch --dry-run --sha sha-green >/dev/null
"$CLI" --state-dir "$green_dir" promote-prepare --dry-run --sha sha-green \
  --promote-root "$tmp/promote-root" >"$tmp/promote.out"
grep -q 'PROMOTE_READY .*sha=sha-green.*status=ready.*output=' "$tmp/promote.out"
manual="$(awk -F 'output=' '/PROMOTE_READY/ {print $2}' "$tmp/promote.out" | awk '{print $1}')"
test -r "$manual"
grep -q 'Candidate SHA: `sha-green`' "$manual"

grep -q 'lastdb-canary-soak-watch' "$ROOT/config/routines-registry/lastdb-canary-soak-watch.toml"
grep -q 'status = "active"' "$ROOT/config/routines-registry/lastdb-canary-soak-watch.toml"
grep -q 'last-stack-canary-pipeline proof --dry-run' "$ROOT/routines/lastdb-canary-soak-watch.md"
grep -q 'lastdb-canary-promote-prepare' "$ROOT/config/routines-registry/lastdb-canary-promote-prepare.toml"
grep -q 'status = "active"' "$ROOT/config/routines-registry/lastdb-canary-promote-prepare.toml"

# promote-execute dry-run after soak_green
LAST_STACK_CANARY_PROMOTE_AUTO=1 \
  "$CLI" --state-dir "$green_dir" promote-execute --dry-run --sha sha-green \
  --promote-root "$tmp/promote-exec-root" >"$tmp/promote-exec.out"
grep -q 'PROMOTE_EXECUTE .*status=ready_dry_run' "$tmp/promote-exec.out"
grep -q 'stable_mutation=false' "$tmp/promote-exec.out"

# --- commit-ancestry guard -------------------------------------------------
# Regression for 2026-08-05: `0.23.3-canary.20260801` (built Aug 1) replaced
# `0.23.2-409-gee967a073` (built Aug 4) because semver ordered them. It was a
# rollback of 196 commits. Hermetic: build a throwaway history, don't depend on
# the fold mirror being present.
mirror="$tmp/mirror.git"
git init -q --bare "$mirror"
seed="$tmp/seed"
git init -q "$seed"
git -C "$seed" config user.email test@example.com
git -C "$seed" config user.name test
echo old >"$seed/f"; git -C "$seed" add f; git -C "$seed" commit -qm old
OLD_OID="$(git -C "$seed" rev-parse HEAD)"
echo new >"$seed/f"; git -C "$seed" commit -qam new
NEW_OID="$(git -C "$seed" rev-parse HEAD)"
git -C "$seed" push -q "$mirror" HEAD:refs/heads/main

guard_dogfood() { # <running_oid> <candidate_oid> <ledger-suffix>
  LAST_STACK_CANARY_FOLD_MIRROR="$mirror" \
  LAST_STACK_CANARY_RUNNING_OID="$1" \
  LAST_STACK_CANARY_SOURCE_OID="$2" \
    "$CLI" --ledger "$tmp/anc-$3.jsonl" dogfood --sha "anc-$3" --version 0.0.1-canary.test
}

# A rollback candidate is refused, and nothing is written to the ledger — the
# primary is never cut over.
if guard_dogfood "$NEW_OID" "$OLD_OID" rollback >"$tmp/anc-rb.out" 2>"$tmp/anc-rb.err"; then
  echo "expected ancestry guard to refuse a rollback candidate" >&2
  exit 1
fi
grep -q 'ANCESTRY stage=dogfood result=REFUSE' "$tmp/anc-rb.err"
grep -q 'commits=1' "$tmp/anc-rb.err"
test ! -e "$tmp/anc-rollback.jsonl"

# A genuine descendant is allowed, and its source OID lands in the ledger.
guard_dogfood "$OLD_OID" "$NEW_OID" fwd >"$tmp/anc-fwd.out" 2>"$tmp/anc-fwd.err"
grep -q 'ANCESTRY stage=dogfood result=ok .*relation=descendant' "$tmp/anc-fwd.out"
[ "$(jq -r 'select(.state=="candidate_found") | .source_git_oid' "$tmp/anc-fwd.jsonl")" = "$NEW_OID" ]

# Rebuilding the identical commit is not a rollback.
guard_dogfood "$NEW_OID" "$NEW_OID" same >"$tmp/anc-same.out" 2>&1
grep -q 'relation=identical' "$tmp/anc-same.out"

# The escape hatch still works, and says so.
LAST_STACK_CANARY_ANCESTRY_GUARD=0 guard_dogfood "$NEW_OID" "$OLD_OID" off \
  >"$tmp/anc-off.out" 2>"$tmp/anc-off.err"
grep -q 'result=skipped reason=guard_disabled' "$tmp/anc-off.err"

# Unknown ancestry: dogfood proceeds (a local cutover is reversible) ...
LAST_STACK_CANARY_FOLD_MIRROR="$mirror" \
LAST_STACK_CANARY_RUNNING_OID=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef \
LAST_STACK_CANARY_SOURCE_OID="$NEW_OID" \
  "$CLI" --ledger "$tmp/anc-unk.jsonl" dogfood --sha anc-unk --version 0.0.1-canary.test \
  >"$tmp/anc-unk.out" 2>"$tmp/anc-unk.err"
grep -q 'result=unknown reason=commit_not_in_mirror' "$tmp/anc-unk.err"

# ... but promote fails closed, because that one is a public release.
"$CLI" --ledger "$tmp/anc-unk.jsonl" advance anc-unk soak_started >/dev/null
"$CLI" --ledger "$tmp/anc-unk.jsonl" advance anc-unk soak_green >/dev/null
if LAST_STACK_CANARY_PROMOTE_AUTO=1 \
   LAST_STACK_CANARY_LIVE_VERSION_CMD=pass \
   LAST_STACK_CANARY_RELEASES_URL="http://127.0.0.1:1/none" \
   LAST_STACK_CANARY_SOURCE_OID="$NEW_OID" \
     "$CLI" --ledger "$tmp/anc-unk.jsonl" promote-execute \
     --promote-root "$tmp/anc-promote-root" >"$tmp/anc-prom.out" 2>"$tmp/anc-prom.err"; then
  echo "expected promote to fail closed on unknown ancestry" >&2
  exit 1
fi
grep -q 'ANCESTRY stage=promote result=unknown' "$tmp/anc-prom.err"
grep -q 'refusing to publish without proven ancestry' "$tmp/anc-prom.err"

echo "PASS last-stack-canary-pipeline"

