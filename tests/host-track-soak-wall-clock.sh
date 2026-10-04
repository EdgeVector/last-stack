#!/usr/bin/env bash
# `host-track status` must report the wall clock that DECIDES the soak flip.
#
# `soak_watch_one` gates on both halves:
#
#   if [ "$elapsed" -lt "$need" ] || [ "$checks" -lt "$min_checks" ]
#
# and its own comment says the check count is the backstop, not the gate. Recent
# last-stack soaks activate at 10-15 checks against min_checks=3, so a status
# line carrying only `checks/min_checks` reads as over-satisfied for most of the
# window's life -- a soaking canary rendered as a stuck promotion.
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
export PATH="$HOME/.local/bin:$tmp/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
mkdir -p "$HOME/.local/bin" "$tmp/bin" "$tmp/cas"

cat > "$tmp/bin/lastgit" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = artifact ] && [ "${2:-}" = resolve ] || exit 2
shift 2
root=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --app) shift 2 ;;
    --channel) shift 2 ;;
    --root) root="$2"; shift 2 ;;
    --json) shift ;;
    *) exit 2 ;;
  esac
done
cat "$root/channels/demo/stable.json"
SH
chmod +x "$tmp/bin/lastgit"

write_registry() {
  local soak_hours="$1"
  cat > "$HOST_TRACK_REGISTRY" <<JSON
{
  "defaults": {"install_mode": "artifact", "artifact_channel": "stable"},
  "apps": [{
    "app": "demo",
    "kind": "artifact-bundle",
    "command": "demo",
    "artifact_root": "\$HOME/../cas",
    "install_root": "\$HOME/apps/demo",
    "links": [{"source": "bin/demo", "target": "\$HOME/.local/bin/demo"}],
    "safe_upgrade": {
      "soak_hours": $soak_hours,
      "probes": [{"argv": ["bin/demo"], "timeout_s": 10}]
    }
  }]
}
JSON
}

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

status_json() {
  "$ROOT/bin/host-track" status demo --json > "$tmp/status.json" 2>"$tmp/status.err"
  jq -c 'if type == "array" then .[0] else . end' "$tmp/status.json"
}

digest_one="$(printf 'a%.0s' {1..64})"
digest_two="$(printf 'b%.0s' {1..64})"
oid_one="$(printf '1%.0s' {1..40})"
oid_two="$(printf '2%.0s' {1..40})"

write_registry 1
publish_fixture "$digest_one" "$oid_one" $'#!/usr/bin/env bash\necho v1'
"$ROOT/bin/host-track" install demo >/dev/null

# No canary parked: the soak fields must be ABSENT (null), never 0. "No window
# recorded" and "zero seconds elapsed" are opposite readings of the same gate.
before="$(status_json)"
printf '%s\n' "$before" | jq -e '.soak_elapsed_secs == null and .soak_need_secs == null' >/dev/null \
  || fail "no-canary status should report null soak clock, got: $before"
"$ROOT/bin/host-track" status demo 2>/dev/null | tr '\t' '\n' | grep -qx 'soak=-' \
  || fail "no-canary plain line should render soak=-"

publish_fixture "$digest_two" "$oid_two" $'#!/usr/bin/env bash\necho v2'
"$ROOT/bin/host-track" refresh demo >/dev/null
[ -f "$HOST_TRACK_STAMP_DIR/demo.soak.json" ] || fail "soak stamp missing after refresh"

soaking="$(status_json)"
printf '%s\n' "$soaking" | jq -e '.soak_state == "soaking"' >/dev/null \
  || fail "expected a soaking canary, got: $soaking"
printf '%s\n' "$soaking" | jq -e '.soak_need_secs == 3600' >/dev/null \
  || fail "soak_need_secs should be soak_hours*3600, got: $soaking"
printf '%s\n' "$soaking" | jq -e '.soak_elapsed_secs != null and .soak_elapsed_secs >= 0 and .soak_elapsed_secs < 3600' >/dev/null \
  || fail "soak_elapsed_secs should be inside the window, got: $soaking"

