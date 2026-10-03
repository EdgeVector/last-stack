#!/usr/bin/env bash
# host-track follows the registry `next` channel (North Star slice 7):
#   - the desired oid is the one `lastdb app resolve` proves, not the channel head
#   - a pinned oid whose artifact is published installs it; status reads pinned
#   - a newer channel head that is NOT proved does not make the host stale,
#     and `pin_behind_oid` names it so the wait is legible instead of `fresh`
#   - no proved row → the host HOLDS its current install (refresh returns 75)
#   - an app not on the index falls back to the channel head as before
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

export HOME="$tmp/home"
export HOST_TRACK_REGISTRY="$tmp/registry.json"
export HOST_TRACK_STAMP_DIR="$tmp/stamps"
export HOST_TRACK_PROBE_SKIP=1
export PATH="$HOME/.local/bin:$tmp/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
mkdir -p "$HOME/.local/bin" "$tmp/bin" "$tmp/cas"

# A fixed, deliberately OLD proof date: the age the status row prints is what
# tells a reader a pin is behind because the prover stopped, not because the
# publish is seconds young, so the test pins a date rather than "now".
export RESOLVE_PROVED_AT="2026-09-20T00:00:00Z"

oid_one="$(printf '1%.0s' {1..40})"
oid_two="$(printf '2%.0s' {1..40})"
oid_three="$(printf '3%.0s' {1..40})"
oid_four="$(printf '4%.0s' {1..40})"
export HOST_TRACK_TEST_MAIN_OID="$oid_one"

cat > "$tmp/bin/lastgit" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = status ]; then
  jq -n --arg oid "$HOST_TRACK_TEST_MAIN_OID" '{refs:[{name:"refs/heads/main",oid:$oid}]}'; exit 0
fi
if [ "${1:-}" = ref ]; then
  printf '%s\t%s\t%s\n' "$HOST_TRACK_TEST_MAIN_OID" "refs/heads/${3:-main}" point; exit 0
fi
[ "${1:-}" = artifact ] && [ "${2:-}" = resolve ] || exit 2
shift 2
app="" channel="" root=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --app) app="$2"; shift 2 ;; --channel) channel="$2"; shift 2 ;; --root) root="$2"; shift 2 ;;
    --json|--promote) shift ;; --repo|--oid|--context|--manifest) shift 2 ;; *) exit 2 ;;
  esac
done
cat "$root/channels/$app/$channel.json"
SH
chmod +x "$tmp/bin/lastgit"

# Fake `lastdb app resolve`: answers from $tmp/resolve.json {app: sha}; an app
# absent from the table is "not in the index"; RESOLVE_NO_ROW=1 is "no row".
cat > "$tmp/bin/lastdb" <<SH
#!/usr/bin/env bash
# \`--version\` is what host-track compares the index's newest row against.
if [ "\$1" = --version ]; then
  echo "lastdb \${STUB_LASTDB_VERSION:-0.23.3-1-gx}"; exit 0
