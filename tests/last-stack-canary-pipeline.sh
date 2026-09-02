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
for label in BOOT_LEDGER OBSERVATIONS VERDICT RECONCILER HEAL_QUEUE CHANNELS LOOM DRY_RUN TEST_SUITE; do
  test "$(grep -c "^${label} " "$proof_out" || true)" = "1"
  grep -q "^${label} result=ok" "$proof_out"
done
grep -q 'DRY_RUN result=ok no_primary_mutation=1 stable_mutation=false' "$proof_out"
grep -q 'VERDICT result=ok sep-0830=window-open sep-0831=red:restart\[guard-memory\] sep-0901=red:status_latency' "$proof_out"
if grep -Eq 'DOGFOOD |CANARY_PIPELINE_PROOF ' "$proof_out"; then
  echo "dry-run proof still prints the old synthetic labels" >&2
  exit 1
fi
if grep -q "$HOME/.lastdb" "$proof_out"; then
  echo "dry-run proof unexpectedly referenced the primary LastDB home" >&2
  exit 1
fi

live_env=(
  LAST_STACK_CANARY_PROOF_SOURCE_OID=211325fc22587c7ea0414c749ed9fd7e291677d8
  LAST_STACK_CANARY_PROOF_INSTALLED_OID=211325fc22587c7ea0414c749ed9fd7e291677d8
  LAST_STACK_CANARY_PROOF_LIVE_BUILD=0.23.3-1435-g211325fc2
  LAST_STACK_CANARY_PROOF_STABLE_BUILD=0.23.3-1427-g38d039aee
  LAST_STACK_CANARY_PROOF_OBSERVE_CMD=true
  LAST_STACK_CANARY_LIVE_VERSION_CMD="echo 0.23.3-1435-g211325fc2"
)
env "${live_env[@]}" "$CLI" proof --live --dry-run >"$tmp/proof-live.out"
for label in BOOT_LEDGER OBSERVATIONS VERDICT RECONCILER HEAL_QUEUE CHANNELS LOOM DRY_RUN TEST_SUITE; do
  test "$(grep -c "^${label} " "$tmp/proof-live.out" || true)" = "1"
  grep -q "^${label} result=ok" "$tmp/proof-live.out"
done
grep -q 'BOOT_LEDGER result=ok source_oid=211325fc22587c7ea0414c749ed9fd7e291677d8 installed_oid=211325fc22587c7ea0414c749ed9fd7e291677d8' "$tmp/proof-live.out"

if LAST_STACK_CANARY_PROOF_BOOT_FAIL=1 \
  LAST_STACK_CANARY_PROOF_OBSERVE_CMD=true \
  LAST_STACK_CANARY_PROOF_LIVE_BUILD=0.23.3-1435-g211325fc2 \
  LAST_STACK_CANARY_PROOF_STABLE_BUILD=0.23.3-1427-g38d039aee \
  "$CLI" proof --live --dry-run >"$tmp/proof-missing-boot.out"; then
  echo "expected a missing BOOT_LEDGER source to fail closed" >&2
  exit 1
fi
grep -q '^BOOT_LEDGER result=fail' "$tmp/proof-missing-boot.out"
if grep -q '^BOOT_LEDGER result=ok' "$tmp/proof-missing-boot.out"; then
  echo "missing BOOT_LEDGER still printed result=ok" >&2
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
grep -q 'last-stack-canary-soak-watch-gate' "$ROOT/config/routines-registry/lastdb-canary-soak-watch.toml"
grep -q 'stateless verdict' "$ROOT/config/routines-registry/lastdb-canary-soak-watch.toml"
soak_prompt="$ROOT/routines/lastdb-canary-soak-watch.md"
grep -q 'last-stack-canary-soak-watch-gate' "$soak_prompt"
grep -q 'owner-only bounded boot ledger' "$soak_prompt"
grep -q 'deterministic verdict function' "$soak_prompt"
grep -q 'wait-next-check' "$soak_prompt"
grep -q 'LAST_STACK_CANARY_V2_HEAL_CMD' "$soak_prompt"
if grep -Eq 'SOAK_WAIT|last-stack-canary-loom|last-stack-canary-red-loom' "$soak_prompt"; then
  echo "canary soak prompt contains legacy Loom state" >&2
  exit 1
fi
if grep -Eq 'ROUTINE_RESULT[[:space:]]+outcome=' "$soak_prompt"; then
  echo "canary soak prompt contains a result-shaped trailer literal" >&2
  exit 1
fi
grep -q 'lastdb-canary-promote-prepare' "$ROOT/config/routines-registry/lastdb-canary-promote-prepare.toml"
grep -q 'status = "paused"' "$ROOT/config/routines-registry/lastdb-canary-promote-prepare.toml"
promote_prompt="$ROOT/routines/lastdb-canary-promote-prepare.md"
grep -q 'This routine is paused' "$promote_prompt"
grep -q 'promote-eligible' "$promote_prompt"

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

# --- baseline OID from a canary-BUILD primary ------------------------------
# Regression for 2026-08-05 (second order): the guard above shipped, but every
# test injected LAST_STACK_CANARY_RUNNING_OID, so the *resolver* was never
# exercised — only the comparator. running_source_oid() read the `-g<sha>`
# describe suffix and nothing else, so on a canary/tag build it returned "",
# stage=dogfood took the `unknown` branch, and the guard PROCEEDED.
#
# That is a fail-open exactly after the guard has already failed once: a bad
# cutover leaves the primary on a canary build, which is the one state where
# the guard can no longer see the running commit. Measured on the live primary:
# `0.23.3-canary.20260801` -> "" here, while its manifest gave 6c742dc6.
#
# Hermetic: serve the release manifest over file:// instead of api.github.com.
stub_manifest() { # <tag> <oid>
  local dir="$tmp/api/repos/EdgeVector/homebrew-lastdb/releases/tags"
  mkdir -p "$dir"
  printf '{"source_git_oid":"%s"}\n' "$2" >"$tmp/api/$1-manifest.json"
  printf '{"assets":[{"name":"lastdb-manifest.json","browser_download_url":"file://%s/api/%s-manifest.json"}]}\n' \
    "$tmp" "$1" >"$dir/$1"
}