# The human line carries both halves, so the reader who never asks for --json
# sees the binding one.
plain="$("$ROOT/bin/host-track" status demo 2>/dev/null | tr '\t' '\n' | grep '^soak=')"
case "$plain" in
  soak=soaking:*/*:*s/3600s*) ;;
  *) fail "plain soak line should carry elapsed/need, got: $plain" ;;
esac

# WHEN THE GATE LAST LOOKED, on every soaking line. The countdown alone is not
# a wait: `status` computes `elapsed` at read time while the gate is consulted
# only on a soak-watch tick, so `3384s/3600s` was read as "216s from flipping"
# in a durable record when the real wait was that plus up to a full tick.
case "$plain" in
  *:last_check=*s*) ;;
  *) fail "a soaking line must say when the gate last looked, got: $plain" ;;
esac
# `checks_total` is what the STARVE arm gates on, so it is needed to explain any
# non-flipping canary -- not only one that has already been abandoned once. It
# used to render only while `abandoned > 0`, which hid it on every healthy soak.
printf '%s\n' "$soaking" | jq -e '.soak_abandoned == 0' >/dev/null \
  || fail "fixture should be un-abandoned so this covers the hidden case: $soaking"
case "$plain" in
  *:total=*:abandoned=0*) ;;
  *) fail "checks_total must render at abandoned=0 too, got: $plain" ;;
esac

# THE INVARIANT, not the constant: `soak_watch_one` re-reads the window from the
# REGISTRY on every pass, so a window widened after a canary parked binds that
# canary. Reporting the stamp's own copy would print a deadline the flip
# ignores. Widen the registry and the reported need must follow it.
jq -e '.soak_hours == 1' "$HOST_TRACK_STAMP_DIR/demo.soak.json" >/dev/null \
  || fail "fixture expected the stamp to record the original 1h window"
write_registry 2
widened="$(status_json)"
printf '%s\n' "$widened" | jq -e '.soak_need_secs == 7200' >/dev/null \
  || fail "soak_need_secs must follow the registry the gate reads, not the stamp: $widened"

# And the reported window is the one the gate actually applies: at an elapsed
# time inside it, soak-watch still refuses to flip.
write_registry 1
jq --argjson started "$(( $(date +%s) - 60 ))" '.started_epoch = $started | .checks = 99' \
  "$HOST_TRACK_STAMP_DIR/demo.soak.json" > "$tmp/stamp.json"
mv "$tmp/stamp.json" "$HOST_TRACK_STAMP_DIR/demo.soak.json"
inside="$(status_json)"
printf '%s\n' "$inside" | jq -e '.soak_elapsed_secs < .soak_need_secs' >/dev/null \
  || fail "fixture should sit inside the window, got: $inside"
out="$("$ROOT/bin/host-track" soak-watch demo)"
printf '%s\n' "$out" | grep -q 'soak pending' \
  || fail "status reported time left but soak-watch flipped anyway: $out"
[ "$(demo)" = v1 ] || fail "soak-watch flipped inside the reported window: $(demo)"

# THE OVERDUE DIRECTION. Both thresholds exceeded while the state is still
# `soaking` is AMBIGUOUS, and the elapsed/need pair above cannot express it: the
# gate may not have been consulted since the window closed, or it may have
# looked and refused on a second condition. Those want opposite actions, so the
# line must name which one it is. The discriminator is the stamp's own
# `last_check_at`: the gate has looked since the close exactly when
# `elapsed - need >= last_check_age`.
iso_at() {
  # BSD first (the macOS runner and this host), GNU second.
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

# `status` re-reads the registry, so pin the window back to 1h for these cases.
write_registry 1
set_soak_fixture() {
  # elapsed_secs, last_check_age_secs
  local elapsed="$1" age="$2" now
  now="$(date +%s)"
  jq --argjson started "$(( now - elapsed ))" \
     --arg last_check "$(iso_at "$(( now - age ))")" \
     '.status = "soaking" | .started_epoch = $started | .last_check_at = $last_check
      | .checks = 9 | .checks_total = 9 | .abandoned_consecutive = 0' \
    "$HOST_TRACK_STAMP_DIR/demo.soak.json" > "$tmp/stamp.json"
  mv "$tmp/stamp.json" "$HOST_TRACK_STAMP_DIR/demo.soak.json"
}
soak_line() { "$ROOT/bin/host-track" status demo 2>/dev/null | tr '\t' '\n' | grep '^soak='; }

# Over budget by 400s, and the gate last looked 600s ago -- so it has NOT been
# consulted since the window closed. Nothing is wrong; one tick is owed.
set_soak_fixture 4000 600
pending="$(status_json)"
printf '%s\n' "$pending" | jq -e '.soak_elapsed_secs >= .soak_need_secs' >/dev/null \
  || fail "fixture should be over budget, got: $pending"
printf '%s\n' "$pending" | jq -e '.soak_gate == "pending"' >/dev/null \
  || fail "an un-consulted over-budget window is gate-pending, got: $pending"
pending_line="$(soak_line)"
case "$pending_line" in
  *window-met:gate-pending*) ;;
  *) fail "over-budget line must say the gate has not looked, got: $pending_line" ;;
esac
# And it must NOT also print the countdown: an over-budget countdown is the
# exact rendering that reads as a stuck promotion.
case "$pending_line" in
  *s/3600s*) fail "an over-budget line must not render a countdown: $pending_line" ;;
esac

# Over budget by 400s and the gate looked 100s ago: it HAS evaluated since the
# close and still did not flip, so something else is binding. Worth diagnosing.
set_soak_fixture 4000 100
refused="$(status_json)"
printf '%s\n' "$refused" | jq -e '.soak_gate == "refused"' >/dev/null \
  || fail "a consulted over-budget window is gate-refused, got: $refused"
case "$(soak_line)" in
  *window-met:gate-refused*) ;;
  *) fail "expected gate-refused, got: $(soak_line)" ;;
esac

# An unreadable `last_check_at` is its own answer. Reporting either verdict
# would be a guess, and the pending one reads as "all is well".
jq '.last_check_at = "not-a-timestamp"' "$HOST_TRACK_STAMP_DIR/demo.soak.json" > "$tmp/stamp.json"
mv "$tmp/stamp.json" "$HOST_TRACK_STAMP_DIR/demo.soak.json"
unknown="$(status_json)"
printf '%s\n' "$unknown" | jq -e '.soak_gate == "unknown" and .soak_last_check_age_secs == null' >/dev/null \
  || fail "an unparseable last_check_at must render neither verdict, got: $unknown"

# INSIDE the window the countdown is correct and must survive: the not-yet-due
# direction is what the elapsed/need pair was added for.
set_soak_fixture 1200 60
inside_again="$(status_json)"
printf '%s\n' "$inside_again" | jq -e '.soak_gate == null' >/dev/null \
  || fail "an in-window soak has no gate verdict to report, got: $inside_again"
# TOLERANCE, not a literal. `*:1200s/3600s:last_check=6*` was the first form of
# this assertion and it is a flake by construction: `set_soak_fixture` takes its
# own `now`, `host-track status` computes `elapsed` at READ time, and every
# `status` spawn in between advances the clock. It passed on this host and failed
# on a GitHub runner at `1202s/3600s:last_check=62s` -- the countdown and the
# tick age both present and correct, the assertion red on two seconds of drift.
# An exact second cannot be derived here, so the claim is the SHAPE plus a band.
line_again="$(soak_line)"
case "$line_again" in
  *s/3600s:last_check=*s*) ;;
  *) fail "in-window line must keep the countdown and the tick age, got: $line_again" ;;
esac
# Bound the numbers ON THE LINE, not only in the JSON. The first version of
# this band read `.soak_elapsed_secs` from the JSON while the shape pattern
# accepted any digits in the line, so a mutation that rendered the countdown as
# `0s/3600s` passed: the band and the shape were guarding two different
# surfaces and the line -- the thing an operator reads -- was unguarded.
line_elapsed="$(printf '%s\n' "$line_again" | sed -n 's|.*:\([0-9]\{1,\}\)s/3600s:.*|\1|p')"
line_age="$(printf '%s\n' "$line_again" | sed -n 's|.*:last_check=\([0-9]\{1,\}\)s.*|\1|p')"
{ [ -n "$line_elapsed" ] && [ "$line_elapsed" -ge 1200 ] && [ "$line_elapsed" -lt 1500 ]; } \
  || fail "the line's countdown must be the fixture's own elapsed, within drift, got: $line_again"
{ [ -n "$line_age" ] && [ "$line_age" -ge 60 ] && [ "$line_age" -lt 360 ]; } \
  || fail "the line's tick age must be the fixture's own, within drift, got: $line_again"
printf '%s\n' "$inside_again" | jq -e '.soak_elapsed_secs >= 1200 and .soak_elapsed_secs < 1500
    and .soak_last_check_age_secs >= 60 and .soak_last_check_age_secs < 360' >/dev/null \
  || fail "the JSON numbers must be the fixture's own, within drift, got: $inside_again"

# A RED canary must NOT carry a clock. Both `soak_red` writes reset
# `started_epoch` to now, so the stamp holds a fresh window for a candidate that
# will never flip; printing it would render `soak_red:1/3:0s/3600s` as a
# countdown. The state is reported, the window is not.
jq '.status = "soak_red" | .started_epoch = '"$(date +%s)"' | .checks = 1' \
  "$HOST_TRACK_STAMP_DIR/demo.soak.json" > "$tmp/stamp.json"
mv "$tmp/stamp.json" "$HOST_TRACK_STAMP_DIR/demo.soak.json"
red="$(status_json)"
printf '%s\n' "$red" | jq -e '.soak_state == "soak_red"' >/dev/null \
  || fail "fixture should be red, got: $red"
printf '%s\n' "$red" | jq -e '.soak_elapsed_secs == null and .soak_need_secs == null' >/dev/null \
  || fail "a red canary must not report a flip window: $red"
red_plain="$("$ROOT/bin/host-track" status demo 2>/dev/null | tr '\t' '\n' | grep '^soak=')"
case "$red_plain" in
  *s/*s) fail "red plain line must not carry a countdown: $red_plain" ;;
  soak=soak_red:*) ;;
  *) fail "unexpected red plain line: $red_plain" ;;
esac

printf 'ok: host-track soak wall clock\n'
