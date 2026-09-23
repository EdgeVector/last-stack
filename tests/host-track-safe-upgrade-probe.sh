#!/usr/bin/env bash
# Probe-before-cutover: a RED candidate must not flip current/PATH.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

export HOME="$tmp/home"
export HOST_TRACK_REGISTRY="$tmp/registry.json"
export HOST_TRACK_STAMP_DIR="$tmp/stamps"
export HOST_TRACK_SOAK_FILE_CARD=0
export HOST_TRACK_PROBE_RETRY_DELAY_S=0
export PATH="$HOME/.local/bin:$tmp/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
mkdir -p "$HOME/.local/bin" "$tmp/bin" "$tmp/cas"

cat > "$HOME/post-install" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\t%s\n' "$HOST_TRACK_APP" "$HOST_TRACK_MANIFEST_DIGEST" > "$HOME/post-install-ran"
SH
chmod +x "$HOME/post-install"

cat > "$tmp/bin/lastgit" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = artifact ] && [ "${2:-}" = resolve ] || exit 2
shift 2
app="" channel="" root=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --app) app="$2"; shift 2 ;;
    --channel) channel="$2"; shift 2 ;;
    --root) root="$2"; shift 2 ;;
    --json) shift ;;
    *) exit 2 ;;
  esac
done
manifest="$root/channels/$app/$channel.json"
[ -f "$manifest" ] || exit 3
cat "$manifest"
SH
chmod +x "$tmp/bin/lastgit"

cat > "$HOST_TRACK_REGISTRY" <<'JSON'
{
  "defaults": {
    "install_mode": "artifact",
    "artifact_channel": "stable"
  },
  "apps": [
    {
      "app": "demo",
      "kind": "artifact-bundle",
      "command": "demo",
      "artifact_root": "$HOME/../cas",
      "install_root": "$HOME/apps/demo",
      "post_install": "$HOME/post-install",
      "links": [
        {"source": "bin/demo", "target": "$HOME/.local/bin/demo"}
      ],
      "safe_upgrade": {
        "probes": [
          {"argv": ["bin/demo"], "timeout_s": 10, "output_matches": "ok"}
        ],
        "latency": true
      },
      "notes": "probe-before-cutover fixture"
    }
  ]
}
JSON

publish_fixture() {
  local digest="$1" oid="$2" content="$3" payload sha size blob manifest
  payload="$tmp/payload"
  printf '%s\n' "$content" > "$payload"
  sha="$(shasum -a 256 "$payload" | awk '{print $1}')"
  size="$(wc -c < "$payload" | tr -d ' ')"
  blob="$tmp/cas/blobs/sha256/${sha:0:2}/$sha"
  mkdir -p "$(dirname "$blob")" "$tmp/cas/channels/demo" "$tmp/cas/manifests"
  cp "$payload" "$blob"
  manifest="$tmp/cas/manifests/$digest.json"
  jq -n \
    --arg digest "$digest" --arg oid "$oid" --arg sha "$sha" --argjson size "$size" \
    '{schema_version: 1, app: "demo", repo: "EdgeVector/demo", source_oid: $oid,
      platform: "test-arm64", created_at: "2026-07-21T00:00:00Z",
      files: [{path: "bin/demo", sha256: $sha, size: $size, mode: 493}],
      manifest_digest: $digest}' > "$manifest"
  cp "$manifest" "$tmp/cas/channels/demo/stable.json"
}

digest_good="$(printf 'a%.0s' {1..64})"
digest_bad="$(printf 'b%.0s' {1..64})"
digest_transient="$(printf 'c%.0s' {1..64})"
digest_shared="$(printf 'd%.0s' {1..64})"
digest_stall="$(printf 'e%.0s' {1..64})"
digest_slow="$(printf 'f%.0s' {1..64})"
oid_good="$(printf '1%.0s' {1..40})"
oid_bad="$(printf '2%.0s' {1..40})"
oid_transient="$(printf '3%.0s' {1..40})"
oid_shared="$(printf '4%.0s' {1..40})"
oid_stall="$(printf '5%.0s' {1..40})"
oid_slow="$(printf '6%.0s' {1..40})"