# The live binary is a canary build whose commit is the NEWER one.
stub_manifest "v0.0.1-canary.live" "$NEW_OID"

guard_from_canary_live() { # <candidate_oid> <ledger-suffix>
  LAST_STACK_CANARY_FOLD_MIRROR="$mirror" \
  LAST_STACK_CANARY_ASSET_API_BASE="file://$tmp/api" \
  LAST_STACK_CANARY_LIVE_VERSION_CMD="echo 0.0.1-canary.live" \
  LAST_STACK_CANARY_SOURCE_OID="$1" \
    "$CLI" --ledger "$tmp/canb-$2.jsonl" dogfood --sha "canb-$2" --version 0.0.1-canary.test
}

# A rollback offered to a canary-running primary is REFUSED, not waved through
# as `unknown`. This is the assertion that fails without the manifest fallback.
if guard_from_canary_live "$OLD_OID" rollback >"$tmp/canb-rb.out" 2>"$tmp/canb-rb.err"; then
  echo "expected refusal: canary-build primary must still resolve a baseline" >&2
  exit 1
fi
grep -q 'ANCESTRY stage=dogfood result=REFUSE' "$tmp/canb-rb.err"
grep -q "baseline\[running\]=$NEW_OID" "$tmp/canb-rb.err"
test ! -e "$tmp/canb-rollback.jsonl"

# ... and a true descendant is still allowed, so the fallback does not simply
# block everything once it starts resolving.
git -C "$seed" commit -q --allow-empty -m newer
NEWER_OID="$(git -C "$seed" rev-parse HEAD)"
git -C "$seed" push -q "$mirror" HEAD:refs/heads/main
guard_from_canary_live "$NEWER_OID" fwd >"$tmp/canb-fwd.out" 2>"$tmp/canb-fwd.err"
grep -q 'ANCESTRY stage=dogfood result=ok .*relation=descendant' "$tmp/canb-fwd.out"

# The candidate override must NOT leak into the running-binary lookup: if it
# did, both sides would collapse onto one OID and every rollback would read as
# `relation=identical` and pass.
grep -q "baseline\[running\]=$NEW_OID" "$tmp/canb-fwd.out"

# --- write-path soak gate --------------------------------------------------
# Regression for 2026-08-05: the 24h soak's four hard checks were `launchctl
# print`, `lastdb status`, `kanban ping` and `situations list` — three liveness
# checks and one human fence. None of them wrote. A candidate whose mutations
# ran ~4x slower passed all four and would have auto-published as public brew
# stable. See brain papercut-canary-soak-gate-has-no-write-path-check.

PROBE="$ROOT/bin/last-stack-canary-write-probe"
test -x "$PROBE" || chmod +x "$PROBE"
bash -n "$PROBE"
# The probe must be an idempotent upsert of ONE fixed slug — a probe that
# accumulated records would grow the store by one row an hour, forever.
grep -q 'canary-soak-write-probe' "$PROBE"
# `brain put` exits 2 unless frontmatter both opens AND closes with `---`.
[ "$(grep -c '^---$' "$PROBE")" = "2" ]

# board_write must be one of the soak checks, not an optional extra.
grep -q '"board_write"' "$CLI"

soak_once() { # <dir> <extra-env-assignments...>  -> runs a real (non-dry-run) soak-watch
  local dir="$1"; shift
  LAST_STACK_CANARY_LIVE_VERSION_CMD=pass \
    "$CLI" --state-dir "$dir" dogfood --sha "$(basename "$dir")" --version 0.0.1-canary.test \
    >/dev/null 2>&1
  env "$@" \
    LAST_STACK_CANARY_PRIMARY_IDENTITY_CMD="printf 'pid=4242 process_start_ts=1234 build=0.0.1-canary.test\\n'" \
    LAST_STACK_CANARY_LAUNCHD_CHECK_CMD=pass \
    LAST_STACK_CANARY_MEMORY_CHECK_CMD="${MEM_CMD:-pass}" \
    LAST_STACK_CANARY_BOARD_CHECK_CMD=pass \
    LAST_STACK_CANARY_SITUATION_CHECK_CMD=pass \
    LAST_STACK_CANARY_SOAK_HOURS=0 \
    LAST_STACK_CANARY_LIVE_VERSION_CMD=pass \
    "$CLI" --state-dir "$dir" soak-watch --sha "$(basename "$dir")"
}

# A write that SUCCEEDS BUT IS SLOW reds the soak. This is the whole point:
# exit code alone was never the missing signal.
slow_dir="$tmp/w-slow"
if soak_once "$slow_dir" \
     LAST_STACK_CANARY_BOARD_WRITE_CHECK_CMD="sleep 0.3" \
     LAST_STACK_CANARY_WRITE_MS_MAX=100 \
     LAST_STACK_CANARY_CHECK_SAMPLES=3 \
     >"$tmp/w-slow.out" 2>"$tmp/w-slow.err"; then
  echo "expected a slow write to red the soak" >&2
  exit 1
fi
grep -q 'status=soak_red' "$tmp/w-slow.out"
grep -q 'CHECK label=board_write result=slow' "$tmp/w-slow.err"
# The ledger must say WHY — a bare `board_write` would not distinguish a write
# that errored from one that merely crawled.
grep -q 'board_write\[slow_median_ms=' "$slow_dir/ledger.jsonl"

# A fast write greens it, and reports the measurement either way.
# NB: `true`/`pass`/`ok` are STUB keywords that short-circuit before timing —
# a real command is required to exercise the budget path.
fast_dir="$tmp/w-fast"
soak_once "$fast_dir" \
  LAST_STACK_CANARY_BOARD_WRITE_CHECK_CMD="exit 0" \
  LAST_STACK_CANARY_WRITE_MS_MAX=60000 \
  LAST_STACK_CANARY_CHECK_SAMPLES=3 \
  >"$tmp/w-fast.out" 2>"$tmp/w-fast.err"