fi
# \`app info\` returns the whole compat list, across ALL builds -- the read that
# discriminates a stalled prover from a build mismatch.
if [ "\$1" = app ] && [ "\$2" = info ]; then
  [ "\$3" = --help ] && { echo usage; exit 0; }
  echo "info \$*" >>"$tmp/info-calls.log"
  [ "\${INFO_UNSUPPORTED:-0}" = 1 ] && { echo "error: unrecognized subcommand 'info'" >&2; exit 2; }
  [ "\${INFO_FAIL:-0}" = 1 ] && { echo "error: failed to read index" >&2; exit 1; }
  app="\$3"; shift 3
  channel="" index=""
  while [ "\$#" -gt 0 ]; do
    case "\$1" in
      --channel) channel="\$2"; shift 2 ;;
      --index) index="\$2"; shift 2 ;;
      *) echo "error: unexpected argument '\$1'" >&2; exit 2 ;;
    esac
  done
  # The stub REFUSES a wrong channel or a wrong index. A stub that answers for
  # any value lets the plumbing read as covered when it is not: measured on the
  # why-stopped fixture the same day, where a channel read from the wrong column
  # still got a good answer and its mutation probe came back green.
  [ "\$channel" = next ] || { echo "error: no channel '\$channel'" >&2; exit 2; }
  [ "\$index" = "\${EXPECT_INFO_INDEX:-http://forge.test/registry}" ] \
    || { echo "error: wrong index '\$index'" >&2; exit 2; }
  if [ "\${INFO_NO_ROWS:-0}" = 1 ]; then
    jq -n --arg a "\$app" '{app_id:\$a, source:"x", compat:[]}'; exit 0
  fi
  jq -n --arg a "\$app" \
    --arg nv "\${INFO_NEWEST_VERSION-0.23.3-1-gx}" \
    --arg na "\${INFO_NEWEST_AT:-2026-09-29T00:00:00Z}" \
    --arg ns "\${INFO_NEWEST_SHA:-$oid_four}" \
    '{app_id:\$a, source:"x", compat:[
        {app_version:"1.0.0", sha:"0000", lastdb_version:"0.23.3-0-gold",
         proved_at:"2026-09-01T00:00:00Z", proof_run:"old-run"},
        {app_version:"1.0.0", sha:\$ns, lastdb_version:\$nv,
         proved_at:\$na, proof_run:("run-" + \$nv)}]}'
  exit 0
fi
[ "\$1" = app ] && [ "\$2" = resolve ] || { echo unknown >&2; exit 2; }
[ "\$3" = --help ] && { echo usage; exit 0; }
app="\$3"
echo "resolve \$*" >>"$tmp/resolve-calls.log"
if [ "\${RESOLVE_NO_ROW:-0}" = 1 ]; then
  echo "error: no next row for app '\$app' was proved with lastdb 0.23.3-1-gx; run \\\`brew upgrade lastdb\\\`" >&2; exit 1
fi
# "I could not ask", not "the answer was no": a real unreadable-index failure.
if [ "\${RESOLVE_UNREADABLE:-0}" = 1 ]; then
  echo "error: failed to read /nope/next.json: No such file or directory (os error 2)" >&2; exit 1
fi
sha="\$(jq -r --arg a "\$app" '.[\$a] // empty' "$tmp/resolve.json")"
[ -n "\$sha" ] || { echo "error: app '\$app' is not in the next index" >&2; exit 1; }
jq -n --arg a "\$app" --arg sha "\$sha" --arg pa "\${RESOLVE_PROVED_AT:-}" --arg pr "\${RESOLVE_PROOF_RUN-run-x}" \
  '{app_id:\$a, channel:"next", sha:\$sha, app_version:"1.0.0", lastdb_version:"0.23.3-1-gx", source:"x"}
   + (if \$pa == "" then {} else {proved_at: \$pa} end)
   + (if \$pr == "" then {} else {proof_run: \$pr} end)'
SH
chmod +x "$tmp/bin/lastdb"
printf '{"demo":"%s"}\n' "$oid_one" >"$tmp/resolve.json"

cat > "$HOST_TRACK_REGISTRY" <<'JSON'
{
  "defaults": {
    "install_mode": "artifact",
    "artifact_channel": "stable",
    "registry_channel": "next",
    "registry_index": "http://forge.test/registry"
  },
  "apps": [
    {
      "app": "demo", "kind": "artifact-bundle", "command": "demo", "install_mode": "artifact",
      "gate": "lastgit", "gate_main": "lastdb:///demo#main", "track_gate_main": false,
      "artifact_root": "$HOME/../cas", "install_root": "$HOME/apps/demo",
      "links": [{"source": "bin/demo", "target": "$HOME/.local/bin/demo"}],
      "notes": "registry pin fixture"
    },
    {
      "app": "plain", "kind": "artifact-bundle", "command": "plain", "install_mode": "artifact",
      "gate": "lastgit", "gate_main": "lastdb:///plain#main", "track_gate_main": false,
      "artifact_root": "$HOME/../cas", "install_root": "$HOME/apps/plain",
      "links": [{"source": "bin/plain", "target": "$HOME/.local/bin/plain"}],
      "notes": "not on the index; follows the channel head"
    }
  ]
}
JSON

