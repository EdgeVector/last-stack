#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
CLI="$ROOT/bin/last-stack-lastdb-canary-dogfood"
LEDGER="$ROOT/bin/last-stack-canary-pipeline"
chmod +x "$CLI" "$LEDGER"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

state_dir="$tmp/state"
# Hermetic main tip — must not match host-built describe binaries accidentally.
MAIN_OID="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
# Isolate canary-builds + fold mirror so host state cannot pollute resolution.
export LAST_STACK_CANARY_MAIN_OID="$MAIN_OID"
export LAST_STACK_CANARY_FOLD_MIRROR="$tmp/no-fold-mirror"
export LAST_STACK_CANARY_BUILDS_DIR="$tmp/canary-builds"
export LAST_STACK_CANARY_FETCH_MAIN=0
# Hermetic: never probe host lastdbd / situations during fixture steps.
export LAST_STACK_CANARY_LIVE_VERSION_CMD=pass
export LAST_STACK_CANARY_SITUATION_CHECK_CMD=pass
mkdir -p "$LAST_STACK_CANARY_BUILDS_DIR"

stub="$tmp/safe-upgrade-stub"
cat >"$stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${SAFE_UPGRADE_STUB_LOG:?}"
case " $* " in
  *" --probe-only "*) printf 'VERDICT: GREEN_PROBE_ONLY\n' ;;
  *) printf 'VERDICT: GREEN\n' ;;
esac
STUB
chmod +x "$stub"

# --- default path: forge-main local binary (trusted override) ---
fallback_bin="$tmp/lastdbd"
cat >"$fallback_bin" <<'BIN'
#!/usr/bin/env bash
printf 'lastdbd 0.25.0-local-main\n'
BIN
chmod +x "$fallback_bin"

out="$(
  LAST_STACK_CANARY_LOCAL_FALLBACK_BIN="$fallback_bin" \
  LAST_STACK_CANARY_SAFE_UPGRADE="$stub" \
  SAFE_UPGRADE_STUB_LOG="$tmp/safe-upgrade.log" \
  "$CLI" --state-dir "$tmp/fallback-state" --dry-run --json
)"
[ "$(printf '%s\n' "$out" | jq -r '.source')" = "forge-main" ]
[ "$(printf '%s\n' "$out" | jq -r '.safe_upgrade_args[0]')" = "--candidate" ]
[ "$(printf '%s\n' "$out" | jq -r '.state')" = "dogfood_green" ]

# --- without a local binary: fail closed (no GH by default) ---
out="$(
  env -u LAST_STACK_CANARY_LOCAL_FALLBACK_BIN \
  LAST_STACK_CANARY_SAFE_UPGRADE="$stub" \
  "$CLI" --state-dir "$tmp/missing-state" --dry-run --json
)" || true
[ "$(printf '%s\n' "$out" | jq -r '.source')" = "forge-main-missing" ]
# NOT dogfood_red: nothing was probed, so nothing may be concluded about a
# binary. Sharing dogfood_red with a real regression is how two dead nights
# read as bad builds and nobody was paged.
[ "$(printf '%s\n' "$out" | jq -r '.state')" = "no_candidate" ]
[ "$(printf '%s\n' "$out" | jq -r '.safe_upgrade')" = "not-run-no-candidate" ]

# --- stale GH prerelease without source_git_oid matching main: refused ---
stale_json='[
  {
    "tag_name": "v0.23.3-canary.20260801",
    "name": "stale canary",
    "prerelease": true,
    "draft": false,
    "assets": [{"name": "lastdb-aarch64-apple-darwin.tar.gz"}]
  }
]'
out="$(
  env -u LAST_STACK_CANARY_LOCAL_FALLBACK_BIN \
  LAST_STACK_CANARY_RELEASES_JSON="$stale_json" \
  LAST_STACK_CANARY_SAFE_UPGRADE="$stub" \
  "$CLI" --state-dir "$tmp/stale-gh-state" --dry-run --json
)" || true
[ "$(printf '%s\n' "$out" | jq -r '.source')" = "forge-main-missing" ]
[ "$(printf '%s\n' "$out" | jq -r '.state')" = "no_candidate" ]

# --- GH opt-in only when source_git_oid matches main tip ---
release_json="$(
  MAIN_OID="$MAIN_OID" python3 - <<'PY'