publish_fixture "$digest_bad" "$oid_bad" $'#!/usr/bin/env bash\necho broken\nexit 1'
if "$ROOT/bin/host-track" install demo >/dev/null 2>"$tmp/first-red.err"; then
  fail "a RED first install should fail closed"
fi
grep -q 'candidate exhausted and no incumbent control is available' "$tmp/first-red.err" \
  || fail "first install did not report the missing incumbent control"
[ ! -L "$HOME/apps/demo/current" ] || fail "RED first install created current"

publish_fixture "$digest_good" "$oid_good" $'#!/usr/bin/env bash\necho ok-v1'
"$ROOT/bin/host-track" install demo >/dev/null \
  || fail "green first install should activate"
[ "$(demo)" = ok-v1 ] || fail "first install did not run: $(demo)"
[ "$(readlink "$HOME/apps/demo/current")" = "versions/$digest_good" ] \
  || fail "first install current pointer wrong"

publish_fixture "$digest_transient" "$oid_transient" $'#!/usr/bin/env bash\nif [ -e "$HOME/shared-probe-down" ]; then echo shared-down >&2; exit 1; fi\nmarker="$HOME/transient-probe-count"\ncount="$(cat "$marker" 2>/dev/null || printf 0)"\ncount=$((count + 1))\nprintf "%s\\n" "$count" >"$marker"\nif [ "$count" -eq 1 ]; then echo transient >&2; exit 1; fi\necho ok-v2'
"$ROOT/bin/host-track" refresh demo >/dev/null 2>"$tmp/transient.err" \
  || fail "a transient probe failure should recover"
grep -q 'probe attempt 1/3 failed' "$tmp/transient.err" \
  || fail "transient failure did not name attempt 1/3: $(cat "$tmp/transient.err")"
grep -q 'probe recovered attempt=2/3' "$tmp/transient.err" \
  || fail "transient probe did not report recovery: $(cat "$tmp/transient.err")"
! grep -q 'probe RED' "$tmp/transient.err" \
  || fail "transient recovery still reported RED: $(cat "$tmp/transient.err")"
[ "$(demo)" = ok-v2 ] || fail "recovered candidate did not activate: $(demo)"
[ "$(readlink "$HOME/apps/demo/current")" = "versions/$digest_transient" ] \
  || fail "recovered candidate current pointer wrong"

publish_fixture "$digest_shared" "$oid_shared" $'#!/usr/bin/env bash\nif [ -e "$HOME/shared-probe-down" ]; then echo shared-down >&2; exit 1; fi\necho ok-v3'
HOST_TRACK_SOAK_HOURS=1 "$ROOT/bin/host-track" refresh demo >/dev/null \
  || fail "shared-control candidate should park for soak"
[ "$(readlink "$HOME/apps/demo/canary")" = "versions/$digest_shared" ] \
  || fail "shared-control candidate did not park as canary"
checks_before="$(jq -r '.checks' "$HOST_TRACK_STAMP_DIR/demo.soak.json")"
touch "$HOME/shared-probe-down"
HOST_TRACK_SOAK_HOURS=1 "$ROOT/bin/host-track" soak-watch demo \
  >/dev/null 2>"$tmp/inconclusive.err" \
  || fail "shared candidate and incumbent failure should stay inconclusive"
grep -q 'probe INCONCLUSIVE; candidate and incumbent both failed' "$tmp/inconclusive.err" \
  || fail "shared failure did not report an inconclusive probe: $(cat "$tmp/inconclusive.err")"
grep -q 'soak probe inconclusive; current and soak state unchanged' "$tmp/inconclusive.err" \
  || fail "shared failure did not preserve the soak: $(cat "$tmp/inconclusive.err")"
[ "$(jq -r '.status' "$HOST_TRACK_STAMP_DIR/demo.soak.json")" = soaking ] \
  || fail "shared failure marked the soak RED"