publish_fixture() {
  local app="$1" digest="$2" oid="$3" content="$4" payload sha size blob manifest
  payload="$tmp/payload"
  printf '%s\n' "$content" > "$payload"
  sha="$(shasum -a 256 "$payload" | awk '{print $1}')"
  size="$(wc -c < "$payload" | tr -d ' ')"
  blob="$tmp/cas/blobs/sha256/${sha:0:2}/$sha"
  mkdir -p "$(dirname "$blob")" "$tmp/cas/channels/$app" "$tmp/cas/manifests"
  cp "$payload" "$blob"
  manifest="$tmp/cas/manifests/$digest.json"
  jq -n --arg app "$app" --arg digest "$digest" --arg oid "$oid" --arg sha "$sha" --argjson size "$size" \
    '{schema_version: 1, app: $app, repo: $app, source_oid: $oid, platform: "test-arm64",
      created_at: "2026-09-20T00:00:00Z",
      files: [{path: ("bin/" + $app), sha256: $sha, size: $size, mode: 493}], manifest_digest: $digest}' > "$manifest"
  cp "$manifest" "$tmp/cas/channels/$app/stable.json"
}

d1="$(printf 'a%.0s' {1..64})"; d2="$(printf 'b%.0s' {1..64})"; d3="$(printf 'c%.0s' {1..64})"
d4="$(printf 'd%.0s' {1..64})"

# 1. Pinned install: channel head is oid_one, resolve says oid_one.
publish_fixture demo "$d1" "$oid_one" $'#!/usr/bin/env bash\necho v1'
"$ROOT/bin/host-track" install demo >/dev/null
[ "$(demo)" = v1 ] || fail "pinned install did not run"
grep -q -- "--index http://forge.test/registry" "$tmp/resolve-calls.log" || fail "registry_index default not passed to resolve"
st="$("$ROOT/bin/host-track" status --json demo)"
printf '%s\n' "$st" | jq -e '.registry_channel == "next" and .registry_pin_state == "pinned" and .stale == false' >/dev/null \
  || fail "pinned status: $st"
# Nothing published past the pin yet, so there is nothing to report.
printf '%s\n' "$st" | jq -e '.pin_behind_oid == null' >/dev/null \
  || fail "pin_behind_oid set while the pin IS the channel head: $st"

# 2. Channel head moves to oid_two (published), but the proved row is still oid_one:
#    the host is NOT stale, and refresh keeps v1.
publish_fixture demo "$d2" "$oid_two" $'#!/usr/bin/env bash\necho v2'
export HOST_TRACK_TEST_MAIN_OID="$oid_two"
st="$("$ROOT/bin/host-track" status --json demo)"
printf '%s\n' "$st" | jq -e '.stale == false and .registry_pin_state == "pinned"' >/dev/null \
  || fail "unproved channel head made the host stale: $st"
# The whole point of the field: the pin is BEHIND a published head, and the
# install is still genuinely current with the pair the registry proved. Both
# halves are asserted together on purpose — a test that checked only
# pin_behind_oid would pass while flipping `stale` and breaking the 7 sites
# that branch on the freshness it feeds.
# papercut-fkanban-host-track-fresh-while-main-ahead-20260923
printf '%s\n' "$st" | jq -e --arg oid "$oid_two" '.pin_behind_oid == $oid and .stale == false' >/dev/null \
  || fail "pin behind a published head not reported, or stale moved: $st"
# `pin_behind` alone cannot separate publish lag from a prover that stopped --
# the two want opposite actions. The proof date and the prover that wrote it
# are in the resolve JSON host-track already reads, so a row that reports the
# lag must also report WHY. The whole-day outage this closes:
# papercut-host-track-registry-pin-lags-behind-published-artifact-20260927
printf '%s\n' "$st" | jq -e --arg t "$RESOLVE_PROVED_AT" \
  '.registry_pin_proved_at == $t and .registry_pin_proof_run == "run-x" and (.registry_pin_proof_age_secs | type) == "number" and .registry_pin_proof_age_secs > 0' >/dev/null \
  || fail "pin behind a head without the proof frontier that explains it: $st"