import json, os
print(json.dumps([
  {
    "tag_name": "v0.24.0-canary.1",
    "name": "LastDB canary",
    "prerelease": True,
    "draft": False,
    "source_git_oid": os.environ["MAIN_OID"],
    "assets": [{"name": "lastdb-aarch64-apple-darwin.tar.gz"}],
  }
]))
PY
)"

out="$(
  env -u LAST_STACK_CANARY_LOCAL_FALLBACK_BIN \
  LAST_STACK_CANARY_RELEASES_JSON="$release_json" \
  LAST_STACK_CANARY_SAFE_UPGRADE="$stub" \
  SAFE_UPGRADE_STUB_LOG="$tmp/safe-upgrade.log" \
  "$CLI" --state-dir "$state_dir" --dry-run --json
)"

[ "$(printf '%s\n' "$out" | jq -r '.candidate')" = "lastdb-0.24.0-canary.1" ]
[ "$(printf '%s\n' "$out" | jq -r '.state')" = "dogfood_green" ]
[ "$(printf '%s\n' "$out" | jq -r '.source')" = "github-prerelease-canary" ]
[ ! -e "$tmp/safe-upgrade.log" ]
[ "$(wc -l <"$state_dir/ledger.jsonl" | tr -d ' ')" = "3" ]

out="$(
  env -u LAST_STACK_CANARY_LOCAL_FALLBACK_BIN \
  LAST_STACK_CANARY_RELEASES_JSON="$release_json" \
  LAST_STACK_CANARY_SAFE_UPGRADE="$stub" \
  SAFE_UPGRADE_STUB_LOG="$tmp/safe-upgrade.log" \
  "$CLI" --state-dir "$state_dir" --live --json
)"
[ "$(printf '%s\n' "$out" | jq -r '.safe_upgrade')" = "green" ]
grep -q -- '--probe-only --version 0.24.0-canary.1' "$tmp/safe-upgrade.log"

# cutover: one Loom graph owns the probe and live step
: >"$tmp/safe-upgrade.log"
loom_stub="$tmp/safe-upgrade-loom-stub"
cat >"$loom_stub" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${SAFE_UPGRADE_LOOM_STUB_LOG:?}"
printf '%s\n' '{"outcome":"ok","status":"succeeded","state":"DONE","execution":"lx-test","graph":"lastdb-safe-upgrade"}'
STUB
chmod +x "$loom_stub"
cut_state="$tmp/cutover-state"
out="$(
  LAST_STACK_CANARY_LOCAL_FALLBACK_BIN="$fallback_bin" \
  LAST_STACK_CANARY_SAFE_UPGRADE="$stub" \
  LAST_STACK_CANARY_SAFE_UPGRADE_LOOM="$loom_stub" \
  SAFE_UPGRADE_STUB_LOG="$tmp/safe-upgrade.log" \
  SAFE_UPGRADE_LOOM_STUB_LOG="$tmp/safe-upgrade-loom.log" \
  LAST_STACK_CANARY_SITUATION_CHECK_CMD=pass \
  LAST_STACK_CANARY_LIVE_VERSION_CMD='echo lastdbd 0.25.0-local-main' \
  "$CLI" --state-dir "$cut_state" --cutover --skip-situation-preflight --json
)"
[ "$(printf '%s\n' "$out" | jq -r '.mode')" = "cutover" ]
[ "$(printf '%s\n' "$out" | jq -r '.safe_upgrade')" = "loom-cutover-green" ]
[ "$(printf '%s\n' "$out" | jq -r '.primary_mutation')" = "true" ]
[ ! -s "$tmp/safe-upgrade.log" ]
grep -q -- "--candidate $fallback_bin" "$tmp/safe-upgrade-loom.log"
grep -q -- "--source-git-oid $MAIN_OID" "$tmp/safe-upgrade-loom.log"

# --- local preferred over GH even when GH is allowed ---
out="$(
  LAST_STACK_CANARY_LOCAL_FALLBACK_BIN="$fallback_bin" \
  LAST_STACK_CANARY_RELEASES_JSON="$release_json" \
  LAST_STACK_CANARY_SAFE_UPGRADE="$stub" \
  "$CLI" --state-dir "$tmp/prefer-local-state" --dry-run --json
)"
[ "$(printf '%s\n' "$out" | jq -r '.source')" = "forge-main" ]
[ "$(printf '%s\n' "$out" | jq -r '.safe_upgrade_args[0]')" = "--candidate" ]

