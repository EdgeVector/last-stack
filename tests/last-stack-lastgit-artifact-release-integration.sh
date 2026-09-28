#!/usr/bin/env bash
# End-to-end proof for merge -> LastGit watcher -> stable -> Host Track.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-artifact-release-e2e.XXXXXX")"
node_home="$(mktemp -d /tmp/ls-ar-node.XXXXXX)"
node_pid=""
required_pid=""
release_pid=""

cleanup() {
  for pid in "$release_pid" "$required_pid" "$node_pid"; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  chmod -R u+w "$tmp" 2>/dev/null || true
  chmod -R u+w "$node_home" 2>/dev/null || true
  rm -rf "$tmp"
  rm -rf "$node_home"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  for log in "$tmp"/*.log; do
    [ -f "$log" ] || continue
    printf '%s\n' "--- $log" >&2
    tail -80 "$log" >&2 || true
  done
  exit 1
}

lastgit_bin="$(command -v lastgit || true)"
remote_helper="$(command -v git-remote-lastdb || true)"
lastdbd_bin="$(command -v lastdbd || true)"
schema_map="${LASTGIT_SCHEMA_MAP:-$HOME/.lastgit/schema-map.json}"
[ -x "$lastgit_bin" ] || fail "lastgit is not installed"
[ -x "$remote_helper" ] || fail "git-remote-lastdb is not installed"
[ -x "$lastdbd_bin" ] || fail "lastdbd is not installed"
[ -f "$schema_map" ] || fail "LastGit schema map is missing: $schema_map"
command -v jq >/dev/null 2>&1 || fail "jq is not installed"
command -v curl >/dev/null 2>&1 || fail "curl is not installed"

socket="$node_home/data/folddb.sock"
full_socket="$node_home/data/folddb-full.sock"
artifact_root="$tmp/artifacts"
pack_root="$tmp/packs"
test_home="$tmp/home"
source_repo="$tmp/source"
registry="$tmp/registry.json"
mkdir -p "$node_home" "$test_home/.local/bin" "$test_home/.lastgit" "$source_repo" "$pack_root"
ln -s "$lastgit_bin" "$test_home/.local/bin/lastgit"
ln -s "$remote_helper" "$test_home/.local/bin/git-remote-lastdb"
cp "$schema_map" "$test_home/.lastgit/schema-map.json"

primary_socket="$HOME/.lastdb/data/folddb.sock"
[ "$socket" != "$primary_socket" ] || fail "test resolved the primary LastDB socket"

(
  unset SENTRY_DSN OBS_SENTRY_DSN RUST_SENTRY_DSN SENTRY_URL 2>/dev/null || true
  export HOME="$test_home" LASTDB_HOME="$node_home" FOLDDB_HOME="$node_home"
  export FOLDDB_DISABLE_KEYCHAIN=1
  exec "$lastdbd_bin" --data-dir "$node_home"
) >"$tmp/node.log" 2>&1 &
node_pid=$!

ready=""
for _ in $(seq 1 120); do
  if [ -S "$socket" ] && [ -S "$full_socket" ]; then
    ready=1
    break
  fi
  kill -0 "$node_pid" 2>/dev/null || fail "throwaway lastdbd exited before its sockets appeared"
  sleep 0.25
done
[ -n "$ready" ] || fail "throwaway LastDB sockets did not appear"

user_hash="$(curl -fsS --unix-socket "$socket" -H 'Host: localhost' \
  http://x/api/system/auto-identity | jq -r '.user_hash // empty')"
[ -n "$user_hash" ] || fail "throwaway LastDB returned no user hash"
jq -c '{schemas:[.schemas[]]}' "$schema_map" >"$tmp/schema-load-request.json"
curl -fsS --unix-socket "$full_socket" -H 'Host: localhost' \
  -H "X-User-Hash: $user_hash" -H 'Content-Type: application/json' \
  --data-binary @"$tmp/schema-load-request.json" http://x/api/schemas/load \
  >"$tmp/schema-load.json"

# Two derived index schemas are optional on a fresh Mini. Every schema that
# serves the watcher, CI verdict, ref, repository, or artifact gate must load.
if ! jq -e --slurpfile map "$schema_map" '
  ($map[0].schemas | to_entries | map({key:.value,value:.key}) | from_entries) as $names
  | [(.failed_schemas // [])[]
      | split(" ")[0]
      | ($names[.] // "UNKNOWN")
      | select(. != "LastgitPackBlobIndex" and . != "LastgitRepoIndex")]
  | length == 0
' "$tmp/schema-load.json" >/dev/null; then
  fail "required LastGit schemas did not load: $(jq -c '.failed_schemas // .' "$tmp/schema-load.json")"
fi

git init -q -b main "$source_repo"
git -C "$source_repo" config user.email artifact-release@test.local
git -C "$source_repo" config user.name "artifact release integration"
ssh-keygen -q -t ed25519 -N '' -C artifact-release@test.local -f "$tmp/signing-key"
printf 'artifact-release@test.local namespaces="git" %s\n' \
  "$(cat "$tmp/signing-key.pub")" >"$tmp/allowed-signers"
git -C "$source_repo" config gpg.format ssh
git -C "$source_repo" config user.signingkey "$tmp/signing-key.pub"
git -C "$source_repo" config gpg.ssh.allowedSignersFile "$tmp/allowed-signers"
git -C "$source_repo" config commit.gpgsign true

mkdir -p "$source_repo/.lastgit"
cp "$ROOT/.lastgit/artifact-release.sh" "$source_repo/.lastgit/artifact-release.sh"
cp "$ROOT/.lastgit/artifacts.json" "$source_repo/.lastgit/artifacts.json"
cat >"$source_repo/.lastgit/ci-required.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "ci-required passed for $LASTGIT_CI_OID"
SH
chmod +x "$source_repo/.lastgit/artifact-release.sh" "$source_repo/.lastgit/ci-required.sh"

for path in config docs harness hooks instructions lib routines skills templates launchd; do
  mkdir -p "$source_repo/$path"
  printf '%s fixture\n' "$path" >"$source_repo/$path/payload.txt"
done
mkdir -p "$source_repo/bin"
cat >"$source_repo/setup" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo setup-ok
SH
cat >"$source_repo/bin/host-track" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo fixture-host-track
SH
cat >"$source_repo/bin/probe" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo probe-ok
SH
chmod +x "$source_repo/setup" "$source_repo/bin/host-track" "$source_repo/bin/probe"
printf 'integration-v1\n' >"$source_repo/VERSION"
git -C "$source_repo" add -A
git -C "$source_repo" commit -S -qm 'initial release fixture'
initial_oid="$(git -C "$source_repo" rev-parse HEAD)"
git -C "$source_repo" remote add origin lastdb:///last-stack

lastgit_env=(
  env HOME="$test_home"
  PATH="$test_home/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
  LASTGIT_SOCKET="$socket"
  LASTGIT_PACK_CAS_DIR="$pack_root"
  LASTGIT_ARTIFACT_ROOT="$artifact_root"
  LASTGIT_BIN="$lastgit_bin"
  LAST_STACK_ARTIFACT_RELEASE_RETRY_SECONDS=1
  LAST_STACK_ARTIFACT_RELEASE_MAX_ATTEMPTS=90
)

"${lastgit_env[@]}" git -C "$source_repo" push -q origin main

"${lastgit_env[@]}" "$lastgit_bin" ci watch --repo last-stack \
  --context ci-required --ref refs/heads/main --keep-alive --no-state-file \
  --scratch-dir "$tmp/ci-required-scratch" \
  --allow-duplicate-coverage --timeout-ms 120000 >"$tmp/ci-required.log" 2>&1 &
required_pid=$!
"${lastgit_env[@]}" "$lastgit_bin" ci watch --repo last-stack \
  --context artifact-release --ref refs/heads/main --keep-alive --no-state-file \
  --scratch-dir "$tmp/artifact-release-scratch" \
  --allow-duplicate-coverage --timeout-ms 120000 >"$tmp/artifact-release.log" 2>&1 &
release_pid=$!

wait_for_stable_oid() {
  local expected="$1" observed=""
  # A cold throwaway node can spend about one minute on its first pack-cover
  # reindex. Keep this bound above the watcher's 120-second CI timeout.
  for _ in $(seq 1 720); do
    kill -0 "$required_pid" 2>/dev/null || fail "ci-required watcher exited"
    kill -0 "$release_pid" 2>/dev/null || fail "artifact-release watcher exited"
    observed="$("${lastgit_env[@]}" "$lastgit_bin" artifact resolve \
      --app last-stack --channel stable --root "$artifact_root" --json 2>/dev/null \
      | jq -r '.source_oid // empty' 2>/dev/null || true)"
    [ "$observed" = "$expected" ] && return 0
    sleep 0.25
  done
  fail "stable did not resolve to $expected; observed ${observed:-none}"
}

# Let both real watchers process the existing main event before the merge.
wait_for_stable_oid "$initial_oid"

git -C "$source_repo" switch -q -c release-change
printf 'integration-v2\n' >"$source_repo/VERSION"
git -C "$source_repo" add VERSION
git -C "$source_repo" commit -S -qm 'release fixture v2'
git -C "$source_repo" switch -q main
git -C "$source_repo" merge -q --no-ff release-change -m 'merge release fixture v2'
merge_oid="$(git -C "$source_repo" rev-parse HEAD)"
[ "$(git -C "$source_repo" rev-list --parents -n 1 "$merge_oid" | wc -w | tr -d ' ')" = 3 ] \
  || fail "fixture did not create a real merge commit"
"${lastgit_env[@]}" git -C "$source_repo" push -q origin main

wait_for_stable_oid "$merge_oid"

resolved_json="$("${lastgit_env[@]}" "$lastgit_bin" artifact resolve \
  --app last-stack --channel stable --root "$artifact_root" --json)"
printf '%s\n' "$resolved_json" | jq -e --arg oid "$merge_oid" '
  .app == "last-stack" and .source_oid == $oid
  and (.manifest_digest | test("^[0-9a-f]{64}$"))
' >/dev/null || fail "resolved stable manifest does not name the merge"
stable_digest="$(printf '%s\n' "$resolved_json" | jq -r '.manifest_digest')"

# Replay an older release after the merge reaches stable. It can publish an
# immutable candidate, but it must not replace the newer stable channel head.
superseded_source="$tmp/superseded-source"
git -C "$source_repo" worktree add -q --detach "$superseded_source" "$initial_oid"
(
  cd "$superseded_source"
  "${lastgit_env[@]}" \
    LASTGIT_CI_CONTEXT=artifact-release \
    LASTGIT_CI_REPO=last-stack \
    LASTGIT_CI_OID="$initial_oid" \
    .lastgit/artifact-release.sh
) >"$tmp/superseded-release.log" 2>&1
grep -q "skip stable promotion for superseded oid=$initial_oid current_main=$merge_oid" \
  "$tmp/superseded-release.log" \
  || fail "older release did not report its superseded main tip"
resolved_after_replay="$("${lastgit_env[@]}" "$lastgit_bin" artifact resolve \
  --app last-stack --channel stable --root "$artifact_root" --json)"
printf '%s\n' "$resolved_after_replay" | jq -e --arg oid "$merge_oid" \
  '.source_oid == $oid' >/dev/null \
  || fail "older release replaced the newer stable channel head: $resolved_after_replay"

ref_oid="$("${lastgit_env[@]}" "$lastgit_bin" ref last-stack main | cut -f1)"
[ "$ref_oid" = "$merge_oid" ] || fail "LastGit main ref does not name the merge"
ci_required_json="$("${lastgit_env[@]}" "$lastgit_bin" ci status "$merge_oid" \
  --repo last-stack --context ci-required --json)"
ci_release_json="$("${lastgit_env[@]}" "$lastgit_bin" ci status "$merge_oid" \
  --repo last-stack --context artifact-release --json)"
printf '%s\n' "$ci_required_json" | jq -e '
  .context == "ci-required" and .state == "success"
' >/dev/null || fail "ci-required watcher did not pass for the merge: $ci_required_json"
printf '%s\n' "$ci_release_json" | jq -e '
  .context == "artifact-release" and .state == "success"
' >/dev/null || fail "artifact-release watcher did not pass for the merge: $ci_release_json"

cat >"$registry" <<JSON
{
  "defaults": {
    "install_mode": "artifact",
    "artifact_channel": "stable",
    "artifact_root": "$artifact_root",
    "safe_upgrade": {"soak_hours": 0}
  },
  "apps": [{
    "app": "last-stack",
    "kind": "artifact skill-pack",
    "command": "probe",
    "gate": "lastgit",
    "gate_main": "lastdb:///last-stack#main",
    "track_gate_main": false,
    "artifact_app": "last-stack",
    "artifact_channel": "stable",
    "install_root": "$test_home/apps/last-stack",
    "links": [{"source":"bin/probe","target":"$test_home/.local/bin/probe"}],
    "safe_upgrade": {
      "soak_hours": 0,
      "probes": [{"argv":["bin/probe"],"output_matches":"probe-ok","attempts":1}]
    }
  }]
}
JSON

host_track_env=(
  env HOME="$test_home"
  PATH="$test_home/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
  LASTGIT_SOCKET="$socket"
  LASTGIT_ARTIFACT_ROOT="$artifact_root"
  HOST_TRACK_REGISTRY="$registry"
  HOST_TRACK_STAMP_DIR="$tmp/stamps"
  HOST_TRACK_ARTIFACT_ROOT="$artifact_root"
  HOST_TRACK_INSTALL_ROOT="$test_home/apps"
  HOST_TRACK_LOCK_DIR="$tmp/locks"
)
"${host_track_env[@]}" "$ROOT/bin/host-track" refresh last-stack \
  >"$tmp/host-track-refresh.log" 2>&1
status_json="$("${host_track_env[@]}" "$ROOT/bin/host-track" status --json last-stack)"
printf '%s\n' "$status_json" | jq -e --arg oid "$merge_oid" --arg digest "$stable_digest" '
  .host_head == $oid
  and .gate_head == $oid
  and .manifest_digest == $digest
  and .channel_manifest_digest == $digest
  and .stale == false
  and .main_unpublished == false
  and .freshness == "fresh"
' >/dev/null || fail "Host Track heads are not fresh at the released merge: $status_json"
"$test_home/.local/bin/probe" | grep -qx probe-ok \
  || fail "Host Track did not activate the stable artifact"

printf 'ok: real LastGit watchers released merge %s and Host Track installed the same head\n' \
  "$merge_oid"