row="$("$ROOT/bin/host-track" status demo)"
case "$row" in
  *"pin_proved=$RESOLVE_PROVED_AT:age="*"h:by=run-x"*) ;;
  *) fail "text row drops the proof frontier beside pin_behind: $row" ;;
esac
# A resolve row that carries no proved_at must leave the fields empty rather
# than inventing an age of "now", which would read as a fresh proof.
st_noat="$(RESOLVE_PROVED_AT= "$ROOT/bin/host-track" status --json demo)"
# This is also the field-shift discriminator: an EMPTY MIDDLE field is what a
# `read`-based split collapses, so `proof_run` would land in `proved_at` here.
printf '%s\n' "$st_noat" | jq -e '.registry_pin_proved_at == null and .registry_pin_proof_age_secs == null and .registry_pin_proof_run == "run-x"' >/dev/null \
  || fail "a resolve row with no proved_at reported an age, or shifted proof_run into it: $st_noat"
# An empty proof_run must not shift into proved_at: tab is IFS whitespace, so
# a `read`-based split collapses the empty field and reports run-x's slot wrong.
st_norun="$(RESOLVE_PROOF_RUN= "$ROOT/bin/host-track" status --json demo)"
printf '%s\n' "$st_norun" | jq -e --arg t "$RESOLVE_PROVED_AT" \
  '.registry_pin_proved_at == $t and .registry_pin_proof_run == null' >/dev/null \
  || fail "an empty proof_run shifted the TSV fields: $st_norun"
# And `freshness` must still be one of the three values the fleet branches on.
printf '%s\n' "$st" | jq -e '. as $r | (["fresh","soft_stale","hard_broken"] | index($r.freshness)) != null' >/dev/null \
  || fail "a pin-behind row invented a new freshness value; 7 sites branch on the literals: $st"
"$ROOT/bin/host-track" refresh demo >/dev/null 2>&1 || true
[ "$(demo)" = v1 ] || fail "refresh moved to an unproved commit"

# 2b. A pin behind a published head is the one state where the frontier's BUILD
#     decides the remedy, and until now nothing in `status` could express it.
#     `registry_pin_proved_at` / `registry_pin_proof_run` come from
#     `lastdb app resolve`, which only ever returns rows keyed to the RUNNING
#     build, so a 32 h frontier reads identically whether the prover stopped or
#     is proving a build this host does not run -- and those want opposite
#     actions. Measured 2026-10-03: the commit the fleet waited nine hours for
#     was already proved on another build.
#     papercut-host-track-proof-run-field-is-build-filtered-so-it-can-never-expose-a-build-mismatch-20261003
st="$(INFO_NEWEST_VERSION=0.23.3-9-gother INFO_NEWEST_AT=2026-10-02T12:00:00Z \
  INFO_NEWEST_SHA="$oid_two" "$ROOT/bin/host-track" status --json demo)"
printf '%s\n' "$st" | jq -e --arg oid "$oid_two" '
  .registry_index_build_match == "mismatch"
  and .registry_index_newest_version == "0.23.3-9-gother"
  and .registry_index_newest_proved_at == "2026-10-02T12:00:00Z"
  and .registry_index_newest_oid == $oid
  and .registry_lastdb_version == "0.23.3-1-gx"' >/dev/null \
  || fail "a frontier on another build did not report a build mismatch: $st"
# The running build must ship WITH the newest row. Without it the newest row has
# nothing in the same object to compare against and every consumer reaches for a
# second tool; three did, and two did not know which tool.
printf '%s\n' "$st" | jq -e '.registry_lastdb_version != .registry_index_newest_version' >/dev/null \
  || fail "mismatch row reported the two builds as equal: $st"
