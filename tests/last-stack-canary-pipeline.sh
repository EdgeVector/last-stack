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

# One slow sample is load; a slow MEDIAN is the binary. A single outlier among
# three must not brake a good candidate.
flap_dir="$tmp/w-flap"
cat >"$tmp/flappy.sh" <<'FLAP'
#!/usr/bin/env bash
n="$(cat "$FLAP_COUNTER" 2>/dev/null || echo 0)"
echo $((n + 1)) >"$FLAP_COUNTER"
[ "$n" = "0" ] && sleep 0.4
exit 0
FLAP
chmod +x "$tmp/flappy.sh"
FLAP_COUNTER="$tmp/flap.count" soak_once "$flap_dir" \
  FLAP_COUNTER="$tmp/flap.count" \
  LAST_STACK_CANARY_BOARD_WRITE_CHECK_CMD="$tmp/flappy.sh" \
  LAST_STACK_CANARY_WRITE_MS_MAX=200 \
  LAST_STACK_CANARY_CHECK_SAMPLES=3 \
  >"$tmp/w-flap.out" 2>"$tmp/w-flap.err"
grep -q 'status=soak_green' "$tmp/w-flap.out"

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

echo "PASS last-stack-canary-pipeline"