grep -q 'status=soak_green' "$tmp/w-fast.out"
grep -q 'CHECK label=board_write result=ok median_ms=' "$tmp/w-fast.out"

# A primary restart invalidates the uninterrupted soak even when the exact
# approved build remains live and every health check passes.
restart_dir="$tmp/w-restart"
LAST_STACK_CANARY_LIVE_VERSION_CMD=pass \
  "$CLI" --state-dir "$restart_dir" dogfood --sha w-restart --version 0.0.1-canary.test \
  >/dev/null 2>&1
LAST_STACK_CANARY_PRIMARY_IDENTITY_CMD="printf 'pid=4242 process_start_ts=1234 build=0.0.1-canary.test\\n'" \
LAST_STACK_CANARY_LAUNCHD_CHECK_CMD=pass \
LAST_STACK_CANARY_MEMORY_CHECK_CMD=pass \
LAST_STACK_CANARY_BOARD_CHECK_CMD=pass \
LAST_STACK_CANARY_BOARD_WRITE_CHECK_CMD=pass \
LAST_STACK_CANARY_SITUATION_CHECK_CMD=pass \
LAST_STACK_CANARY_SOAK_HOURS=24 \
LAST_STACK_CANARY_LIVE_VERSION_CMD=pass \
  "$CLI" --state-dir "$restart_dir" soak-watch --sha w-restart >/dev/null
if LAST_STACK_CANARY_PRIMARY_IDENTITY_CMD="printf 'pid=4243 process_start_ts=2345 build=0.0.1-canary.test\\n'" \
   LAST_STACK_CANARY_LAUNCHD_CHECK_CMD=pass \
   LAST_STACK_CANARY_MEMORY_CHECK_CMD=pass \
   LAST_STACK_CANARY_BOARD_CHECK_CMD=pass \
   LAST_STACK_CANARY_BOARD_WRITE_CHECK_CMD=pass \
   LAST_STACK_CANARY_SITUATION_CHECK_CMD=pass \
   LAST_STACK_CANARY_SOAK_HOURS=24 \
   LAST_STACK_CANARY_LIVE_VERSION_CMD=pass \
     "$CLI" --state-dir "$restart_dir" soak-watch --sha w-restart \
     >"$tmp/w-restart.out" 2>"$tmp/w-restart.err"; then
  echo "expected a primary PID change to red the soak" >&2
  exit 1
fi
grep -q 'status=soak_red' "$tmp/w-restart.out"
grep -q 'primary_restarted\[pid=4242->4243_start=1234->2345\]' "$restart_dir/ledger.jsonl"

# One slow sample is load; a slow MEDIAN is the binary. A single outlier among
# three must not brake a good candidate.
#
# The two fast samples are real `bash` spawns, so the budget has to clear a
# loaded host, not an idle one. At a 200ms budget with a 0.4s outlier this
# assertion failed about 1 run in 5 standalone, and every run under the four
# parallel CI shards: a fast spawn crossed 200ms, so the MEDIAN was a fast
# sample that read as slow. The gap is what the test is about, so widen it —
# 2s outlier against a 1s budget keeps the same meaning with room for load.
flap_dir="$tmp/w-flap"
cat >"$tmp/flappy.sh" <<'FLAP'
#!/usr/bin/env bash
n="$(cat "$FLAP_COUNTER" 2>/dev/null || echo 0)"
echo $((n + 1)) >"$FLAP_COUNTER"
[ "$n" = "0" ] && sleep 2
exit 0
FLAP
chmod +x "$tmp/flappy.sh"
FLAP_COUNTER="$tmp/flap.count" soak_once "$flap_dir" \
  FLAP_COUNTER="$tmp/flap.count" \
  LAST_STACK_CANARY_BOARD_WRITE_CHECK_CMD="$tmp/flappy.sh" \
  LAST_STACK_CANARY_WRITE_MS_MAX=1000 \
  LAST_STACK_CANARY_CHECK_SAMPLES=3 \
  >"$tmp/w-flap.out" 2>"$tmp/w-flap.err"
grep -q 'status=soak_green' "$tmp/w-flap.out" \
  || { echo "flap median assertion failed: $(cat "$tmp/w-flap.err")" >&2; exit 1; }

# A write that ERRORS is distinguishable in the ledger from one that is slow.
err_dir="$tmp/w-err"
if soak_once "$err_dir" \
     LAST_STACK_CANARY_BOARD_WRITE_CHECK_CMD="exit 3" \
     >"$tmp/w-err.out" 2>"$tmp/w-err.err"; then
  echo "expected a failing write to red the soak" >&2
  exit 1
fi
grep -q 'board_write\[exit_3\]' "$err_dir/ledger.jsonl"

# --dry-run must NEVER run the mutating probe against a real node, even though
# no stub was provided for it. Proof runs and CI fixtures depend on this.
skip_dir="$tmp/w-skip"
"$CLI" --state-dir "$skip_dir" dogfood --dry-run --sha w-skip >/dev/null
LAST_STACK_CANARY_LAUNCHD_CHECK_CMD=pass \
LAST_STACK_CANARY_MEMORY_CHECK_CMD=pass \
LAST_STACK_CANARY_BOARD_CHECK_CMD=pass \
LAST_STACK_CANARY_SITUATION_CHECK_CMD=pass \
LAST_STACK_CANARY_SOAK_HOURS=0 \
LAST_STACK_CANARY_LIVE_VERSION_CMD=pass \
  "$CLI" --state-dir "$skip_dir" soak-watch --dry-run --sha w-skip >"$tmp/w-skip.out"
grep -q 'CHECK label=board_write result=ok mode=dry-run-skip' "$tmp/w-skip.out"

