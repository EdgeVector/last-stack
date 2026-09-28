#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-artifact-release.XXXXXX")"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

release_script="$ROOT/.lastgit/artifact-release.sh"
plist="$ROOT/launchd/com.edgevector.lastgit-artifact-release-last-stack.plist"
calls="$tmp/lastgit.calls"
attempts="$tmp/promote-attempts"
fake_lastgit="$tmp/lastgit"

[ -x "$release_script" ] || fail "artifact release script is missing or not executable"
[ -f "$plist" ] || fail "artifact release LaunchAgent template is missing"

jq -e '
  .artifacts[]
  | select(.app == "last-stack")
  | .context == "artifact-release"
    and (.paths | index("VERSION") != null)
    and (.paths | index("setup") != null)
    and (.paths | index("bin") != null)
    and (.paths | index("skills") != null)
    and (.paths | index("launchd") != null)
' "$ROOT/.lastgit/artifacts.json" >/dev/null \
  || fail "artifact configuration does not bind the complete payload to artifact-release"

plutil -lint "$plist" >/dev/null || fail "artifact release LaunchAgent is invalid"
plutil -extract Label raw -o - "$plist" \
  | grep -qx 'com.edgevector.lastgit-artifact-release-last-stack' \
  || fail "artifact release LaunchAgent label is wrong"
plutil -extract ProgramArguments.2 raw -o - "$plist" \
  | grep -q -- 'ci watch --repo last-stack --context artifact-release --ref refs/heads/main' \
  || fail "artifact release LaunchAgent does not watch LastGit main"
plutil -extract ProgramArguments.2 raw -o - "$plist" \
  | grep -Fq -- "--scratch-dir \"\$HOME/.lastgit/ci-watch-scratch/artifact-release-last-stack\"" \
  || fail "artifact release LaunchAgent does not isolate its checkout scratch directory"

cat > "$fake_lastgit" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$LASTGIT_TEST_CALLS"
if [ "${1:-}" = artifact ] && [ "${2:-}" = publish ]; then
  jq -n --arg digest "$(printf 'd%.0s' {1..64})" --arg oid "$LASTGIT_CI_OID" \
    '{app:"last-stack",source_oid:$oid,manifest_digest:$digest}'
  exit 0
fi
if [ "${1:-}" = ref ] && [ "${2:-}" = last-stack ] && [ "${3:-}" = main ]; then
  jq -n --arg oid "${LASTGIT_TEST_MAIN_OID:-$LASTGIT_CI_OID}" \
    '{repo:"last-stack",name:"refs/heads/main",oid:$oid,source:"point"}'
  exit 0
fi
if [ "${1:-}" = artifact ] && [ "${2:-}" = promote ]; then
  count=0
  [ ! -f "$LASTGIT_TEST_ATTEMPTS" ] || count="$(cat "$LASTGIT_TEST_ATTEMPTS")"
  count=$((count + 1))
  printf '%s\n' "$count" > "$LASTGIT_TEST_ATTEMPTS"
  [ "$count" -ge 2 ] || exit 1
  printf 'ARTIFACT promote app=last-stack\n'
  exit 0
fi
exit 2
SH
chmod +x "$fake_lastgit"

oid="$(git -C "$ROOT" rev-parse HEAD)"
LASTGIT_BIN="$fake_lastgit" \
LASTGIT_CI_CONTEXT=artifact-release \
LASTGIT_CI_REPO=last-stack \
LASTGIT_CI_OID="$oid" \
LASTGIT_TEST_CALLS="$calls" \
LASTGIT_TEST_ATTEMPTS="$attempts" \
LAST_STACK_ARTIFACT_RELEASE_RETRY_SECONDS=0 \
LAST_STACK_ARTIFACT_RELEASE_MAX_ATTEMPTS=3 \
  "$release_script" > "$tmp/release.out"

[ "$(cat "$attempts")" = 2 ] || fail "release did not retry promotion"
publish_line="$(grep '^artifact publish ' "$calls")"
promote_line="$(grep '^artifact promote ' "$calls" | sed -n '1p')"
printf '%s\n' "$publish_line" | grep -q -- '^artifact publish ' \
  || fail "release did not publish before promotion"
printf '%s\n' "$publish_line" | grep -q -- '--app last-stack --repo last-stack' \
  || fail "release published with the wrong app or repo"
printf '%s\n' "$publish_line" | grep -q -- "--oid $oid" \
  || fail "release did not bind the manifest to the CI OID"
printf '%s\n' "$promote_line" | grep -q -- '^artifact promote ' \
  || fail "release did not promote after publication"
printf '%s\n' "$promote_line" | grep -q -- '--channel stable' \
  || fail "release did not promote the stable channel"
printf '%s\n' "$promote_line" | grep -q -- '--gate lastgit --context ci-required' \
  || fail "release did not use the LastGit required gate"
grep -q 'last-stack artifact release PASSED' "$tmp/release.out" \
  || fail "release did not report success"
[ "$(grep -c '^ref last-stack main --json$' "$calls")" = 2 ] \
  || fail "release did not recheck the LastGit main tip before each promotion attempt"

: > "$calls"
if LASTGIT_BIN="$fake_lastgit" \
  LASTGIT_CI_CONTEXT=ci-required \
  LASTGIT_CI_REPO=last-stack \
  LASTGIT_CI_OID="$oid" \
  LASTGIT_TEST_CALLS="$calls" \
  LASTGIT_TEST_ATTEMPTS="$attempts" \
  "$release_script" > /dev/null 2>&1; then
  fail "release accepted the wrong LastGit context"
fi
[ ! -s "$calls" ] || fail "wrong-context run changed artifact state"

: > "$calls"
: > "$attempts"
newer_oid="$(printf 'e%.0s' {1..40})"
LASTGIT_BIN="$fake_lastgit" \
LASTGIT_CI_CONTEXT=artifact-release \
LASTGIT_CI_REPO=last-stack \
LASTGIT_CI_OID="$oid" \
LASTGIT_TEST_MAIN_OID="$newer_oid" \
LASTGIT_TEST_CALLS="$calls" \
LASTGIT_TEST_ATTEMPTS="$attempts" \
LAST_STACK_ARTIFACT_RELEASE_RETRY_SECONDS=0 \
LAST_STACK_ARTIFACT_RELEASE_MAX_ATTEMPTS=3 \
  "$release_script" > "$tmp/superseded.out"
grep -q '^artifact publish ' "$calls" \
  || fail "superseded release did not publish its candidate"
grep -q '^ref last-stack main --json$' "$calls" \
  || fail "superseded release did not resolve the LastGit main tip"
if grep -q '^artifact promote ' "$calls"; then
  fail "superseded release moved the stable channel backward"
fi
[ ! -s "$attempts" ] || fail "superseded release attempted stable promotion"
grep -q "skip stable promotion for superseded oid=$oid current_main=$newer_oid" \
  "$tmp/superseded.out" \
  || fail "superseded release did not report why it skipped promotion"
grep -q 'last-stack artifact release PASSED (superseded)' "$tmp/superseded.out" \
  || fail "superseded release did not report success"

jq -e '
  .apps[] | select(.app == "last-stack")
  | .gate == "lastgit"
    and .gate_main == "lastdb:///last-stack#main"
    and .track_gate_main == false
' "$ROOT/config/host-track/apps.json" >/dev/null \
  || fail "host-track does not report the LastGit main source"

printf 'ok: LastGit artifact release publishes, promotes stable, and rejects rollback\n'