# Asked about the right app, on the right channel, on the app's own index. The
# stub refuses a wrong channel or index, so this grep only sharpens the message.
grep -q -- "info demo --channel next --index http://forge.test/registry" "$tmp/info-calls.log" \
  || fail "app info was not asked about demo/next on the configured index: $(cat "$tmp/info-calls.log")"
# And the text row must carry it beside pin_behind, or the only reader who sees
# the field is one who already knew to ask for --json.
row="$(INFO_NEWEST_VERSION=0.23.3-9-gother "$ROOT/bin/host-track" status demo)"
case "$row" in
  *"index_newest=mismatch:0.23.3-9-gother@"*":running=0.23.3-1-gx"*) ;;
  *) fail "text row drops the build discriminator beside pin_behind: $row" ;;
esac

# 2c. The frontier IS on this host's build: the prover is not working on another
#     build, so the AGE decides, and registry_pin_proof_age_secs already answers
#     that. Deliberately NOT labelled `prover-stalled` -- a pin three minutes
#     behind a fresh publish reaches this arm too.
st="$("$ROOT/bin/host-track" status --json demo)"
printf '%s\n' "$st" | jq -e '
  .registry_index_build_match == "match"
  and .registry_index_newest_version == .registry_lastdb_version' >/dev/null \
  || fail "a frontier on the running build did not report a match: $st"

# 2d. The read failed, or the binary has no `app info`. "I did not look" must
#     never render as a measured answer, and no value field may be invented.
for env_fail in INFO_FAIL=1 INFO_UNSUPPORTED=1; do
  st="$(env "$env_fail" "$ROOT/bin/host-track" status --json demo)"
  printf '%s\n' "$st" | jq -e '
    .registry_index_build_match == "unread"
    and .registry_index_newest_version == null
    and .registry_index_newest_proved_at == null
    and .registry_index_newest_oid == null' >/dev/null \
    || fail "$env_fail did not report unread, or invented a newest row: $st"
  # The row it IS about must survive: an unread discriminator is additive.
  printf '%s\n' "$st" | jq -e --arg oid "$oid_two" \
    '.pin_behind_oid == $oid and .registry_pin_state == "pinned" and .stale == false' >/dev/null \
    || fail "$env_fail changed the pin row it only annotates: $st"
done

# 2e. The index was READ and holds no proved row for this app on any build.
#     That is a different claim from "I could not read it", and collapsing the
#     two is the defect papercut-host-track-reads-any-registry-resolve-failure-as-no-proved-row-20261002
#     closed one level up. Do not re-introduce it one level down.
st="$(INFO_NO_ROWS=1 "$ROOT/bin/host-track" status --json demo)"
printf '%s\n' "$st" | jq -e '
  .registry_index_build_match == "no-rows"
  and .registry_index_newest_version == null' >/dev/null \
  || fail "an empty compat list rendered as something other than no-rows: $st"

# 2g. A row whose lastdb_version is empty: no verdict is possible, and the
#     EMPTY FIRST FIELD must not shift the other two. `IFS=$'\t' read` collapses
#     it -- tab is IFS whitespace -- so proved_at would land in the version slot
#     and a comparison would be made against a timestamp. Hence `cut` per field,
#     and hence this case: without it the discipline reads as covered and is not.
st="$(INFO_NEWEST_VERSION= "$ROOT/bin/host-track" status --json demo)"
printf '%s\n' "$st" | jq -e '
  .registry_index_build_match == "unread"
  and .registry_index_newest_version == null
  and .registry_index_newest_proved_at == "2026-09-29T00:00:00Z"
  and (.registry_index_newest_oid | length) == 40' >/dev/null \
  || fail "an empty lastdb_version shifted the TSV fields, or produced a verdict: $st"