# --- memory guard actually guards memory ------------------------------------
# `memory_guard` was named for a bar it did not implement: it ran `lastdb
# status` and read only the exit code. A check that reads as covered but is not
# is worse than an absent one.
over_dir="$tmp/m-over"
if MEM_CMD="printf 'Memory RSS: 20.0 GiB\n'" soak_once "$over_dir" \
     LASTDBD_RSS_LIMIT_MB=12288 \
     LAST_STACK_CANARY_BOARD_WRITE_CHECK_CMD=pass \
     >"$tmp/m-over.out" 2>"$tmp/m-over.err"; then
  echo "expected RSS over the ceiling to red the soak" >&2
  exit 1
fi
grep -q 'CHECK label=memory_guard result=fail rss_mb=20480' "$tmp/m-over.err"
grep -q 'memory_guard\[rss_mb=20480_ceiling_mb=11059\]' "$over_dir/ledger.jsonl"

under_dir="$tmp/m-under"
MEM_CMD="printf 'Memory RSS: 1.56 GiB\n'" soak_once "$under_dir" \
  LASTDBD_RSS_LIMIT_MB=12288 \
  LAST_STACK_CANARY_BOARD_WRITE_CHECK_CMD=pass \
  >"$tmp/m-under.out" 2>"$tmp/m-under.err"
grep -q 'status=soak_green' "$tmp/m-under.out"
grep -q 'CHECK label=memory_guard rss_mb=1597 ceiling_mb=11059' "$tmp/m-under.out"

# An older binary that does not print `Memory RSS:` must not brake a soak — but
# the gap has to be visible rather than silently green.
quiet_dir="$tmp/m-quiet"
MEM_CMD="printf 'lastdbd: running\n'" soak_once "$quiet_dir" \
  LAST_STACK_CANARY_BOARD_WRITE_CHECK_CMD=pass \
  >"$tmp/m-quiet.out" 2>"$tmp/m-quiet.err"
grep -q 'status=soak_green' "$tmp/m-quiet.out"
grep -q 'label=memory_guard note=rss_not_reported' "$tmp/m-quiet.err"

# --- an idle lane is a NOOP, not an error ---
# soak_red used to be selectable, so the watchers latched on an already-decided
# candidate and exited 1 every hour about a binary that was no longer live.
idle="$tmp/idle-state"
mkdir -p "$idle"
"$CLI" --state-dir "$idle" create dead --version 0.0.1 --source t --note n >/dev/null
"$CLI" --state-dir "$idle" advance dead dogfood_started --note n >/dev/null
"$CLI" --state-dir "$idle" advance dead dogfood_green --note n >/dev/null
"$CLI" --state-dir "$idle" advance dead soak_started --note n >/dev/null
"$CLI" --state-dir "$idle" advance dead soak_red --note n >/dev/null

out="$("$CLI" --state-dir "$idle" soak-watch --dry-run)"
rc=$?
[ "$rc" = "0" ]
printf '%s\n' "$out" | grep -q 'status=no_active_candidate'

out="$("$CLI" --state-dir "$idle" promote-prepare --dry-run)"
rc=$?
[ "$rc" = "0" ]
printf '%s\n' "$out" | grep -q 'status=no_active_candidate'

# --- a terminal verdict is never re-selected ---
! printf '%s\n' "$out" | grep -q 'soak_red'

# --- the situation fence default is the SCOPED preflight ---
grep -q 'situations preflight --action lastdb-safe-upgrade' "$CLI"
! grep -q 'jq -e "length == 0"' "$CLI"

# --- settle grace: a blind identity probe at soak start DEFERS ---
# Regression for 2026-08-30 (lx-20260830T221122.295-20948-1): soak-watch ran
# ~35s after the live cutover, the identity probe returned nothing, and the
# code appended a baseline-less soak_started row — then hard-red on
# primary_identity_baseline_missing, the baseline it had itself declined to
# write. Inside the settle grace this must be soak_pending with NO ledger
# transition; the next tick (warm node) establishes the baseline properly.
settle_dir="$tmp/w-settle"
LAST_STACK_CANARY_LIVE_VERSION_CMD=pass \
  "$CLI" --state-dir "$settle_dir" dogfood --sha w-settle --version 0.0.1-canary.test \
  >/dev/null 2>&1
LAST_STACK_CANARY_PRIMARY_IDENTITY_CMD="exit 1" \
LAST_STACK_CANARY_LAUNCHD_CHECK_CMD=pass \
LAST_STACK_CANARY_MEMORY_CHECK_CMD=pass \
LAST_STACK_CANARY_BOARD_CHECK_CMD=pass \
LAST_STACK_CANARY_BOARD_WRITE_CHECK_CMD=pass \
LAST_STACK_CANARY_SITUATION_CHECK_CMD=pass \
LAST_STACK_CANARY_SOAK_HOURS=24 \
LAST_STACK_CANARY_LIVE_VERSION_CMD=pass \
  "$CLI" --state-dir "$settle_dir" soak-watch --sha w-settle >"$tmp/w-settle.out" 2>&1
grep -q 'status=soak_pending' "$tmp/w-settle.out"
grep -q 'soak_settling primary_identity_unavailable' "$tmp/w-settle.out"
! grep -q 'soak_started' "$settle_dir/ledger.jsonl"
# Next tick, probe recovered: the baseline lands WITH identity and the soak
# can complete (hours=0 collapses the window for the fixture).
LAST_STACK_CANARY_PRIMARY_IDENTITY_CMD="printf 'pid=4242 process_start_ts=1234 build=0.0.1-canary.test\n'" \
LAST_STACK_CANARY_LAUNCHD_CHECK_CMD=pass \
LAST_STACK_CANARY_MEMORY_CHECK_CMD=pass \
LAST_STACK_CANARY_BOARD_CHECK_CMD=pass \
LAST_STACK_CANARY_BOARD_WRITE_CHECK_CMD=pass \
LAST_STACK_CANARY_SITUATION_CHECK_CMD=pass \
LAST_STACK_CANARY_SOAK_HOURS=0 \
LAST_STACK_CANARY_LIVE_VERSION_CMD=pass \
  "$CLI" --state-dir "$settle_dir" soak-watch --sha w-settle >"$tmp/w-settle2.out" 2>&1
