#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
HOST_TRACK_BIN="${HOST_TRACK_BIN:-$ROOT/bin/host-track}"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

installed_oid="1111111111111111111111111111111111111111"
tip_oid="2222222222222222222222222222222222222222"
home="$tmp/home"
install_root="$tmp/install/toy"
fake_bin="$tmp/bin"
refresh_count="$tmp/refresh-count"
registry="$tmp/registry.json"
stamp_dir="$tmp/stamps"

mkdir -p \
  "$home" \
  "$fake_bin" \
  "$install_root/versions/$installed_oid/bin" \
  "$install_root/versions/$tip_oid/bin" \
  "$stamp_dir"
ln -s "versions/$installed_oid" "$install_root/current"

cat > "$fake_bin/lastgit" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = "status" ] || exit 2
printf '{"refs":[{"name":"refs/heads/main","oid":"%s"}]}\n' "$HOST_TRACK_TEST_TIP"
SH

cat > "$fake_bin/toy" <<'SH'
#!/usr/bin/env bash
printf 'toy\n'
SH

cat > "$tmp/refresh-to-tip" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
ln -sfn "versions/$HOST_TRACK_TEST_TIP" "$HOST_TRACK_TEST_INSTALL/current"
printf 'refresh\n' >> "$HOST_TRACK_TEST_REFRESH_COUNT"
SH
chmod +x "$fake_bin/lastgit" "$fake_bin/toy" "$tmp/refresh-to-tip"

cat > "$registry" <<EOF
{
  "apps": [
    {
      "app": "toy",
      "install_mode": "local-safe",
      "kind": "local-safe cli",
      "command": "toy",
      "gate": "lastgit",
      "gate_main": "lastdb:///toy#main",
      "install_root": "$install_root",
      "refresh": "$tmp/refresh-to-tip"
    }
  ]
}
EOF

cat > "$stamp_dir/toy.json" <<EOF
{
  "app": "toy",
  "install_mode": "local-safe",
  "version_id": "$installed_oid",
  "current": "versions/$installed_oid"
}
EOF

export HOME="$home"
export PATH="$fake_bin:/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"
export HOST_TRACK_REGISTRY="$registry"
export HOST_TRACK_STAMP_DIR="$stamp_dir"
export HOST_TRACK_TEST_TIP="$tip_oid"
export HOST_TRACK_TEST_INSTALL="$install_root"
export HOST_TRACK_TEST_REFRESH_COUNT="$refresh_count"

stale_status="$("$HOST_TRACK_BIN" status --json toy)"
printf '%s\n' "$stale_status" | jq -e \
  --arg installed "$installed_oid" \
  --arg tip "$tip_oid" \
  '.install_mode == "local-safe"
   and .host_head == $installed
   and .gate_head == $tip
   and .stale == true' >/dev/null \
  || fail "installed A versus product tip B did not report stale with both oids"

"$HOST_TRACK_BIN" refresh toy >/dev/null
fresh_status="$("$HOST_TRACK_BIN" status --json toy)"
printf '%s\n' "$fresh_status" | jq -e \
  --arg tip "$tip_oid" \
  '.host_head == $tip and .gate_head == $tip and .stale == false' >/dev/null \
  || fail "refresh did not advance local-safe current to the product tip"
[ "$(wc -l < "$refresh_count" | tr -d ' ')" = "1" ] \
  || fail "stale refresh did not invoke the refresher exactly once"

"$HOST_TRACK_BIN" refresh toy >/dev/null
[ "$(wc -l < "$refresh_count" | tr -d ' ')" = "1" ] \
  || fail "already-current local-safe refresh invoked the refresher again"

printf 'PASS host-track local-safe product-tip staleness and refresh\n'
