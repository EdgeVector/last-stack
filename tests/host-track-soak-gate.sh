#!/usr/bin/env bash
# The soak gate counts as well as waits, a red soak opens ONE incident that
# keeps its heal key across digests, and the post-flip watch rolls back on
# red. All against a sandbox registry + stub helpers — no live installs.
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
export HOST_TRACK_STAMP_DIR="$tmp/stamps"
mkdir -p "$HOME" "$tmp/stamps"

install_root="$tmp/apps/demo"
artifact_root="$tmp/artifacts"
mkdir -p "$install_root/versions/digestaaaa" "$install_root/versions/digestbbbb" \
  "$install_root/versions/digestcccc" "$artifact_root"

# Probe stub: a shared marker fails every version; a digest marker fails one.
for d in digestaaaa digestbbbb digestcccc; do
  mkdir -p "$install_root/versions/$d/bin"
  cat > "$install_root/versions/$d/bin/probe" <<EOF
#!/usr/bin/env bash
[ ! -f "$tmp/probe-shared-red" ]
[ ! -f "$tmp/probe-red-$d" ]
EOF
  chmod +x "$install_root/versions/$d/bin/probe"
done

# Card, heal, and ship-soak stubs record their argv.
cat > "$tmp/file-pr-stub" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$tmp/file-pr-calls"
exit 0
EOF
cat > "$tmp/heal-stub" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$tmp/heal-calls"
exit 0
EOF
cat > "$tmp/ship-soak-tick-stub" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$tmp/ship-soak-tick-calls"
exit 0
EOF
chmod +x "$tmp/file-pr-stub" "$tmp/heal-stub" "$tmp/ship-soak-tick-stub"
export HOST_TRACK_FILE_PR="$tmp/file-pr-stub"
export HOST_TRACK_SOAK_HEAL_RUNNER="$tmp/heal-stub"
export HOST_TRACK_SHIP_SOAK_TICK_RUNNER="$tmp/ship-soak-tick-stub"

registry="$tmp/registry.json"
cat > "$registry" <<EOF
{
  "defaults": {
    "install_mode": "artifact",
    "artifact_root": "$artifact_root",
    "safe_upgrade": { "soak_hours": 1, "min_checks": 3, "post_flip_ticks": 2 }
  },
  "apps": [
    {
      "app": "demo",
      "kind": "artifact-bundle",
      "command": "demo",
      "install_mode": "artifact",
      "install_root": "$install_root",
      "artifact_root": "$artifact_root",
      "links": [{"source": "bin/probe", "target": "$HOME/.local/bin/demo"}],
      "notes": "soak gate fixture",
      "safe_upgrade": {
        "probes": [
          {"argv": ["bin/probe"], "timeout_s": 10},
          {"argv": ["bin/probe"], "timeout_s": 10}
        ]
      }
    }
  ]
}
EOF
export HOST_TRACK_REGISTRY="$registry"

ht() { "$ROOT/bin/host-track" "$@"; }
stamp="$HOST_TRACK_STAMP_DIR/demo.soak.json"
old_epoch=$(( $(date +%s) - 7200 ))

# --- 1. min_checks gate: window elapsed but too few checks → no flip -------
ln -sfn versions/digestaaaa "$install_root/current"
ln -sfn versions/digestbbbb "$install_root/canary"
jq -n --argjson started "$old_epoch" \
  '{app:"demo", digest:"digestbbbb", status:"soaking", soak_hours:1,
    started_epoch:$started, checks:1}' > "$stamp"

out="$(ht soak-watch demo 2>&1)" || fail "green tick should exit 0: $out"
printf '%s\n' "$out" | grep -q 'soak pending .* checks=2/3' \
  || fail "expected pending at checks=2/3, got: $out"
[ "$(readlink "$install_root/current")" = "versions/digestaaaa" ] \
  || fail "current must not flip below min_checks"
grep -q -- '--app demo --quiet' "$tmp/ship-soak-tick-calls" \
  || fail "each Host Track tick should resume ship-soak runs for its app"

# --- 2. checks reach min over an elapsed window → activation attempted -----
out="$(ht soak-watch demo 2>&1)" || true
printf '%s\n' "$out" | grep -q 'soak GREEN .*checks=3/3.*activating' \
  || fail "expected GREEN activation at checks=3/3, got: $out"

# --- 3. red soak: stamp red, card filed once, heal kicked with card key ----
rm -f "$stamp"
jq -n --argjson started "$old_epoch" \
  '{app:"demo", digest:"digestbbbb", status:"soaking", soak_hours:1,
    started_epoch:$started, checks:1}' > "$stamp"