# --- staged canary-builds/<oid>/lastdbd with matching describe shortsha ---
stage="$LAST_STACK_CANARY_BUILDS_DIR/$MAIN_OID"
mkdir -p "$stage"
staged="$stage/lastdbd"
cat >"$staged" <<BIN
#!/usr/bin/env bash
printf 'lastdbd 0.26.0-1-g${MAIN_OID:0:9}\n'
BIN
chmod +x "$staged"
# write manifest too
printf '{"source_git_oid":"%s"}\n' "$MAIN_OID" >"$stage/manifest.json"

out="$(
  env -u LAST_STACK_CANARY_LOCAL_FALLBACK_BIN \
  LAST_STACK_CANARY_SAFE_UPGRADE="$stub" \
  "$CLI" --state-dir "$tmp/staged-state" --dry-run --json
)"
[ "$(printf '%s\n' "$out" | jq -r '.source')" = "forge-main" ]
[ "$(printf '%s\n' "$out" | jq -r '.safe_upgrade_args[1]')" = "$staged" ]
[ "$(printf '%s\n' "$out" | jq -r '.state')" = "dogfood_green" ]

# --- --dry-run never shells out to a release build ---
# The proof harness and every ad-hoc "what would tonight pick?" check run
# --dry-run; a multi-GB cargo build from one would red every CR that shells it.
build_probe="$tmp/build-probe"
build_stub="$tmp/build-main-stub"
cat >"$build_stub" <<STUB
#!/usr/bin/env bash
printf 'ran\n' >>"$build_probe"
exit 1
STUB
chmod +x "$build_stub"
: >"$build_probe"
out="$(
  env -u LAST_STACK_CANARY_LOCAL_FALLBACK_BIN \
  env -u LAST_STACK_CANARY_BUILDS_DIR \
  LAST_STACK_CANARY_MAIN_OID="$MAIN_OID" \
  LAST_STACK_CANARY_FOLD_MIRROR="$tmp/no-fold-mirror" \
  LAST_STACK_CANARY_BUILD_MAIN_BIN="$build_stub" \
  LAST_STACK_CANARY_SAFE_UPGRADE="$stub" \
  "$CLI" --state-dir "$tmp/nobuild-state" --dry-run --json
)" || true
[ ! -s "$build_probe" ]

# --- a --dry-run against the REAL ledger writes nothing to it ---
# The documented "what would tonight pick?" check used to stamp the production
# ledger with dogfood_green, and the next soak tick then recorded a false
# soak_red for a candidate that had never been cut over. Both are terminal, so
# a diagnostic could park the night it was run to inspect.
real_ledger_dir="$tmp/pretend-production"
mkdir -p "$real_ledger_dir"
out="$(
  env -u LAST_STACK_CANARY_LOCAL_FALLBACK_BIN \
  LAST_STACK_CANARY_PIPELINE_DIR="$real_ledger_dir" \
  LAST_STACK_CANARY_SAFE_UPGRADE="$stub" \
  "$CLI" --dry-run --json
)" || true
# No --state-dir was passed, so the run must not have created a ledger at all.
[ ! -e "$real_ledger_dir/ledger.jsonl" ]
# It still REPORTS the state it would have reached.
printf '%s\n' "$out" | jq -e '.state' >/dev/null

# --- but an explicit --state-dir still records (fixtures/proof depend on it) ---
out="$(
  LAST_STACK_CANARY_LOCAL_FALLBACK_BIN="$fallback_bin" \
  LAST_STACK_CANARY_SAFE_UPGRADE="$stub" \
  "$CLI" --state-dir "$tmp/explicit-state" --dry-run --json
)"
[ -s "$tmp/explicit-state/ledger.jsonl" ]
[ "$(printf '%s\n' "$out" | jq -r '.state')" = "dogfood_green" ]

# --- a blocked Situation is `blocked_situation`, never `dogfood_red` ---
# The fence stopping us says nothing about the candidate. Recording it as a red
# verdict is what let an unrelated codex outage look like a bad LastDB build.
out="$(
  env -u LAST_STACK_CANARY_LOCAL_FALLBACK_BIN \
  LAST_STACK_CANARY_SAFE_UPGRADE="$stub" \
  LAST_STACK_CANARY_SITUATION_CHECK_CMD=fail \
  "$CLI" --state-dir "$tmp/fenced-state" --cutover --json
)" || true
[ "$(printf '%s\n' "$out" | jq -r '.state')" = "blocked_situation" ]
[ "$(printf '%s\n' "$out" | jq -r '.safe_upgrade')" = "blocked-situation" ]
[ "$(printf '%s\n' "$out" | jq -r '.primary_mutation')" = "false" ]