grep -q 'status=soak_green' "$tmp/w-settle2.out"
grep -q '"state":"soak_started".*"primary_pid":"4242"\|"primary_pid":"4242".*"state":"soak_started"' \
  "$settle_dir/ledger.jsonl"

# Past the grace, a probe that stays blind cannot certify a soak → real red.
blind_dir="$tmp/w-blind"
LAST_STACK_CANARY_LIVE_VERSION_CMD=pass \
  "$CLI" --state-dir "$blind_dir" dogfood --sha w-blind --version 0.0.1-canary.test \
  >/dev/null 2>&1
if LAST_STACK_CANARY_PRIMARY_IDENTITY_CMD="exit 1" \
   LAST_STACK_CANARY_SETTLE_GRACE_MIN=0 \
   LAST_STACK_CANARY_LAUNCHD_CHECK_CMD=pass \
   LAST_STACK_CANARY_MEMORY_CHECK_CMD=pass \
   LAST_STACK_CANARY_BOARD_CHECK_CMD=pass \
   LAST_STACK_CANARY_BOARD_WRITE_CHECK_CMD=pass \
   LAST_STACK_CANARY_SITUATION_CHECK_CMD=pass \
   LAST_STACK_CANARY_SOAK_HOURS=24 \
   LAST_STACK_CANARY_LIVE_VERSION_CMD=pass \
     "$CLI" --state-dir "$blind_dir" soak-watch --sha w-blind \
     >"$tmp/w-blind.out" 2>&1; then
  echo "expected a past-grace blind identity probe to red the soak" >&2
  exit 1
fi
grep -q 'status=soak_red' "$tmp/w-blind.out"
grep -q 'primary_identity_unavailable_past_settle_grace' "$blind_dir/ledger.jsonl"

# --- one exit-code blip is not a verdict; a persistent failure is ---
# Same principle as the slow-median rule: one failed read probe is a blip
# (post-cutover `kanban ping` timing out), a failure that survives the
# bounded retry is the binary.
flapread_dir="$tmp/w-flapread"
cat >"$tmp/flapread.sh" <<'FLAPR'
#!/usr/bin/env bash
n="$(cat "$FLAPR_COUNTER" 2>/dev/null || echo 0)"
echo $((n + 1)) >"$FLAPR_COUNTER"
[ "$n" = "0" ] && exit 1
exit 0
FLAPR
chmod +x "$tmp/flapread.sh"
LAST_STACK_CANARY_LIVE_VERSION_CMD=pass \
  "$CLI" --state-dir "$flapread_dir" dogfood --sha w-flapread --version 0.0.1-canary.test \
  >/dev/null 2>&1
FLAPR_COUNTER="$tmp/flapread.count" \
LAST_STACK_CANARY_CHECK_FAIL_RETRY_DELAY_S=0 \
LAST_STACK_CANARY_PRIMARY_IDENTITY_CMD="printf 'pid=4242 process_start_ts=1234 build=0.0.1-canary.test\n'" \
LAST_STACK_CANARY_LAUNCHD_CHECK_CMD=pass \
LAST_STACK_CANARY_MEMORY_CHECK_CMD=pass \
LAST_STACK_CANARY_BOARD_CHECK_CMD="$tmp/flapread.sh" \
LAST_STACK_CANARY_BOARD_WRITE_CHECK_CMD=pass \
LAST_STACK_CANARY_SITUATION_CHECK_CMD=pass \
LAST_STACK_CANARY_SOAK_HOURS=0 \
LAST_STACK_CANARY_LIVE_VERSION_CMD=pass \
  "$CLI" --state-dir "$flapread_dir" soak-watch --sha w-flapread \
  >"$tmp/w-flapread.out" 2>"$tmp/w-flapread.err"
grep -q 'status=soak_green' "$tmp/w-flapread.out"
grep -q 'CHECK label=board_read result=retry exit_1' "$tmp/w-flapread.err"

persist_dir="$tmp/w-persist"
LAST_STACK_CANARY_LIVE_VERSION_CMD=pass \
  "$CLI" --state-dir "$persist_dir" dogfood --sha w-persist --version 0.0.1-canary.test \
  >/dev/null 2>&1
if LAST_STACK_CANARY_CHECK_FAIL_RETRY_DELAY_S=0 \
   LAST_STACK_CANARY_PRIMARY_IDENTITY_CMD="printf 'pid=4242 process_start_ts=1234 build=0.0.1-canary.test\n'" \
   LAST_STACK_CANARY_LAUNCHD_CHECK_CMD=pass \
   LAST_STACK_CANARY_MEMORY_CHECK_CMD=pass \
   LAST_STACK_CANARY_BOARD_CHECK_CMD="exit 1" \
   LAST_STACK_CANARY_BOARD_WRITE_CHECK_CMD=pass \
   LAST_STACK_CANARY_SITUATION_CHECK_CMD=pass \
   LAST_STACK_CANARY_SOAK_HOURS=0 \
   LAST_STACK_CANARY_LIVE_VERSION_CMD=pass \
     "$CLI" --state-dir "$persist_dir" soak-watch --sha w-persist \
     >"$tmp/w-persist.out" 2>"$tmp/w-persist.err"; then
  echo "expected a persistent board_read failure to red the soak" >&2
  exit 1
fi
grep -q 'status=soak_red' "$tmp/w-persist.out"
grep -q 'board_read\[exit_1\]' "$persist_dir/ledger.jsonl"

# --- v2 verdict fixtures are pure durable-evidence queries ---
"$CLI" --json verdict --candidate sep0830 --boot '{"pid":"1","start_ts":"1"}' --observations '[]' \
  | grep -q '"verdict":"window-open"'
"$CLI" --json verdict --candidate sep0831 --boot '{"pid":"1","start_ts":"1","cause":"guard-memory"}' --observations '[]' \
  | grep -q '"evidence":"restart\[guard-memory\]"'
"$CLI" --json verdict --candidate sep0901 --boot '{"pid":"1","start_ts":"1"}' \
  --observations '[{"check":"status_latency[19s>2s]","subject":"build","passed":false}]' \
  | grep -q '"evidence":"status_latency\[19s>2s\]"'