[ "$(jq -r '.checks' "$HOST_TRACK_STAMP_DIR/demo.soak.json")" = "$checks_before" ] \
  || fail "inconclusive probe counted as green"
[ "$(readlink "$HOME/apps/demo/current")" = "versions/$digest_transient" ] \
  || fail "inconclusive probe changed current"
rm -f "$HOME/shared-probe-down"

# Latency bar. The shared-control case above left a parked canary; drop that
# soak state so these refreshes take the direct activate path and the
# latency verdict alone decides the outcome. One probe call costs ~0.7s of
# harness overhead in this fixture, so the stall sleeps well past 3x that.
rm -f "$HOST_TRACK_STAMP_DIR/demo.soak.json" "$HOME/apps/demo/canary"

# One-shot stall: the candidate's second call (its first latency sample;
# call 1 is the correctness probe) sleeps, so pair one is far over the
# ratio. Pair two is even. Expect a re-sample, no RED, and activation.
publish_fixture "$digest_stall" "$oid_stall" $'#!/usr/bin/env bash\nmarker="$HOME/stall-probe-count"\ncount="$(cat "$marker" 2>/dev/null || printf 0)"\ncount=$((count + 1))\nprintf "%s\\n" "$count" >"$marker"\nif [ "$count" -eq 2 ]; then sleep 2.5; fi\necho ok-v4'
HOST_TRACK_ACTIVATE=1 HOST_TRACK_PROBE_LAT_FLOOR_MS=100 "$ROOT/bin/host-track" refresh demo \
  >/dev/null 2>"$tmp/stall.err" \
  || fail "a one-shot latency stall should recover on re-sample: $(cat "$tmp/stall.err")"
grep -q 'latency re-sample candidate=' "$tmp/stall.err" \
  || fail "stall did not trigger a latency re-sample: $(cat "$tmp/stall.err")"
grep -q 'latency recovered on re-sample; first pair' "$tmp/stall.err" \
  || fail "stall re-sample did not report recovery: $(cat "$tmp/stall.err")"
! grep -q 'latency RED' "$tmp/stall.err" \
  || fail "one-shot stall still reported latency RED: $(cat "$tmp/stall.err")"
[ "$(demo)" = ok-v4 ] || fail "stall-recovered candidate did not activate: $(demo)"
[ "$(readlink "$HOME/apps/demo/current")" = "versions/$digest_stall" ] \
  || fail "stall-recovered candidate current pointer wrong"

# Persistently slow candidate: every call sleeps, so both pairs are over the
# ratio. Expect RED on the second pair and no flip.
publish_fixture "$digest_slow" "$oid_slow" $'#!/usr/bin/env bash\nsleep 2.5\necho ok-v5'
if HOST_TRACK_ACTIVATE=1 HOST_TRACK_PROBE_LAT_FLOOR_MS=100 "$ROOT/bin/host-track" refresh demo \
  >/dev/null 2>"$tmp/slow.err"; then
  fail "a persistently slow candidate should fail closed: $(cat "$tmp/slow.err")"
fi
grep -q 'latency re-sample candidate=' "$tmp/slow.err" \
  || fail "slow candidate was not re-sampled before RED: $(cat "$tmp/slow.err")"
grep -q 'latency RED candidate=.*(both pairs; first pair' "$tmp/slow.err" \
  || fail "slow candidate did not RED on both pairs: $(cat "$tmp/slow.err")"
[ "$(demo)" = ok-v4 ] || fail "latency RED changed the live command: $(demo)"
[ "$(readlink "$HOME/apps/demo/current")" = "versions/$digest_stall" ] \
  || fail "latency RED flipped current"

publish_fixture "$digest_bad" "$oid_bad" $'#!/usr/bin/env bash\necho broken\nexit 1'
if "$ROOT/bin/host-track" refresh demo >/dev/null 2>"$tmp/red.err"; then
  fail "RED probe refresh should fail closed"