# --- the default fence is SCOPED preflight, not "any Situation is open" ---
grep -q 'situations preflight --action lastdb-safe-upgrade' "$CLI"
! grep -q 'situations list --json | jq -e "length == 0"' "$CLI"
grep -q 'situations preflight --action lastdb-safe-upgrade' "$LEDGER"
! grep -q 'situations list --json | jq -e "length == 0"' "$LEDGER"

# A verified-live recovery uses a new attempt key. The old soak_red row stays
# terminal. The new row keeps the actual live version as its observed identity.
recovery_ledger="$tmp/recovery-ledger.jsonl"
old_sha="0.25.0-local-main"
"$LEDGER" --ledger "$recovery_ledger" create "$old_sha" --version "$old_sha" --source old >/dev/null
"$LEDGER" --ledger "$recovery_ledger" advance "$old_sha" dogfood_started >/dev/null
"$LEDGER" --ledger "$recovery_ledger" advance "$old_sha" dogfood_green >/dev/null
"$LEDGER" --ledger "$recovery_ledger" advance "$old_sha" soak_started >/dev/null
"$LEDGER" --ledger "$recovery_ledger" advance "$old_sha" soak_red >/dev/null
recovery_sha="$old_sha-recovery-lx-test-child"
LAST_STACK_CANARY_ANCESTRY_GUARD=0 \
  "$LEDGER" --json --ledger "$recovery_ledger" dogfood \
    --sha "$recovery_sha" \
    --observed-sha "$old_sha" \
    --version "$old_sha" \
    --source verified-live-recovery \
    --source-git-oid "$MAIN_OID" >/dev/null
recovery_current="$("$LEDGER" --json --ledger "$recovery_ledger" read "$recovery_sha")"
[ "$(printf '%s\n' "$recovery_current" | jq -r '.state')" = dogfood_green ]
[ "$(printf '%s\n' "$recovery_current" | jq -r '.candidate')" = "$recovery_sha" ]
[ "$(printf '%s\n' "$recovery_current" | jq -r '.observed_sha')" = "$old_sha" ]
[ "$("$LEDGER" --json --ledger "$recovery_ledger" read "$old_sha" | tail -1 | jq -r '.state')" = soak_red ]
before_retry="$(wc -l <"$recovery_ledger" | tr -d ' ')"
LAST_STACK_CANARY_ANCESTRY_GUARD=0 \
  "$LEDGER" --json --ledger "$recovery_ledger" dogfood \
    --sha "$recovery_sha" \
    --observed-sha "$old_sha" \
    --version "$old_sha" \
    --source verified-live-recovery \
    --source-git-oid "$MAIN_OID" >/dev/null
[ "$(wc -l <"$recovery_ledger" | tr -d ' ')" = "$before_retry" ]

# --- a staged build one merge behind main tip is still dogfooded ---
# Tip equality is unwinnable on a repo that merges several times a day: a real
# ancestor sat staged on the host while the nightly red'd as "unbuilt".
anc_mirror="$tmp/anc-mirror"
git init -q "$anc_mirror"
git -C "$anc_mirror" config user.email t@example.com
git -C "$anc_mirror" config user.name t
git -C "$anc_mirror" commit -q --allow-empty -m base
anc_oid="$(git -C "$anc_mirror" rev-parse HEAD)"
git -C "$anc_mirror" commit -q --allow-empty -m tip
tip_oid="$(git -C "$anc_mirror" rev-parse HEAD)"

anc_builds="$tmp/anc-builds"
mkdir -p "$anc_builds/$anc_oid"
cat >"$anc_builds/$anc_oid/lastdbd" <<'BIN'
#!/usr/bin/env bash
printf 'lastdbd 0.27.0-ancestor\n'
BIN
chmod +x "$anc_builds/$anc_oid/lastdbd"
printf '{"source_git_oid":"%s"}\n' "$anc_oid" >"$anc_builds/$anc_oid/manifest.json"

