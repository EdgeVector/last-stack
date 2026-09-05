#!/usr/bin/env bash
set -euo pipefail

# A HEAL-node-spawned agent exports the ambient live-loom contract; scrub it
# so every invocation below controls its own LOOM_* env.
unset LOOM_LIVE LOOM_CANARY_LIVE LOOM_CANARY_RED_LIVE \
  LOOM_EXEC_ID LOOM_INPUT LOOM_IDEMPOTENCY_KEY LOOM_SCRIPTS \
  LASTDB_SAFE_UPGRADE_EXPECTED_SOURCE_OID \
  LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_PATH \
  LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_PATH \
  LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_VERSION \
  LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_VERSION \
  LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_SHA256 \
  LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_SHA256 \
  LASTDB_SAFE_UPGRADE_EXPECTED_ARTIFACT_DIGEST \
  LASTDB_DEV_STAMP_RECEIPT || true

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
FRESH="$ROOT/lib/canary-loom/lastdb-candidate-freshness.py"
STEP="$ROOT/lib/canary-loom/loom-safe-upgrade-step.sh"
GRAPH="$ROOT/lib/canary-loom/lastdb-safe-upgrade.json"
LAUNCHER="$ROOT/bin/last-stack-safe-upgrade-loom"
DRIVER="$ROOT/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh"
DOGFOOD="$ROOT/bin/last-stack-lastdb-canary-dogfood"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

bash -n "$STEP"
bash -n "$LAUNCHER"
bash -n "$DRIVER"
python3 -m py_compile "$FRESH" "$DOGFOOD"

[ "$(jq -r .version "$GRAPH")" = "6" ] || fail "safe-upgrade graph version did not advance"
grep -q 'SAFE_UPGRADE_PROTOCOL_VERSION="6"' "$LAUNCHER" \
  || fail "launcher key namespace does not match safe-upgrade graph version 6"
[ "$(jq -r '.states.DECIDE.map.current' "$GRAPH")" = "DONE" ] \
  || fail "equal candidate does not finish as a no-op"
probe_timeout="$(jq -er '.states.PROBE.timeout_sec | numbers' "$GRAPH")"
cutover_timeout="$(jq -er '.states.CUTOVER.timeout_sec | numbers' "$GRAPH")"
[ "$cutover_timeout" -ge "$probe_timeout" ] \
  || fail "CUTOVER timeout must cover every check that PROBE runs"
[ "$cutover_timeout" -ge 7200 ] \
  || fail "CUTOVER timeout cannot cover the measured real-data safety pass"
grep -q 'timeout=node_timeout("PROBE")' "$STEP" \
  || fail "PROBE wrapper timeout does not come from the graph"
grep -q 'timeout=node_timeout("CUTOVER")' "$STEP" \
  || fail "CUTOVER wrapper timeout does not come from the graph"
if grep -Eq 'timeout=(3600|7200)' "$STEP"; then
  fail "safe-upgrade wrapper retains a timeout separate from the graph"
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-safe-upgrade-loom.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
tmp="$(CDPATH= cd -- "$tmp" && pwd -P)"

repo="$tmp/fold"
git init -q "$repo"
base_branch="$(git -C "$repo" symbolic-ref --short HEAD)"
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name test
git -C "$repo" commit -q --allow-empty -m a
oid_a="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" commit -q --allow-empty -m b
oid_b="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -q -b side "$oid_a"
git -C "$repo" commit -q --allow-empty -m side
oid_side="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -q "$base_branch"

