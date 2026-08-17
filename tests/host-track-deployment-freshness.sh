#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

remote="$tmp/fold.git"
seed="$tmp/seed"
cache="$tmp/cache.git"
current="$tmp/current"
registry="$tmp/registry.json"
refresh_marker="$tmp/refresh-ran"
mkdir -p "$seed" "$current"
git init -q --bare "$remote"
git init -q -b main "$seed"
git -C "$seed" config user.name test
git -C "$seed" config user.email test@example.com
printf 'one\n' > "$seed/file.txt"
git -C "$seed" add file.txt
git -C "$seed" commit -q -m one
installed_oid="$(git -C "$seed" rev-parse HEAD)"
git -C "$seed" remote add origin "$remote"
git -C "$seed" push -q origin main
printf 'two\n' > "$seed/file.txt"
git -C "$seed" commit -qam two
gate_oid="$(git -C "$seed" rev-parse HEAD)"
git -C "$seed" push -q origin main
git clone -q --bare "$remote" "$cache"

write_binary() {
  local path="$1" oid="$2" name="$3"
  printf '#!/usr/bin/env bash\nprintf "%%s 0.23.3-test-g%%s\\n" %s %s\n' \
    "$name" "$oid" > "$path"
  chmod +x "$path"
}
write_binary "$current/lastdb" "${installed_oid:0:12}" lastdb
write_binary "$current/lastdbd" "${installed_oid:0:12}" lastdbd

printf '#!/usr/bin/env bash\ntouch %q\n' "$refresh_marker" > "$tmp/forbidden-refresh"
chmod +x "$tmp/forbidden-refresh"

cat > "$registry" <<EOF
{
  "apps": [
    {
      "app": "lastdbd",
      "install_mode": "checkout",
      "kind": "safe-upgrade-managed binary",
      "command": "lastdbd",
      "gate": "forgejo",
      "gate_remote": "$remote",
      "gate_ref": "refs/heads/main",
      "deployment_binary": "$current/lastdbd",
      "deployment_peer_binary": "$current/lastdb",
      "deployment_repo_cache": "$cache",
      "refresh": "$tmp/forbidden-refresh",
      "artifact_exemption": {
        "kind": "deployment-only",
        "owner": "platform",
        "rationale": "safe upgrade only"
      }
    }
  ]
}
EOF

export HOST_TRACK_REGISTRY="$registry"
export HOST_TRACK_STAMP_DIR="$tmp/stamps"

stale_status="$("$ROOT/bin/host-track" status --json lastdbd)"
printf '%s\n' "$stale_status" | jq -e \
  --arg installed "$installed_oid" --arg gate "$gate_oid" '
    .host_head == $installed
    and .gate_head == $gate
    and .behind_by == 1
    and .binary_pair_match == true
    and .deployment_problem == null
    and .stale == true
    and .freshness == "soft_stale"
  ' >/dev/null || fail "deployment-only lag was not measured: $stale_status"

stale_list="$("$ROOT/bin/host-track" status --stale --json)"
printf '%s\n' "$stale_list" | jq -e \
  'length == 1 and .[0].app == "lastdbd"' >/dev/null \
  || fail "status --stale did not list the lagging primary: $stale_list"

set +e
refresh_error="$("$ROOT/bin/host-track" refresh lastdbd 2>&1)"
refresh_rc=$?
set -e
[ "$refresh_rc" -eq 3 ] || fail "deployment-only refresh returned $refresh_rc instead of refusal"
printf '%s\n' "$refresh_error" | grep -q 'deployment-only.*lastdb-safe-upgrade' \
  || fail "deployment-only refresh did not explain the safe-upgrade boundary"
[ ! -e "$refresh_marker" ] || fail "deployment-only refresh helper ran"

write_binary "$current/lastdb" "${gate_oid:0:12}" lastdb
pair_status="$("$ROOT/bin/host-track" status --json lastdbd)"
printf '%s\n' "$pair_status" | jq -e \
  '.binary_pair_match == false
   and .deployment_problem == "installed binary pair disagrees"
   and .stale == true
   and .freshness == "hard_broken"' >/dev/null \
  || fail "binary-pair mismatch was not surfaced: $pair_status"

write_binary "$current/lastdbd" "${gate_oid:0:12}" lastdbd
fresh_status="$("$ROOT/bin/host-track" status --json lastdbd)"
printf '%s\n' "$fresh_status" | jq -e \
  --arg gate "$gate_oid" '
    .host_head == $gate
    and .gate_head == $gate
    and .behind_by == 0
    and .binary_pair_match == true
    and .stale == false
    and .freshness == "fresh"
  ' >/dev/null || fail "safe-upgrade cutover did not report fresh: $fresh_status"
fresh_list="$("$ROOT/bin/host-track" status --stale --json)"
printf '%s\n' "$fresh_list" | jq -e 'length == 0' >/dev/null \
  || fail "status --stale retained a current deployment: $fresh_list"

printf 'PASS host-track deployment-only freshness\n'