# 2f. The healthy path pays NOTHING. The read is scoped to a pin that is behind,
#     so a fleet with nothing behind must spawn no `app info` at all -- asserted
#     structurally, because a cost regression here is invisible in every output.
#     HOST_TRACK_TEST_MAIN_OID is NOT the lever here: `pin_behind_oid` compares
#     the pin against the PUBLISHED artifact channel head, not lastgit main, so
#     the pin has to catch up for the row to have nothing behind.
cp "$tmp/resolve.json" "$tmp/resolve.json.bak"
printf '{"demo":"%s"}\n' "$oid_two" >"$tmp/resolve.json"
: >"$tmp/info-calls.log"
st="$("$ROOT/bin/host-track" status --json demo)"
printf '%s\n' "$st" | jq -e '
  .pin_behind_oid == null
  and .registry_index_build_match == null
  and .registry_index_newest_version == null
  and .registry_index_newest_proved_at == null
  and .registry_index_newest_oid == null
  and .registry_lastdb_version == null' >/dev/null \
  || fail "a row with nothing behind carried the discriminator: $st"
[ ! -s "$tmp/info-calls.log" ] \
  || fail "app info was spawned for an app with nothing behind: $(cat "$tmp/info-calls.log")"
mv "$tmp/resolve.json.bak" "$tmp/resolve.json"

# 3. The proof lands for oid_two: now the host is stale and refresh installs v2.
printf '{"demo":"%s"}\n' "$oid_two" >"$tmp/resolve.json"
st="$("$ROOT/bin/host-track" status --json demo)"
printf '%s\n' "$st" | jq -e '.stale == true and .registry_pin_oid == "'"$oid_two"'"' >/dev/null \
  || fail "proved pin not stale: $st"
# The pin caught up: the field must clear, or it becomes a permanent warning.
printf '%s\n' "$st" | jq -e '.pin_behind_oid == null' >/dev/null \
  || fail "pin_behind_oid survived the pin catching up: $st"
"$ROOT/bin/host-track" refresh demo >/dev/null 2>&1
[ "$(demo)" = v2 ] || fail "refresh did not install the proved commit"

# 4. Proved commit with no published artifact yet: hold (75), status pinned-unpublished.
printf '{"demo":"%s"}\n' "$oid_three" >"$tmp/resolve.json"
set +e
"$ROOT/bin/host-track" refresh --force demo >/dev/null 2>"$tmp/hold.err"
rc=$?
set -e
[ "$rc" -eq 75 ] || fail "unpublished pin did not hold (rc=$rc): $(cat "$tmp/hold.err")"
grep -q "no published artifact yet" "$tmp/hold.err" || fail "hold message: $(cat "$tmp/hold.err")"
[ "$(demo)" = v2 ] || fail "hold changed the install"
st="$("$ROOT/bin/host-track" status --json demo)"
printf '%s\n' "$st" | jq -e '.registry_pin_state == "pinned-unpublished"' >/dev/null || fail "pinned-unpublished status: $st"

# 5. No proved row at all for this node: hold, not stale.
set +e
RESOLVE_NO_ROW=1 "$ROOT/bin/host-track" refresh --force demo >/dev/null 2>"$tmp/norow.err"
rc=$?
set -e
[ "$rc" -eq 75 ] || fail "no-row did not hold (rc=$rc): $(cat "$tmp/norow.err")"
grep -q "no registry row proved with this LastDB build" "$tmp/norow.err" || fail "no-row message: $(cat "$tmp/norow.err")"
st="$(RESOLVE_NO_ROW=1 "$ROOT/bin/host-track" status --json demo)"
printf '%s\n' "$st" | jq -e '.registry_pin_state == "no-proved-row" and .stale == false' >/dev/null || fail "no-row status: $st"
printf '%s\n' "$st" | jq -e '.registry_pin_proved_at == null and .registry_pin_proof_age_secs == null' >/dev/null \
  || fail "a no-proved-row hold reported a proof date it does not have: $st"

# Publish a head the install is NOT on, so a hold has real lag to report. Both
# hold arms must report it identically; without this the two arms agree
# trivially and a parity assertion below cannot fail.
publish_fixture demo "$d4" "$oid_four" $'#!/usr/bin/env bash\necho v3'
export HOST_TRACK_TEST_MAIN_OID="$oid_four"
st="$(RESOLVE_NO_ROW=1 "$ROOT/bin/host-track" status --json demo)"
printf '%s\n' "$st" | jq -e --arg oid "$oid_four" \
  '.registry_pin_state == "no-proved-row" and .pin_behind_oid == $oid and .freshness == "soft_stale" and .stale == false' >/dev/null \
  || fail "a no-proved-row hold stopped naming the published head it is behind: $st"