make_candidate() {
  local dir="$1" version="$2" oid="$3"
  mkdir -p "$dir"
  printf '#!/usr/bin/env bash\nprintf "lastdbd %s\\n"\n' "$version" >"$dir/lastdbd"
  printf '#!/usr/bin/env bash\nprintf "lastdb %s\\n"\n' "$version" >"$dir/lastdb"
  chmod 755 "$dir/lastdbd" "$dir/lastdb"
  if [ -n "$oid" ]; then
    printf '{"source_git_oid":"%s"}\n' "$oid" >"$dir/manifest.json"
  fi
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

artifact_digest() {
  printf '%s\0%s\0%s\0%s\0%s\0%s\0%s' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" \
    | shasum -a 256 | awk '{print $1}'
}

candidate_input() {
  local dir="$1" oid="$2" version daemon cli daemon_sha cli_sha digest
  daemon="$(CDPATH= cd -- "$dir" && printf '%s/lastdbd\n' "$(pwd -P)")"
  cli="$(CDPATH= cd -- "$dir" && printf '%s/lastdb\n' "$(pwd -P)")"
  version="$("$daemon" --version | awk '{print $NF}')"
  daemon_sha="$(sha256_file "$daemon")"
  cli_sha="$(sha256_file "$cli")"
  digest="$(artifact_digest \
    "$oid" "$daemon" "$cli" "$daemon_sha" "$cli_sha" "$version" "$version")"
  jq -cn \
    --arg candidate "$daemon" \
    --arg candidate_cli "$cli" \
    --arg version "$version" \
    --arg lastdbd_version "$version" \
    --arg lastdb_version "$version" \
    --arg lastdbd_sha256 "$daemon_sha" \
    --arg lastdb_sha256 "$cli_sha" \
    --arg source_git_oid "$oid" \
    --arg candidate_artifact_digest "$digest" \
    --arg safe_upgrade_protocol_version 6 \
    '{candidate:$candidate,candidate_cli:$candidate_cli,version:$version,lastdbd_version:$lastdbd_version,lastdb_version:$lastdb_version,lastdbd_sha256:$lastdbd_sha256,lastdb_sha256:$lastdb_sha256,source_git_oid:$source_git_oid,candidate_artifact_digest:$candidate_artifact_digest,safe_upgrade_protocol_version:$safe_upgrade_protocol_version}'
}

make_candidate "$tmp/current-a" "0.23.3-1-g${oid_a:0:12}" "$oid_a"
make_candidate "$tmp/current-b" "0.23.3-2-g${oid_b:0:12}" "$oid_b"
make_candidate "$tmp/candidate-a" "0.23.3-1-g${oid_a:0:12}" "$oid_a"
make_candidate "$tmp/candidate-b" "0.23.3-2-g${oid_b:0:12}" "$oid_b"
make_candidate "$tmp/candidate-side" "0.23.3-2-g${oid_side:0:12}" "$oid_side"
make_candidate "$tmp/candidate-unknown" "0.23.3-release" ""

out="$(python3 "$FRESH" \
  --candidate "$tmp/candidate-a/lastdbd" \
  --current-bin "$tmp/current-a/lastdbd" \
  --git-dir "$repo")"
[ "$(printf '%s\n' "$out" | jq -r .relation)" = "current" ] \
  || fail "equal candidate was not current: $out"

out="$(python3 "$FRESH" \
  --candidate "$tmp/candidate-b/lastdbd" \
  --current-bin "$tmp/current-a/lastdbd" \
  --git-dir "$repo")"
[ "$(printf '%s\n' "$out" | jq -r .relation)" = "forward" ] \
  || fail "descendant candidate was not forward: $out"

set +e
out="$(python3 "$FRESH" \
  --candidate "$tmp/candidate-a/lastdbd" \
  --current-bin "$tmp/current-b/lastdbd" \
  --git-dir "$repo")"
rc=$?
set -e
[ "$rc" -eq 1 ] && [ "$(printf '%s\n' "$out" | jq -r .relation)" = "stale" ] \
  || fail "older candidate did not fail stale: rc=$rc out=$out"

set +e
out="$(python3 "$FRESH" \
  --candidate "$tmp/candidate-side/lastdbd" \
  --current-bin "$tmp/current-b/lastdbd" \
  --git-dir "$repo")"
rc=$?
set -e
[ "$rc" -eq 1 ] && [ "$(printf '%s\n' "$out" | jq -r .relation)" = "diverged" ] \
  || fail "divergent candidate did not fail closed: rc=$rc out=$out"

set +e
out="$(python3 "$FRESH" \
  --candidate "$tmp/candidate-unknown/lastdbd" \
  --current-bin "$tmp/current-b/lastdbd" \
  --git-dir "$repo")"
rc=$?
set -e
[ "$rc" -eq 1 ] && [ "$(printf '%s\n' "$out" | jq -r .relation)" = "unknown" ] \
  || fail "unknown ancestry did not fail closed: rc=$rc out=$out"

mock_home="$tmp/home"
skill_dir="$mock_home/.last-stack/skills/lastdb-safe-upgrade/scripts"
mkdir -p "$skill_dir"
safe_log="$tmp/safe.log"
cat >"$skill_dir/safe-upgrade-lastdb.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'args=%s marker=%s exec=%s daemon=%s cli=%s daemon_sha=%s cli_sha=%s source=%s receipt=%s\n' \
  "$*" "${LASTDB_SAFE_UPGRADE_VIA_LOOM:-}" "${LOOM_EXEC_ID:-}" \
  "${LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_PATH:-}" \
  "${LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_PATH:-}" \
  "${LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_SHA256:-}" \
  "${LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_SHA256:-}" \
  "${LASTDB_SAFE_UPGRADE_EXPECTED_SOURCE_OID:-}" \
  "${LASTDB_DEV_STAMP_RECEIPT:-}" >>"${SAFE_LOG:?}"
case " $* " in
  *" --probe-only "*)
    case "${SAFE_MOCK_PROBE:-green}" in
      green) printf 'VERDICT: GREEN_PROBE_ONLY\n' ;;
      false-green)
        # Real drivers cat sub-probe output: the smoke stage prints its own
        # "VERDICT: GREEN" before a later bar fails RED with rc=1.
        printf 'VERDICT: GREEN\n'
        printf 'VERDICT: RED\n'
        printf 'REASON: candidate fails the latency bar\n'
        exit 1
        ;;
      rc-red)
        printf 'VERDICT: GREEN_PROBE_ONLY\n'
        exit 1
        ;;
    esac
    ;;
  *)
    [ "${LASTDB_SAFE_UPGRADE_VIA_LOOM:-}" = "1" ] || exit 70
    [ -n "${LOOM_EXEC_ID:-}" ] || exit 71
    printf 'VERDICT: GREEN\n'
    ;;