# --- v2 reconciler reads only immutable boot and observation rows ---
v2_dir="$tmp/v2"
v2_at_0830='2026-08-30T00:30:00Z'
"$CLI" --state-dir "$v2_dir" record-boot --candidate sep0830 --pid 101 \
  --start-ts '2026-08-30T00:00:00Z' --build v0830 --at '2026-08-30T00:00:00Z' >/dev/null
out="$("$CLI" --state-dir "$v2_dir" --json reconcile --candidate sep0830 \
  --window-seconds 86400 --at "$v2_at_0830")"
[ "$(printf '%s\n' "$out" | jq -r '.verdict')" = "window-open" ]
[ "$(printf '%s\n' "$out" | jq -r '.action')" = "wait-next-check" ]
[ "$(printf '%s\n' "$out" | jq -r '.boot_count')" = "1" ]
[ "$(printf '%s\n' "$out" | jq -r '.action_plan.dispatchable')" = "false" ]
wait_log="$tmp/wait-action.log"
out="$("$CLI" --state-dir "$v2_dir" --json reconcile --candidate sep0830 \
  --window-seconds 86400 --at "$v2_at_0830" --execute-actions \
  --action-command "printf '%s\\n' waited >> '$wait_log'")"
[ "$(printf '%s\n' "$out" | jq -r '.action_dispatch')" = "not-an-action" ]
[ "$(printf '%s\n' "$out" | jq -r '.action_plan.dispatchable')" = "false" ]
test ! -e "$wait_log"

"$CLI" --state-dir "$v2_dir" record-boot --candidate sep0831 --pid 102 \
  --start-ts '2026-08-31T00:00:00Z' --build v0831 --cause guard-memory --at '2026-08-31T00:00:00Z' >/dev/null
out="$("$CLI" --state-dir "$v2_dir" --json reconcile --candidate sep0831 \
  --window-seconds 86400 --at '2026-08-31T00:30:00Z')"
[ "$(printf '%s\n' "$out" | jq -r '.verdict')" = "red" ]
[ "$(printf '%s\n' "$out" | jq -r '.subject')" = "build" ]
[ "$(printf '%s\n' "$out" | jq -r '.evidence')" = "restart[guard-memory]" ]
[ "$(printf '%s\n' "$out" | jq -r '.action')" = "heal" ]
[ "$(printf '%s\n' "$out" | jq -r '.heal_queued')" = "true" ]
jq -e 'select(.record_type == "heal_queue" and .candidate == "sep0831" and .status == "queued")' \
  "$v2_dir/ledger.jsonl" >/dev/null

# A heal attempts once for a durable failure class. Later ticks re-check the
# evidence but never make their own repeated action attempt.
heal_log="$tmp/heal-action.log"
out="$("$CLI" --state-dir "$v2_dir" --json reconcile --candidate sep0831 \
  --window-seconds 86400 --at '2026-08-31T00:31:00Z' --execute-actions \
  --action-command "printf '%s\\n' heal >> '$heal_log'")"
[ "$(printf '%s\n' "$out" | jq -r '.action_dispatch')" = "ok" ]
out="$("$CLI" --state-dir "$v2_dir" --json reconcile --candidate sep0831 \
  --window-seconds 86400 --at '2026-08-31T00:32:00Z' --execute-actions \
  --action-command "printf '%s\\n' heal >> '$heal_log'")"
[ "$(printf '%s\n' "$out" | jq -r '.action_dispatch')" = "already-dispatched" ]
test "$(wc -l <"$heal_log" | tr -d ' ')" -eq 1

"$CLI" --state-dir "$v2_dir" record-boot --candidate heal-env --pid 111 \
  --start-ts '2026-08-31T00:00:00Z' --build vhealenv --cause guard-memory \
  --at '2026-08-31T00:00:00Z' >/dev/null
heal_env_log="$tmp/heal-env-action.log"
out="$(LAST_STACK_CANARY_V2_HEAL_CMD="printf '%s\\n' heal-env >> '$heal_env_log'" \
  "$CLI" --state-dir "$v2_dir" --json reconcile --candidate heal-env \
  --window-seconds 86400 --at '2026-08-31T00:31:00Z' --execute-actions)"
[ "$(printf '%s\n' "$out" | jq -r '.action')" = "heal" ]
[ "$(printf '%s\n' "$out" | jq -r '.action_dispatch')" = "ok" ]
[ "$(printf '%s\n' "$out" | jq -r '.action_plan.dispatchable')" = "true" ]
grep -q heal-env "$heal_env_log"

"$CLI" --state-dir "$v2_dir" record-boot --candidate sep0901 --pid 103 \
  --start-ts '2026-09-01T00:00:00Z' --build v0901 --at '2026-09-01T00:00:00Z' >/dev/null
"$CLI" --state-dir "$v2_dir" record-observation --candidate sep0901 --check status_latency \
  --subject build --result pass --measured-ms 19000 --budget-ms 2000 --at '2026-09-01T00:01:00Z' >/dev/null
out="$("$CLI" --state-dir "$v2_dir" --json reconcile --candidate sep0901 \
  --window-seconds 86400 --at '2026-09-01T00:30:00Z')"
[ "$(printf '%s\n' "$out" | jq -r '.verdict')" = "red" ]
[ "$(printf '%s\n' "$out" | jq -r '.evidence')" = "status_latency[p95=19000ms>2000ms]" ]

# Timeout and absence are failures even when a collector falsely reports pass.
"$CLI" --state-dir "$v2_dir" record-boot --candidate absence --pid 104 \
  --start-ts '2026-09-02T00:00:00Z' --build vabsence --at '2026-09-02T00:00:00Z' >/dev/null
"$CLI" --state-dir "$v2_dir" record-observation --candidate absence --check status \
  --subject observer --result pass --detail timeout --at '2026-09-02T00:01:00Z' >/dev/null