# 5b. The index could not be READ: hold, and say so. `no-proved-row` is a claim
#     about what the index contains; making it without reading the index sends
#     the next reader to the prover routine instead of to the node or the
#     network. Holding is correct in both cases, so only the label differs --
#     which is exactly why this survived: the install behaves, the operator is
#     misled. papercut-host-track-reads-any-registry-resolve-failure-as-no-proved-row-20261002
set +e
RESOLVE_UNREADABLE=1 "$ROOT/bin/host-track" refresh --force demo >/dev/null 2>"$tmp/unread.err"
rc=$?
set -e
[ "$rc" -eq 75 ] || fail "unreadable index did not hold (rc=$rc): $(cat "$tmp/unread.err")"
grep -q "registry index could not be read" "$tmp/unread.err" \
  || fail "unreadable index did not say so: $(cat "$tmp/unread.err")"
grep -q "no registry row proved with this LastDB build" "$tmp/unread.err" \
  && fail "an unread index claimed the registry proved nothing: $(cat "$tmp/unread.err")"
[ "$(demo)" = v2 ] || fail "unreadable-index hold changed the install"
st="$(RESOLVE_UNREADABLE=1 "$ROOT/bin/host-track" status --json demo)"
printf '%s\n' "$st" | jq -e '.registry_pin_state == "unreadable"' >/dev/null \
  || fail "an unreadable index rendered some other state: $st"
# Holding must not read as staleness, or `refresh` and force-fresh-if-stale
# restage on every tick of a network blip.
printf '%s\n' "$st" | jq -e '.stale == false' >/dev/null \
  || fail "an unreadable index made the host stale: $st"
printf '%s\n' "$st" | jq -e '. as $r | (["fresh","soft_stale","hard_broken"] | index($r.freshness)) != null' >/dev/null \
  || fail "an unreadable index invented a new freshness value: $st"
# Splitting rc 3 out of rc 2 must change the LABEL and nothing else. Measured
# while writing this: the first version of the split dropped the lag reporting
# from the new arm, and the live row went no-proved-row/soft_stale ->
# unreadable/FRESH -- silently un-fixing
# papercut-host-track-status-renders-stale-false-fresh-when-gate-head-is-unreadable-20261001
# for the unreadable half, with the whole suite green. Assert parity, not the
# literal, so the next split cannot lose it either.
no_row="$(RESOLVE_NO_ROW=1 "$ROOT/bin/host-track" status --json demo)"
unread="$st"
for f in pin_behind_oid freshness stale gate_head; do
  a="$(printf '%s\n' "$no_row" | jq -r --arg f "$f" '.[$f] | tostring')"
  b="$(printf '%s\n' "$unread" | jq -r --arg f "$f" '.[$f] | tostring')"
  [ "$a" = "$b" ] || fail "hold arms disagree on $f: no-proved-row=$a unreadable=$b"
done
# And the two must stay distinguishable on the one field that IS the fix.
printf '%s\n' "$no_row" | jq -e '.registry_pin_state == "no-proved-row"' >/dev/null \
  || fail "the no-proved-row answer stopped being reported as itself: $no_row"

# 5c. The index FETCH fails (the forge-URL arm of registry_index_local_copy).
#     Same class as 5b one level up: a failed curl used to become rc 2, which
#     the renderer labels `no-proved-row`. Hermetic -- `curl` is stubbed and the
#     URL is never dialled; without this case the `|| return 3` on the fetch is
#     unreachable from the suite and reads as coverage it does not have.
cat > "$tmp/bin/curl" <<'SH'
#!/usr/bin/env bash
echo "curl: (7) Failed to connect" >&2
exit 7
SH
chmod +x "$tmp/bin/curl"
jq '.apps[0].registry_index = "http://127.0.0.1:3300/registry"' "$HOST_TRACK_REGISTRY" >"$tmp/r3.json" \
  && mv "$tmp/r3.json" "$HOST_TRACK_REGISTRY"