esac
SH
chmod 755 "$skill_dir/safe-upgrade-lastdb.sh"

stale_input="$(candidate_input "$tmp/candidate-a" "$oid_a")"
out="$(HOME="$mock_home" \
  LOOM_LIVE=1 \
  LOOM_INPUT="$stale_input" \
  LASTDB_SAFE_UPGRADE_CURRENT_BIN="$tmp/current-b/lastdbd" \
  LASTDB_SAFE_UPGRADE_FOLD_GIT_DIR="$repo" \
  "$STEP" PROBE)"
printf '%s\n' "$out" | grep -q '"verdict":"red"' || fail "stale graph probe was not red"
printf '%s\n' "$out" | grep -q '"freshness":"stale"' || fail "stale relation was not recorded"
[ ! -e "$safe_log" ] || fail "stale graph reached the safe-upgrade driver"

equal_input="$(candidate_input "$tmp/candidate-b" "$oid_b")"
out="$(HOME="$mock_home" \
  LOOM_LIVE=1 \
  LOOM_INPUT="$equal_input" \
  LASTDB_SAFE_UPGRADE_CURRENT_BIN="$tmp/current-b/lastdbd" \
  LASTDB_SAFE_UPGRADE_FOLD_GIT_DIR="$repo" \
  "$STEP" PROBE)"
printf '%s\n' "$out" | grep -q '"verdict":"current"' || fail "equal graph probe did not no-op"
[ ! -e "$safe_log" ] || fail "equal graph probe reached the safe-upgrade driver"

