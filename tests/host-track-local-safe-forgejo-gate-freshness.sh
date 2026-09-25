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
main_ahead_oid="2222222222222222222222222222222222222222"
home="$tmp/home"
install_root="$tmp/install/toy"
fake_bin="$tmp/bin"
registry="$tmp/registry.json"
stamp_dir="$tmp/stamps"

mkdir -p \
  "$home" \
  "$fake_bin" \
  "$install_root/versions/$installed_oid/bin" \
  "$install_root/versions/$main_ahead_oid/bin" \
  "$stamp_dir"
ln -s "versions/$installed_oid" "$install_root/current"

cat > "$fake_bin/toy" <<'SH'
#!/usr/bin/env bash
printf 'toy\n'
SH
chmod +x "$fake_bin/toy"

cat > "$registry" <<EOF
{
  "apps": [
    {
      "app": "toy",
      "install_mode": "local-safe",
      "kind": "local-safe cli",
      "command": "toy",
      "gate": "http://localhost:3300",
      "gate_main": "http://localhost:3300/EdgeVector/toy#main",
      "gate_remote": "http://localhost:3300/EdgeVector/toy.git",
      "gate_ref": "refs/heads/main",
      "install_root": "$install_root",
      "refresh": "/bin/true"
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

# Mock git command to return different oids for different operations
cat > "$fake_bin/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# For ls-remote queries against our test Forgejo gate, return main_ahead_oid
if [[ "$*" == *"ls-remote"* ]] && [[ "$*" == *"localhost:3300"* ]]; then
  printf '%s\trefs/heads/main\n' "$HOST_TRACK_TEST_MAIN_AHEAD"
  exit 0
fi
# Fallback to real git for other operations
exec /usr/bin/git "$@"
SH
chmod +x "$fake_bin/git"

export HOME="$home"
export PATH="$fake_bin:/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"
export HOST_TRACK_REGISTRY="$registry"
export HOST_TRACK_STAMP_DIR="$stamp_dir"
export HOST_TRACK_TEST_MAIN_AHEAD="$main_ahead_oid"

# Check status: when main is ahead and install is not, should be stale and soft_stale freshness
status="$("$HOST_TRACK_BIN" status --json toy)"

# Debug output
printf 'Status JSON: %s\n' "$status" >&2

printf '%s\n' "$status" | jq -e \
  --arg installed "$installed_oid" \
  --arg ahead "$main_ahead_oid" \
  '.install_mode == "local-safe"
   and .host_head == $installed
   and .gate_head == $ahead
   and .stale == true
   and .freshness == "soft_stale"' >/dev/null \
  || fail "local-safe with Forgejo gate: main ahead should be stale=true and freshness=soft_stale"

printf 'PASS host-track local-safe Forgejo gate freshness\n'