out="$("$CLI" --state-dir "$v2_dir" --json reconcile --candidate absence \
  --window-seconds 86400 --at '2026-09-02T00:30:00Z')"
[ "$(printf '%s\n' "$out" | jq -r '.verdict')" = "line-stopped" ]
[ "$(printf '%s\n' "$out" | jq -r '.action')" = "line-stop" ]

"$CLI" --state-dir "$v2_dir" record-boot --candidate host-window --pid 105 \
  --start-ts '2026-09-03T00:00:00Z' --build vhost --at '2026-09-03T00:00:00Z' >/dev/null
"$CLI" --state-dir "$v2_dir" record-observation --candidate host-window --check disk \
  --subject host --result fail --detail absent --at '2026-09-03T00:01:00Z' >/dev/null
out="$("$CLI" --state-dir "$v2_dir" --json reconcile --candidate host-window \
  --window-seconds 86400 --at '2026-09-03T00:30:00Z')"
[ "$(printf '%s\n' "$out" | jq -r '.verdict')" = "window-open" ]
[ "$(printf '%s\n' "$out" | jq -r '.action')" = "pause-window" ]
[ "$(printf '%s\n' "$out" | jq -r '.action_plan.dispatchable')" = "true" ]
out="$("$CLI" --state-dir "$v2_dir" --json reconcile --candidate host-window \
  --window-seconds 86400 --at '2026-09-03T00:30:00Z' --execute-actions)"
[ "$(printf '%s\n' "$out" | jq -r '.action_dispatch')" = "planned" ]
[ "$(printf '%s\n' "$out" | jq -r '.action_plan.command')" = "" ]

# A neutral upgrade supersedes the old candidate. An operator restart starts a
# new quiet window instead of making the candidate red.
"$CLI" --state-dir "$v2_dir" record-boot --candidate superseded --pid 106 \
  --start-ts '2026-09-04T00:00:00Z' --build vold --cause upgrade --at '2026-09-04T00:00:00Z' >/dev/null
out="$("$CLI" --state-dir "$v2_dir" --json reconcile --candidate superseded \
  --window-seconds 86400 --at '2026-09-04T00:30:00Z')"
[ "$(printf '%s\n' "$out" | jq -r '.verdict')" = "superseded" ]
[ "$(printf '%s\n' "$out" | jq -r '.action')" = "retire" ]

"$CLI" --state-dir "$v2_dir" record-boot --candidate operator-reset --pid 107 \
  --start-ts '2026-09-05T00:00:00Z' --build vreset --at '2026-09-05T00:00:00Z' >/dev/null
"$CLI" --state-dir "$v2_dir" record-boot --candidate operator-reset --pid 108 \
  --start-ts '2026-09-05T01:00:00Z' --build vreset --cause operator --at '2026-09-05T01:00:00Z' >/dev/null
out="$("$CLI" --state-dir "$v2_dir" --json reconcile --candidate operator-reset \
  --window-seconds 7200 --at '2026-09-05T02:00:00Z')"
[ "$(printf '%s\n' "$out" | jq -r '.verdict')" = "window-open" ]

# A completed window with no observation rows is observer failure. Silence
# cannot certify a build as green.
"$CLI" --state-dir "$v2_dir" record-boot --candidate silent-window --pid 110 \
  --start-ts '2026-09-06T00:00:00Z' --build vsilent --at '2026-09-06T00:00:00Z' >/dev/null
out="$("$CLI" --state-dir "$v2_dir" --json reconcile --candidate silent-window \
  --window-seconds 86400 --at '2026-09-07T00:00:00Z')"
[ "$(printf '%s\n' "$out" | jq -r '.verdict')" = "line-stopped" ]
[ "$(printf '%s\n' "$out" | jq -r '.subject')" = "observer" ]
[ "$(printf '%s\n' "$out" | jq -r '.evidence')" = "observations_absent" ]
[ "$(printf '%s\n' "$out" | jq -r '.action')" = "line-stop" ]
[ "$(printf '%s\n' "$out" | jq -r '.observation_count')" = "0" ]

# Dry-run plans a fresh verdict but does not append another durable event.
dry_before="$(wc -l <"$v2_dir/ledger.jsonl" | tr -d ' ')"
out="$("$CLI" --state-dir "$v2_dir" --json reconcile --candidate sep0830 --dry-run \
  --window-seconds 86400 --at "$v2_at_0830")"
dry_after="$(wc -l <"$v2_dir/ledger.jsonl" | tr -d ' ')"
[ "$dry_before" = "$dry_after" ]
[ "$(printf '%s\n' "$out" | jq -r '.action_dispatch')" = "not-an-action" ]
[ "$(printf '%s\n' "$out" | jq -r '.action_plan.dispatchable')" = "false" ]
[ "$(printf '%s\n' "$out" | jq -r '.heal_queued')" = "false" ]

# Dry-run plus execute still writes no evidence and starts no command.
dry_exec_log="$tmp/dry-exec.log"
stable_before="$tmp/stable-before"
cp "$v2_dir/ledger.jsonl" "$stable_before"
out="$("$CLI" --state-dir "$v2_dir" --json reconcile --candidate sep0831 --dry-run \
  --execute-actions --action-command "printf '%s\\n' ran >> '$dry_exec_log'" \
  --window-seconds 86400 --at '2026-08-31T00:33:00Z')"
[ "$(printf '%s\n' "$out" | jq -r '.action')" = "heal" ]
[ "$(printf '%s\n' "$out" | jq -r '.action_dispatch')" = "dry-run" ]
[ "$(printf '%s\n' "$out" | jq -r '.action_plan.dispatchable')" = "true" ]
[ "$(printf '%s\n' "$out" | jq -r '.action_plan.command')" != "" ]
[ "$(printf '%s\n' "$out" | jq -r '.heal_queued')" = "false" ]
cmp -s "$stable_before" "$v2_dir/ledger.jsonl"
test ! -e "$dry_exec_log"
if grep -Eq 'SOAK_WAIT|resume_key|active_execution' "$v2_dir/ledger.jsonl"; then
  echo "v2 ledger contains a legacy wait marker" >&2
  exit 1