touch "$tmp/probe-red-digestbbbb"
ship_ticks_before_red="$(wc -l < "$tmp/ship-soak-tick-calls" | tr -d ' ')"
if ht soak-watch demo >"$tmp/red.out" 2>&1; then
  fail "red soak should exit nonzero: $(cat "$tmp/red.out")"
fi
[ "$(jq -r '.status' "$stamp")" = "soak_red" ] || fail "stamp should be soak_red"
slug="$(jq -r '.card_slug' "$stamp")"
[ "$slug" = "soak-red-demo-digestbbbb" ] || fail "unexpected incident slug: $slug"
grep -q -- "--key $slug" "$tmp/heal-calls" || fail "heal kick should use the card slug key"
[ "$(wc -l < "$tmp/file-pr-calls")" -eq 1 ] || fail "exactly one card filing expected"
[ "$(wc -l < "$tmp/ship-soak-tick-calls" | tr -d ' ')" -eq $((ship_ticks_before_red + 1)) ] \
  || fail "a red Host Track tick should still resume ship-soak"

# --- 4. incident keying: a successor digest's red joins the SAME incident --
ln -sfn versions/digestcccc "$install_root/canary"
touch "$tmp/probe-red-digestcccc"
# park_canary path preserved card_slug via write_soak_stamp; emulate the
# successor park the way refresh does: new digest, no explicit slug.
jq -n --argjson started "$old_epoch" --arg slug "$slug" \
  '{app:"demo", digest:"digestcccc", status:"soaking", soak_hours:1,
    started_epoch:$started, checks:1, card_slug:$slug}' > "$stamp"
if ht soak-watch demo >"$tmp/red2.out" 2>&1; then
  fail "second red should exit nonzero"
fi
[ "$(wc -l < "$tmp/file-pr-calls")" -eq 1 ] \
  || fail "successor digest must NOT open a second card: $(cat "$tmp/file-pr-calls")"
grep -c -- "--key $slug" "$tmp/heal-calls" >/dev/null \
  || fail "successor red should reuse the incident heal key"
tail -1 "$tmp/heal-calls" | grep -q -- "--key $slug" \
  || fail "heal key drifted across digests: $(tail -1 "$tmp/heal-calls")"

# --- 5. post-flip watch: green decrements; red rolls back to previous ------
rm -f "$tmp/probe-red-digestbbbb" "$tmp/probe-red-digestcccc" "$stamp"
rm -f "$install_root/canary"
ln -sfn versions/digestbbbb "$install_root/current"
ln -sfn versions/digestaaaa "$install_root/previous"
postflip="$HOST_TRACK_STAMP_DIR/demo.postflip.json"
jq -n '{app:"demo", digest:"digestbbbb", ticks_left:2, flipped_at:"t"}' > "$postflip"

out="$(ht soak-watch demo 2>&1)" || fail "green post-flip tick should pass: $out"
printf '%s\n' "$out" | grep -q 'post-flip watch green; ticks_left=1' \
  || fail "expected ticks_left=1, got: $out"

touch "$tmp/probe-red-digestbbbb"
if ht soak-watch demo >"$tmp/pf.out" 2>&1; then
  fail "red post-flip should exit nonzero: $(cat "$tmp/pf.out")"
fi
grep -q 'post-flip RED; rolling back to previous' "$tmp/pf.out" \
  || fail "expected rollback message: $(cat "$tmp/pf.out")"
[ "$(readlink "$install_root/current")" = "versions/digestaaaa" ] \
  || fail "post-flip red must roll current back to previous"
[ ! -f "$postflip" ] || fail "post-flip stamp should be cleared after rollback"

# --- 6. green soak activation archives the stamp (incident closes) ---------
rm -f "$tmp/probe-red-digestbbbb"
ln -sfn versions/digestbbbb "$install_root/canary"
ln -sfn versions/digestbbbb "$install_root/current"
jq -n '{app:"demo", digest:"digestbbbb", status:"soaking", soak_hours:1,
  started_epoch:1, checks:5, card_slug:"soak-red-demo-digestbbbb"}' > "$stamp"
out="$(ht soak-watch demo 2>&1)" || fail "already-current tick should pass: $out"
[ ! -f "$stamp" ] || fail "stamp should be archived once canary is current"
ls "$HOST_TRACK_STAMP_DIR/soak-history/" | grep -q '^demo-digestbbbb' \
  || fail "archived stamp missing from soak-history"

printf 'ok: host-track soak gate, incident keying, Loom resume, post-flip watch\n'
