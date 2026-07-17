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

kanban_registry="$(jq -c '.apps[] | select(.app == "kanban")' "$ROOT/config/host-track/apps.json")"
printf '%s\n' "$kanban_registry" | jq -e '
  .kind == "B checkout-shim" and
  .gate == "lastgit" and
  .gate_main == "lastdb:///fkanban#main" and
  .gate_remote == "lastgit" and
  .gate_ref == "refs/heads/main" and
  .host_track == "$HOME/.host-track/fkanban" and
  .refresh == "$HOME/.local/bin/kanban-host-track-refresh"
' >/dev/null || fail "default kanban registry entry is not a real host-track target"
printf '%s\n' "$kanban_registry" | jq -e '.notes | test("Placeholder") | not' >/dev/null \
  || fail "default kanban registry entry still looks like a placeholder"

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
ln -s "$ROOT/bin/host-track" "$fake_bin/host-track"

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

last_stack_remote="$tmp/last-stack-remote.git"
last_stack_seed="$tmp/last-stack-seed"
last_stack_host="$tmp/last-stack-host"
git init --bare -q "$last_stack_remote"
git init -q -b main "$last_stack_seed"
git -C "$last_stack_seed" config user.email test@example.invalid
git -C "$last_stack_seed" config user.name "Host Track Test"
printf '1.2.3-test\n' > "$last_stack_seed/VERSION"
git -C "$last_stack_seed" add VERSION
git -C "$last_stack_seed" commit -q -m "last-stack seed"
git -C "$last_stack_seed" remote add lastgit "$last_stack_remote"
git -C "$last_stack_seed" push -q lastgit main
git clone -q "$last_stack_remote" "$last_stack_host"
git -C "$last_stack_host" remote rename origin lastgit
cat > "$last_stack_host/setup" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'setup\n' > "$(dirname "$0")/.setup-ran"
SH
chmod +x "$last_stack_host/setup"

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
    },
    {
      "app": "last-stack",
      "kind": "C skill-pack",
      "command": "host-track",
      "gate": "lastgit",
      "gate_main": "$last_stack_remote#main",
      "gate_remote": "lastgit",
      "gate_ref": "refs/heads/main",
      "host_track": "$last_stack_host",
      "refresh_mode": "last-stack-self-upgrade",
      "notes": "test last-stack"
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

last_stack_status="$("$ROOT/bin/host-track" status --json last-stack)"
printf '%s\n' "$last_stack_status" | jq -e '.app == "last-stack"' >/dev/null || fail "last-stack status app mismatch"
printf '%s\n' "$last_stack_status" | jq -e '.kind == "C skill-pack"' >/dev/null || fail "last-stack kind mismatch"
printf '%s\n' "$last_stack_status" | jq -e '.version == "1.2.3-test"' >/dev/null || fail "last-stack VERSION missing"
printf '%s\n' "$last_stack_status" | jq -e '.host_head and .host_head_short' >/dev/null || fail "last-stack HEAD missing"
last_stack_which="$("$ROOT/bin/host-track" which last-stack --json)"
printf '%s\n' "$last_stack_which" | jq -e '.exec_path | endswith("/host-track")' >/dev/null \
  || fail "which --json did not report host-track executable"
printf '%s\n' "$last_stack_which" | jq -e '.version == "1.2.3-test" and .host_head' >/dev/null \
  || fail "which --json did not include VERSION and HEAD"

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
printf 'dirty\n' > "$last_stack_host/dirty.txt"
if "$ROOT/bin/host-track" refresh --force last-stack >/dev/null 2>&1; then
  fail "dirty fallback last-stack refresh succeeded"
fi

printf '%s\n' "$("$ROOT/bin/host-track" status --json)" | jq -e 'length == 2 and .[0].app == "fake" and .[1].app == "last-stack"' >/dev/null \
  || fail "status --json did not return registry array"

plain_status="$("$ROOT/bin/host-track" status)"
printf '%s\n' "$plain_status" | grep -q $'^app=fake\t' || fail "plain status missing fake app"
printf '%s\n' "$plain_status" | grep -q $'^app=last-stack\t' || fail "plain status missing last-stack app"
plain_count="$(printf '%s\n' "$plain_status" | grep -c '^app=')"
[ "$plain_count" -eq 2 ] || fail "plain status returned $plain_count app rows"

echo "ok: host-track status/check/which/refresh"