fi
grep -q 'probe attempt 1/3 failed' "$tmp/red.err" || fail "persistent failure missed attempt 1"
grep -q 'probe attempt 2/3 failed' "$tmp/red.err" || fail "persistent failure missed attempt 2"
grep -q 'probe attempt 3/3 failed' "$tmp/red.err" || fail "persistent failure missed attempt 3"
grep -q 'probe exhausted after 3 attempts' "$tmp/red.err" \
  || fail "refresh did not report exhausted retries: $(cat "$tmp/red.err")"
grep -q 'incumbent control GREEN; confirming candidate' "$tmp/red.err" \
  || fail "refresh did not compare the incumbent: $(cat "$tmp/red.err")"
grep -q 'probe RED; candidate failed while incumbent passed' "$tmp/red.err" \
  || fail "refresh did not report a candidate-only RED: $(cat "$tmp/red.err")"
[ "$(demo)" = ok-v4 ] || fail "RED probe changed the live command: $(demo)"
[ "$(readlink "$HOME/apps/demo/current")" = "versions/$digest_stall" ] \
  || fail "RED probe flipped current"
[ ! -e "$HOME/.local/bin/demo" ] || [ "$(readlink "$HOME/.local/bin/demo")" = "$HOME/apps/demo/current/bin/demo" ] \
  || true
# PATH still points at current (good tree).
[ "$(readlink "$HOME/.local/bin/demo")" = "$HOME/apps/demo/current/bin/demo" ] \
  || [ "$(readlink "$HOME/.local/bin/demo")" = "$HOME/apps/demo/versions/$digest_stall/bin/demo" ] \
  || fail "PATH link left the good tree"

# Bad version may exist on disk (staged) but must not be current.
if [ -L "$HOME/apps/demo/current" ]; then
  [ "$(readlink "$HOME/apps/demo/current")" != "versions/$digest_bad" ] \
    || fail "current points at RED candidate"
fi

# Skip-probe is the Tom-only override and must actually activate.
HOST_TRACK_PROBE_SKIP=1 "$ROOT/bin/host-track" refresh --force demo >/dev/null \
  || fail "HOST_TRACK_PROBE_SKIP should allow activation"
skip_out="$(demo || true)"
[ "$skip_out" = broken ] || fail "skip-probe did not activate the new binary: $skip_out"

# A forced restage of the LIVE digest has no incumbent of its own. When the
# probe fails there AND on `previous`, that is a shared cause (a missing probe
# fixture record, 2026-09-23 brain), not a bad binary: INCONCLUSIVE, current
# unchanged, no rollback to an older build that fails the same probe.
# (papercut-host-track-red-probe-rolls-current-back-when-incumbent-also-fails-20260923)
publish_fixture "$digest_shared" "$oid_shared" $'#!/usr/bin/env bash\nif [ -e "$HOME/shared-probe-down" ]; then echo shared-down >&2; exit 1; fi\necho ok-v3'
HOST_TRACK_PROBE_SKIP=1 HOST_TRACK_ACTIVATE=1 "$ROOT/bin/host-track" refresh --force demo >/dev/null \
  || fail "skip-probe should activate the shared-control tree"
[ "$(readlink "$HOME/apps/demo/current")" = "versions/$digest_shared" ] \
  || fail "fixture: shared tree is not current"
touch "$HOME/shared-probe-down"
HOST_TRACK_ACTIVATE=1 "$ROOT/bin/host-track" refresh --force demo >/dev/null 2>"$tmp/restage.err" \
  || fail "a restage that fails on current and previous should be inconclusive: $(cat "$tmp/restage.err")"
grep -q 'INCONCLUSIVE' "$tmp/restage.err" \
  || fail "restage did not report INCONCLUSIVE: $(cat "$tmp/restage.err")"
! grep -q 'rolling current back' "$tmp/restage.err" \
  || fail "restage rolled current back on a shared failure: $(cat "$tmp/restage.err")"
[ "$(readlink "$HOME/apps/demo/current")" = "versions/$digest_shared" ] \
  || fail "restage changed current: $(readlink "$HOME/apps/demo/current")"
rm -f "$HOME/shared-probe-down"

printf 'ok: host-track probe-before-cutover\n'