set +e
"$ROOT/bin/host-track" refresh --force demo >/dev/null 2>"$tmp/fetch.err"
rc=$?
set -e
[ "$rc" -eq 75 ] || fail "a failed index fetch did not hold (rc=$rc): $(cat "$tmp/fetch.err")"
grep -q "registry index could not be read" "$tmp/fetch.err" \
  || fail "a failed index fetch did not say the index was unreadable: $(cat "$tmp/fetch.err")"
grep -q "no registry row proved with this LastDB build" "$tmp/fetch.err" \
  && fail "a failed index fetch claimed the registry proved nothing: $(cat "$tmp/fetch.err")"
st="$("$ROOT/bin/host-track" status --json demo)"
printf '%s\n' "$st" | jq -e '.registry_pin_state == "unreadable" and .stale == false' >/dev/null \
  || fail "a failed index fetch rendered the wrong state, or made the host stale: $st"
[ "$(demo)" = v2 ] || fail "a failed index fetch changed the install"
rm "$tmp/bin/curl"
jq '.apps[0].registry_index = "http://forge.test/registry"' "$HOST_TRACK_REGISTRY" >"$tmp/r4.json" \
  && mv "$tmp/r4.json" "$HOST_TRACK_REGISTRY"

# 6. An app not on the index follows the channel head as before.
publish_fixture plain "$d3" "$oid_three" $'#!/usr/bin/env bash\necho p1'
"$ROOT/bin/host-track" install plain >/dev/null
[ "$(plain)" = p1 ] || fail "not-on-index app did not install from the channel"
st="$("$ROOT/bin/host-track" status --json plain)"
printf '%s\n' "$st" | jq -e '.registry_pin_state == "not-on-index" and .stale == false' >/dev/null || fail "not-on-index status: $st"

# 7. registry_follow=false opts an app out entirely.
jq '.apps[0].registry_follow = false' "$HOST_TRACK_REGISTRY" >"$tmp/r2.json" && mv "$tmp/r2.json" "$HOST_TRACK_REGISTRY"
st="$("$ROOT/bin/host-track" status --json demo)"
printf '%s\n' "$st" | jq -e '.registry_channel == null' >/dev/null || fail "registry_follow=false still pinned: $st"

# 8. `registry_app` maps the host-track app name to the registry app id, and the
#    newest-row read must honour it. `last-stack-why-stopped` cannot: it reads
#    `status --json`, which does not expose the mapping, so it guesses the
#    host-track name. The producer HAS the mapping, which is the reason the read
#    belongs here rather than in each consumer. No app sets it today, so without
#    this case the `reg_app` line is dead to the suite.
jq '.apps[0].registry_follow = true | .apps[0].registry_app = "demo-reg"' "$HOST_TRACK_REGISTRY" \
  >"$tmp/r5.json" && mv "$tmp/r5.json" "$HOST_TRACK_REGISTRY"
printf '{"demo-reg":"%s"}\n' "$oid_one" >"$tmp/resolve.json"
: >"$tmp/info-calls.log"
st="$(INFO_NEWEST_VERSION=0.23.3-9-gother "$ROOT/bin/host-track" status --json demo)"
printf '%s\n' "$st" | jq -e --arg oid "$oid_four" \
  '.pin_behind_oid == $oid and .registry_index_build_match == "mismatch"' >/dev/null \
  || fail "a mapped registry_app did not reach the newest-row read: $st"
grep -q -- "info demo-reg --channel next" "$tmp/info-calls.log" \
  || fail "app info was asked about the host-track name, not the mapped registry id: $(cat "$tmp/info-calls.log")"
grep -q -- "info demo --channel" "$tmp/info-calls.log" \
  && fail "app info was asked about the unmapped name: $(cat "$tmp/info-calls.log")"

printf 'PASS host-track-registry-pin\n'