forward_input="$(candidate_input "$tmp/candidate-b" "$oid_b")"

# Item fanout cannot override the immutable tuple that the parent supplies.
conflict_input="$(printf '%s' "$forward_input" | jq -c \
  '. + {item:(. + {lastdb_sha256:"0000000000000000000000000000000000000000000000000000000000000000"})}')"
set +e
out="$(HOME="$mock_home" LOOM_LIVE=1 LOOM_INPUT="$conflict_input" "$STEP" PROBE 2>&1)"
rc=$?
set -e
[ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'immutable item/context mismatch' \
  || fail "item/top-level candidate conflict did not fail closed: rc=$rc out=$out"
[ ! -e "$safe_log" ] || fail "immutable input conflict reached the safe-upgrade driver"

# The step recomputes the digest. A caller cannot supply a valid tuple with a
# digest from another path or protocol input.
bad_digest_input="$(printf '%s' "$forward_input" | jq -c \
  '.candidate_artifact_digest="0000000000000000000000000000000000000000000000000000000000000000"')"
out="$(HOME="$mock_home" LOOM_LIVE=1 LOOM_INPUT="$bad_digest_input" "$STEP" PROBE)"
printf '%s\n' "$out" | grep -q 'exact candidate binding refused' \
  || fail "mismatched artifact digest did not fail closed: $out"
printf '%s\n' "$out" | grep -q 'artifact digest does not match' \
  || fail "artifact digest refusal did not name the tuple mismatch: $out"
[ ! -e "$safe_log" ] || fail "mismatched artifact digest reached the safe-upgrade driver"

legacy_protocol_input="$(printf '%s' "$forward_input" | jq -c \
  '.safe_upgrade_protocol_version="5"')"
out="$(HOME="$mock_home" LOOM_LIVE=1 LOOM_INPUT="$legacy_protocol_input" "$STEP" PROBE)"
printf '%s\n' "$out" | grep -q 'safe-upgrade protocol version is not 6' \
  || fail "legacy safe-upgrade protocol was not refused: $out"
[ ! -e "$safe_log" ] || fail "legacy safe-upgrade protocol reached the driver"

# Any byte change after kickoff fails before ancestry or the driver. This test
# mutates only the paired CLI, which a daemon-only execution key would miss.
cp "$tmp/candidate-b/lastdb" "$tmp/candidate-b/lastdb.saved"
printf '# byte change after kickoff\n' >>"$tmp/candidate-b/lastdb"
set +e
out="$(HOME="$mock_home" LOOM_LIVE=1 LOOM_INPUT="$forward_input" "$STEP" PROBE 2>&1)"
rc=$?
set -e
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'exact candidate binding refused' \
  || fail "paired CLI byte change was not refused: rc=$rc out=$out"
printf '%s\n' "$out" | grep -q 'candidate pair bytes changed' \
  || fail "paired CLI byte refusal did not name changed bytes: $out"
[ ! -e "$safe_log" ] || fail "changed paired CLI reached the safe-upgrade driver"
mv "$tmp/candidate-b/lastdb.saved" "$tmp/candidate-b/lastdb"
chmod 755 "$tmp/candidate-b/lastdb"

# Forward probe, driver green (rc=0, final verdict GREEN_PROBE_ONLY).
out="$(HOME="$mock_home" \
  SAFE_LOG="$safe_log" \
  LOOM_LIVE=1 \
  LOOM_EXEC_ID=lx-test-probe-green \
  LOOM_INPUT="$forward_input" \
  LASTDB_SAFE_UPGRADE_CURRENT_BIN="$tmp/current-a/lastdbd" \
  LASTDB_SAFE_UPGRADE_FOLD_GIT_DIR="$repo" \
  "$STEP" PROBE)"
printf '%s\n' "$out" | grep -q '"verdict":"green"' || fail "green probe was not green: $out"

# A long successful probe can outlive the caller's drive window. A repeated
# request for the same immutable execution must reuse the stored result. The
# CUTOVER node reruns the complete safe-upgrade driver before any live change.
safe_log_lines_before="$(wc -l <"$safe_log" | tr -d ' ')"
resumed_green_input="$(printf '%s\n' "$forward_input" | jq -c '. + {verdict:"green",probe_rc:0}')"
out="$(HOME="$mock_home" \
  SAFE_LOG="$safe_log" \
  SAFE_MOCK_PROBE=false-green \
  LOOM_LIVE=1 \
  LOOM_EXEC_ID=lx-test-probe-resume-green \
  LOOM_INPUT="$resumed_green_input" \
  LASTDB_SAFE_UPGRADE_CURRENT_BIN="$tmp/current-a/lastdbd" \
  LASTDB_SAFE_UPGRADE_FOLD_GIT_DIR="$repo" \
  "$STEP" PROBE)"
printf '%s\n' "$out" | grep -q 'reused exact stored green result' \
  || fail "stored green probe was not reused: $out"
if printf '%s\n' "$out" | grep -q 'LOOM_CONTEXT_PATCH'; then
  fail "stored green probe wrote another context patch: $out"
fi
safe_log_lines_after="$(wc -l <"$safe_log" | tr -d ' ')"
[ "$safe_log_lines_after" = "$safe_log_lines_before" ] \
  || fail "stored green probe reran the safe-upgrade driver"

# JSON false compares equal to zero in Python. Exact type checks must reject
# it so a malformed prior receipt cannot skip the probe driver.
resumed_false_input="$(printf '%s\n' "$forward_input" | jq -c '. + {verdict:"green",probe_rc:false}')"
out="$(HOME="$mock_home" \
  SAFE_LOG="$safe_log" \
  SAFE_MOCK_PROBE=green \
  LOOM_LIVE=1 \
  LOOM_EXEC_ID=lx-test-probe-resume-false \
  LOOM_INPUT="$resumed_false_input" \
  LASTDB_SAFE_UPGRADE_CURRENT_BIN="$tmp/current-a/lastdbd" \
  LASTDB_SAFE_UPGRADE_FOLD_GIT_DIR="$repo" \
  "$STEP" PROBE)"
printf '%s\n' "$out" | grep -q 'LOOM_CONTEXT_PATCH' \
  || fail "boolean probe receipt skipped the driver: $out"
safe_log_lines_after_false="$(wc -l <"$safe_log" | tr -d ' ')"
[ "$safe_log_lines_after_false" -eq $((safe_log_lines_before + 1)) ] \
  || fail "boolean probe receipt did not rerun the driver"

# Incident lx-20260830T203912: the smoke stage's own "VERDICT: GREEN" inside a
# rc=1 red probe must not read as green — the false green sent a RED candidate
# into CUTOVER.
out="$(HOME="$mock_home" \
  SAFE_LOG="$safe_log" \
  SAFE_MOCK_PROBE=false-green \
  LOOM_LIVE=1 \
  LOOM_EXEC_ID=lx-test-probe-red \
  LOOM_INPUT="$forward_input" \
  LASTDB_SAFE_UPGRADE_CURRENT_BIN="$tmp/current-a/lastdbd" \
  LASTDB_SAFE_UPGRADE_FOLD_GIT_DIR="$repo" \
  "$STEP" PROBE)"
printf '%s\n' "$out" | grep -q '"verdict":"red"' \
  || fail "smoke-section GREEN inside a rc=1 probe was not red: $out"
printf '%s\n' "$out" | grep -q 'REASON: candidate fails the latency bar' \
  || fail "red probe did not carry the driver REASON line: $out"
[ -s "$tmp/candidate-b/probe-fail-lx-test-probe-red.log" ] \
  || fail "red probe left no durable evidence file"

# A driver that prints a green verdict but exits non-zero is still red.
out="$(HOME="$mock_home" \
  SAFE_LOG="$safe_log" \
  SAFE_MOCK_PROBE=rc-red \
  LOOM_LIVE=1 \
  LOOM_EXEC_ID=lx-test-probe-rc \
  LOOM_INPUT="$forward_input" \
  LASTDB_SAFE_UPGRADE_CURRENT_BIN="$tmp/current-a/lastdbd" \
  LASTDB_SAFE_UPGRADE_FOLD_GIT_DIR="$repo" \
  "$STEP" PROBE)"
printf '%s\n' "$out" | grep -q '"verdict":"red"' \
  || fail "green text with rc=1 was not red: $out"

HOME="$mock_home" \
  SAFE_LOG="$safe_log" \
  LOOM_LIVE=1 \
  LOOM_EXEC_ID=lx-test-safe-upgrade \
  LOOM_INPUT="$forward_input" \
  LASTDB_SAFE_UPGRADE_CURRENT_BIN="$tmp/current-a/lastdbd" \
  LASTDB_SAFE_UPGRADE_FOLD_GIT_DIR="$repo" \
  "$STEP" CUTOVER >/dev/null
grep -q 'marker=1 exec=lx-test-safe-upgrade' "$safe_log" \
  || fail "Loom did not mark the live driver call"
grep -q "daemon=$tmp/candidate-b/lastdbd cli=$tmp/candidate-b/lastdb" "$safe_log" \
  || fail "Loom did not pass the exact candidate paths to the driver"
grep -q "daemon_sha=$(sha256_file "$tmp/candidate-b/lastdbd") cli_sha=$(sha256_file "$tmp/candidate-b/lastdb") source=$oid_b" "$safe_log" \
  || fail "Loom did not pass both hashes and the source OID to the driver"
grep -q 'receipt=.*/lx-test-safe-upgrade-.*\.receipt' "$safe_log" \
  || fail "Loom did not isolate the DEV receipt by execution and pair hashes"

set +e
out="$("$DRIVER" --candidate "$tmp/candidate-b/lastdbd" --yes 2>&1)"
rc=$?
set -e
[ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q 'requires the Loom' \
  || fail "direct live driver bypass was not refused: rc=$rc out=$out"

dry_a="$(LASTDB_SAFE_UPGRADE_FOLD_GIT_DIR="$repo" \
  "$LAUNCHER" --candidate "$tmp/candidate-a/lastdbd" --source-git-oid "$oid_a" --dry-run --json)"
dry_b="$(LASTDB_SAFE_UPGRADE_FOLD_GIT_DIR="$repo" \
  "$LAUNCHER" --candidate "$tmp/candidate-b/lastdbd" --source-git-oid "$oid_b" --dry-run --json)"
[ "$(printf '%s\n' "$dry_a" | jq -r .graph)" = "lastdb-safe-upgrade" ] \
  || fail "launcher did not select the safe-upgrade graph"
version_a="$("$tmp/candidate-a/lastdbd" --version | awk '{print $NF}')"
version_b="$("$tmp/candidate-b/lastdbd" --version | awk '{print $NF}')"
digest_a="$(artifact_digest "$oid_a" "$tmp/candidate-a/lastdbd" "$tmp/candidate-a/lastdb" "$(sha256_file "$tmp/candidate-a/lastdbd")" "$(sha256_file "$tmp/candidate-a/lastdb")" "$version_a" "$version_a")"
digest_b="$(artifact_digest "$oid_b" "$tmp/candidate-b/lastdbd" "$tmp/candidate-b/lastdb" "$(sha256_file "$tmp/candidate-b/lastdbd")" "$(sha256_file "$tmp/candidate-b/lastdb")" "$version_b" "$version_b")"
[ "$(printf '%s\n' "$dry_a" | jq -r .key)" = "safe-upgrade-v6-$digest_a" ] \
  || fail "launcher key did not bind candidate A full tuple digest"
[ "$(printf '%s\n' "$dry_b" | jq -r .key)" = "safe-upgrade-v6-$digest_b" ] \
  || fail "launcher key did not bind candidate B full tuple digest"
[ "$(printf '%s\n' "$dry_a" | jq -r .candidate_artifact_digest)" = "$digest_a" ] \
  || fail "launcher output omitted candidate A artifact digest"
[ "$(printf '%s\n' "$dry_a" | jq -r .safe_upgrade_protocol_version)" = 6 ] \
  || fail "launcher output omitted safe-upgrade protocol v6"
key_a="$(printf '%s\n' "$dry_a" | jq -r .key)"
[ "${#digest_a}" -eq 64 ] && [ "${#key_a}" -eq 80 ] \
  || fail "launcher execution key is not fixed length"
[ "$(printf '%s\n' "$dry_a" | jq -r .key)" != "$(printf '%s\n' "$dry_b" | jq -r .key)" ] \
  || fail "different candidates reused one Loom key"

cp -R "$tmp/candidate-a" "$tmp/candidate-a-relocated"
dry_a_relocated="$(LASTDB_SAFE_UPGRADE_FOLD_GIT_DIR="$repo" \
  "$LAUNCHER" --candidate "$tmp/candidate-a-relocated/lastdbd" --source-git-oid "$oid_a" --dry-run --json)"
[ "$(printf '%s\n' "$dry_a" | jq -r .key)" != "$(printf '%s\n' "$dry_a_relocated" | jq -r .key)" ] \
  || fail "identical candidate bytes at a new canonical path reused one Loom key"

make_candidate "$tmp/candidate-a-cli-change" "0.23.3-1-g${oid_a:0:12}" "$oid_a"
printf '# distinct CLI bytes\n' >>"$tmp/candidate-a-cli-change/lastdb"
dry_a_cli_change="$(LASTDB_SAFE_UPGRADE_FOLD_GIT_DIR="$repo" \
  "$LAUNCHER" --candidate "$tmp/candidate-a-cli-change/lastdbd" --source-git-oid "$oid_a" --dry-run --json)"
[ "$(printf '%s\n' "$dry_a" | jq -r .key)" != "$(printf '%s\n' "$dry_a_cli_change" | jq -r .key)" ] \
  || fail "a paired CLI-only byte change reused the prior Loom execution key"

grep -q 'run_safe_upgrade_loom(candidate)' "$DOGFOOD" \
  || fail "legacy dogfood cutover does not route through Loom"
if grep -q 'cut_args = \["--yes"' "$DOGFOOD"; then
  fail "legacy dogfood retains a direct live driver call"
fi
if grep -q 'safe-upgrade-lastdb\.sh\|\["bash", skill, "--candidate", cand, "--yes"\]' \
  "$ROOT/lib/canary-loom/loom-canary-step.sh"; then
  fail "parent canary step retains an alternate live driver call"
fi
grep -q 'LASTDB_SAFE_UPGRADE_VIA_LOOM' "$DRIVER" \
  || fail "driver lacks the Loom live-cutover contract"
grep -q 'publish "\$defs/lastdb-safe-upgrade.json"' "$ROOT/bin/last-stack-canary-loom" \
  || fail "parent launcher does not publish the safe-upgrade child graph"
grep -q 'export_loom_run_deadline_for' "$ROOT/bin/last-stack-canary-loom" \
  || fail "parent launcher does not size LOOM_RUN_DEADLINE_SECS for the child"
grep -q 'export_loom_run_deadline_for lastdb-safe-upgrade' "$LAUNCHER" \
  || fail "safe-upgrade launcher does not size LOOM_RUN_DEADLINE_SECS"
grep -q 'last-stack-safe-upgrade-loom' "$ROOT/skills/lastdb-safe-upgrade/SKILL.md" \
  || fail "skill does not route live upgrades through Loom"

printf 'PASS: LastDB live safe upgrades are Loom-only and fail closed on stale ancestry\n'
