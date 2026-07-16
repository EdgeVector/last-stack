#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

export HOME="$tmp/home"
mkdir -p "$HOME/.local/bin"

fake_bin="$tmp/fake-bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/fakeapp" <<'SH'
#!/usr/bin/env bash
echo fakeapp
SH
chmod +x "$fake_bin/fakeapp"
export PATH="$fake_bin:/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"

remote="$tmp/remote.git"
seed="$tmp/seed"
host="$tmp/host"
git init --bare -q "$remote"
git init -q -b main "$seed"
git -C "$seed" config user.email test@example.invalid
git -C "$seed" config user.name "Host Track Test"
printf 'one\n' > "$seed/file.txt"
git -C "$seed" add file.txt
git -C "$seed" commit -q -m initial
git -C "$seed" remote add origin "$remote"
git -C "$seed" push -q origin main
git clone -q "$remote" "$host"

cat > "$host/refresh-host.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
git -C "$(dirname "$0")" fetch origin main
git -C "$(dirname "$0")" merge --ff-only origin/main
SH
chmod +x "$host/refresh-host.sh"

registry="$tmp/registry.json"
cat > "$registry" <<EOF
{
  "apps": [
    {
      "app": "fake",
      "kind": "A compile",
      "command": "fakeapp",
      "gate": "test",
      "gate_main": "$remote#main",
      "gate_remote": "origin",
      "gate_ref": "refs/heads/main",
      "host_track": "$host",
      "refresh": "$host/refresh-host.sh",
      "notes": "test app"
    }
  ]
}
EOF

stamp_dir="$tmp/stamps"
export HOST_TRACK_REGISTRY="$registry"
export HOST_TRACK_STAMP_DIR="$stamp_dir"

status="$("$ROOT/bin/host-track" status --json fake)"
printf '%s\n' "$status" | jq -e '.app == "fake"' >/dev/null || fail "status app mismatch"
printf '%s\n' "$status" | jq -e '.exec_path | endswith("/fakeapp")' >/dev/null || fail "status missing executable"
printf '%s\n' "$status" | jq -e '.stale == false' >/dev/null || fail "fresh host reported stale"

"$ROOT/bin/host-track" which fake | grep -q '/fakeapp$' || fail "which did not print fakeapp"
"$ROOT/bin/host-track" check fake >/dev/null || fail "fresh check failed"

printf 'two\n' > "$seed/file.txt"
git -C "$seed" add file.txt
git -C "$seed" commit -q -m update
git -C "$seed" push -q origin main

stale="$("$ROOT/bin/host-track" status --json fake)"
printf '%s\n' "$stale" | jq -e '.stale == true' >/dev/null || fail "stale host was not detected"
if "$ROOT/bin/host-track" check fake >/dev/null 2>&1; then
  fail "stale check succeeded"
fi

"$ROOT/bin/host-track" refresh fake >/dev/null
fresh="$("$ROOT/bin/host-track" status --json fake)"
printf '%s\n' "$fresh" | jq -e '.stale == false' >/dev/null || fail "refresh did not catch up"
test -s "$stamp_dir/fake.json" || fail "refresh did not write stamp"
printf '%s\n' "$("$ROOT/bin/host-track" status --json)" | jq -e 'length == 1 and .[0].app == "fake"' >/dev/null \
  || fail "status --json did not return registry array"

echo "ok: host-track status/check/which/refresh"