fi

# Channel policy keeps primary on main, promotes only a completed quiet window,
# and holds a normal incoming cutover near the current window end.
out="$("$CLI" --state-dir "$v2_dir" --json channels --main-build sep0830 --incoming-build next \
  --window-seconds 86400 --cutover-hold-hours 24 --at '2026-08-30T00:30:00Z')"
[ "$(printf '%s\n' "$out" | jq -r '.primary.tracks_main')" = "true" ]
[ "$(printf '%s\n' "$out" | jq -r '.stable.verdict')" = "none" ]
[ "$(printf '%s\n' "$out" | jq -r '.cutover.hold')" = "true" ]
out="$("$CLI" --state-dir "$v2_dir" --json channels --main-build sep0830 --incoming-build next \
  --incoming-fixes-red --window-seconds 86400 --cutover-hold-hours 24 --at '2026-08-30T00:30:00Z')"
[ "$(printf '%s\n' "$out" | jq -r '.cutover.hold')" = "false" ]

"$CLI" --state-dir "$v2_dir" record-boot --candidate channel-green --pid 109 \
  --start-ts '2026-08-01T00:00:00Z' --build vgreen >/dev/null
"$CLI" --state-dir "$v2_dir" record-observation --candidate channel-green --check status \
  --subject build --result pass --at '2026-08-01T00:01:00Z' >/dev/null
"$CLI" --state-dir "$v2_dir" reconcile --candidate channel-green --window-seconds 86400 \
  --at '2026-09-01T00:00:00Z' >/dev/null
out="$("$CLI" --state-dir "$v2_dir" --json channels --main-build channel-green \
  --window-seconds 86400 --at '2026-09-01T00:00:00Z')"
[ "$(printf '%s\n' "$out" | jq -r '.stable.build')" = "channel-green" ]

# The live collector reads only Fold's bounded owner boot ledger. A later build
# retires the candidate; a failed collector remains named observer evidence,
# while the missing boot row remains a build failure.
boot_ledger_json='{"boots":[{"pid":201,"process_start_ts":1788134400,"build":"vcanary","restart_cause":"initial"},{"pid":202,"process_start_ts":1788138000,"build":"vnext","restart_cause":"upgrade"}]}'
out="$("$CLI" --state-dir "$v2_dir" --json sync-boot-ledger --candidate vcanary \
  --boot-ledger-command "printf '%s\\n' '$boot_ledger_json'")"
[ "$(printf '%s\n' "$out" | jq -r '.result')" = "ok" ]
[ "$(printf '%s\n' "$out" | jq -r '.matched_boots')" = "2" ]
[ "$(printf '%s\n' "$out" | jq -r '.appended_boots')" = "2" ]
out="$("$CLI" --state-dir "$v2_dir" --json reconcile --candidate vcanary \
  --window-seconds 86400 --at '2026-09-01T02:00:00Z')"
[ "$(printf '%s\n' "$out" | jq -r '.verdict')" = "superseded" ]
[ "$(printf '%s\n' "$out" | jq -r '.evidence')" = "restart[supersession]" ]
out="$("$CLI" --state-dir "$v2_dir" --json sync-boot-ledger --candidate vcanary \
  --boot-ledger-command "printf '%s\\n' '$boot_ledger_json'")"
[ "$(printf '%s\n' "$out" | jq -r '.appended_boots')" = "0" ]
[ "$(printf '%s\n' "$out" | jq -r '.duplicate_boots')" = "2" ]

out="$("$CLI" --state-dir "$v2_dir" --json sync-boot-ledger --candidate vmissing \
  --boot-ledger-command 'exit 28')"
[ "$(printf '%s\n' "$out" | jq -r '.result')" = "failed" ]
[ "$(printf '%s\n' "$out" | jq -r '.failure')" = "absent" ]
out="$("$CLI" --state-dir "$v2_dir" --json reconcile --candidate vmissing \
  --window-seconds 86400 --at '2026-09-01T02:00:00Z')"
[ "$(printf '%s\n' "$out" | jq -r '.verdict')" = "red" ]
[ "$(printf '%s\n' "$out" | jq -r '.subject')" = "build" ]

# Command observations measure a real p95 and preserve timeout/exit evidence.
out="$("$CLI" --state-dir "$v2_dir" --json observe-command --candidate command-pass \
  --check status --subject build --command true --samples 3 --timeout-seconds 1 --budget-ms 2000 \
  --at '2026-09-01T00:00:00Z')"
[ "$(printf '%s\n' "$out" | jq -r '.passed')" = "true" ]
[ "$(printf '%s\n' "$out" | jq -r '.samples')" = "3" ]
out="$("$CLI" --state-dir "$v2_dir" --json observe-command --candidate command-fail \
  --check status --subject build --command 'exit 7' --samples 3 --timeout-seconds 1 --budget-ms 2000 \
  --at '2026-09-01T00:00:00Z')"
[ "$(printf '%s\n' "$out" | jq -r '.passed')" = "false" ]
[ "$(printf '%s\n' "$out" | jq -r '.detail')" = "exit_7" ]

# A candidate-independent identity absence is durable observer evidence. The
# next successful identity read clears the line without blaming a build.
"$CLI" --state-dir "$v2_dir" record-line-event --check primary_identity \
  --subject observer --result pass --detail timeout --at '2026-09-01T00:00:00Z' >/dev/null
out="$("$CLI" --state-dir "$v2_dir" --json line-status)"
[ "$(printf '%s\n' "$out" | jq -r '.state')" = "line-stopped" ]
[ "$(printf '%s\n' "$out" | jq -r '.subject')" = "observer" ]
"$CLI" --state-dir "$v2_dir" record-line-event --check primary_identity \
  --subject observer --result pass --at '2026-09-01T00:01:00Z' >/dev/null
out="$("$CLI" --state-dir "$v2_dir" --json line-status)"
[ "$(printf '%s\n' "$out" | jq -r '.state')" = "clear" ]

echo "PASS last-stack-canary-pipeline"