out="$(
  env -u LAST_STACK_CANARY_LOCAL_FALLBACK_BIN \
  LAST_STACK_CANARY_MAIN_OID="$tip_oid" \
  LAST_STACK_CANARY_FOLD_MIRROR="$anc_mirror" \
  LAST_STACK_CANARY_BUILDS_DIR="$anc_builds" \
  LAST_STACK_CANARY_SAFE_UPGRADE="$stub" \
  "$CLI" --state-dir "$tmp/anc-state" --dry-run --json
)"
[ "$(printf '%s\n' "$out" | jq -r '.source')" = "forge-main-ancestor" ]
[ "$(printf '%s\n' "$out" | jq -r '.state')" = "dogfood_green" ]
printf '%s\n' "$out" | jq -r '.note' | grep -q 'behind_main=1'

# --- but an ancestor outside the window is refused ---
out="$(
  env -u LAST_STACK_CANARY_LOCAL_FALLBACK_BIN \
  LAST_STACK_CANARY_MAIN_OID="$tip_oid" \
  LAST_STACK_CANARY_FOLD_MIRROR="$anc_mirror" \
  LAST_STACK_CANARY_BUILDS_DIR="$anc_builds" \
  LAST_STACK_CANARY_ANCESTOR_MAX_COMMITS=0 \
  LAST_STACK_CANARY_SAFE_UPGRADE="$stub" \
  "$CLI" --state-dir "$tmp/anc-window-state" --dry-run --json
)" || true
[ "$(printf '%s\n' "$out" | jq -r '.source')" = "forge-main-missing" ]

# --- a build that is NOT on main's history is never eligible ---
git -C "$anc_mirror" checkout -q -b side "$anc_oid"
git -C "$anc_mirror" commit -q --allow-empty -m off-main
side_oid="$(git -C "$anc_mirror" rev-parse HEAD)"
git -C "$anc_mirror" checkout -q -
side_builds="$tmp/side-builds"
mkdir -p "$side_builds/$side_oid"
cat >"$side_builds/$side_oid/lastdbd" <<'BIN'
#!/usr/bin/env bash
printf 'lastdbd 0.27.0-sidebranch\n'
BIN
chmod +x "$side_builds/$side_oid/lastdbd"
printf '{"source_git_oid":"%s"}\n' "$side_oid" >"$side_builds/$side_oid/manifest.json"

out="$(
  env -u LAST_STACK_CANARY_LOCAL_FALLBACK_BIN \
  LAST_STACK_CANARY_MAIN_OID="$tip_oid" \
  LAST_STACK_CANARY_FOLD_MIRROR="$anc_mirror" \
  LAST_STACK_CANARY_BUILDS_DIR="$side_builds" \
  LAST_STACK_CANARY_SAFE_UPGRADE="$stub" \
  "$CLI" --state-dir "$tmp/side-state" --dry-run --json
)" || true
[ "$(printf '%s\n' "$out" | jq -r '.source')" = "forge-main-missing" ]

grep -q '^id = "lastdb-canary-dogfood"$' "$ROOT/config/routines-registry/lastdb-canary-dogfood.toml"
grep -q '^status = "active"$' "$ROOT/config/routines-registry/lastdb-canary-dogfood.toml"
grep -q 'lastdb-canary-dogfood.md' "$ROOT/config/routines-registry/lastdb-canary-dogfood.toml"
# The nightly starts Loom graph B only. Graph B starts graph A as a child.
# The legacy CLI remains testable, but the scheduled prompt now dispatches one
# bounded v2 action and gives quiet-window ownership to the hourly reconciler.
dog_md="$ROOT/routines/lastdb-canary-dogfood.md"
grep -q 'last-stack-canary-v2-dogfood-gate' "$dog_md"
grep -q 'bounded safe-upgrade action' "$dog_md"
if grep -Eq 'last-stack-canary-loom|lastdb-canary-release|SOAK_WAIT' "$dog_md"; then
  echo "dogfood prompt still invokes the retired release graph" >&2
  exit 1
fi
# The soak watch is the v2 evidence reconciler, not a Loom clock.
soak_md="$ROOT/routines/lastdb-canary-soak-watch.md"
grep -q 'stateless LastDB canary v2 reconciler' "$soak_md"
if grep -Eq 'last-stack-canary-loom|SOAK_WAIT' "$soak_md"; then
  echo "soak-watch still invokes the retired release graph" >&2
  exit 1
fi

echo "ok last-stack-lastdb-canary-dogfood"
