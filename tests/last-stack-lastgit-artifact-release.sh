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
  | grep -q -- 'ci watch --repo last-stack --context artifact-release --ref refs/heads/main --keep-alive' \
  || fail "artifact release LaunchAgent does not watch LastGit main"

cat > "$fake_lastgit" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$LASTGIT_TEST_CALLS"
if [ "${1:-}" = artifact ] && [ "${2:-}" = publish ]; then
  jq -n --arg digest "$(printf 'd%.0s' {1..64})" --arg oid "$LASTGIT_CI_OID" \
    '{app:"last-stack",source_oid:$oid,manifest_digest:$digest}'
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
publish_line="$(sed -n '1p' "$calls")"
promote_line="$(sed -n '2p' "$calls")"
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

jq -e '
  .apps[] | select(.app == "last-stack")
  | .gate == "lastgit"
    and .gate_main == "lastdb:///last-stack#main"
    and .track_gate_main == false
' "$ROOT/config/host-track/apps.json" >/dev/null \
  || fail "host-track does not report the LastGit main source"

printf 'ok: LastGit artifact release publishes and promotes stable\n'
