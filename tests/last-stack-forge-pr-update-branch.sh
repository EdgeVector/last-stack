#!/usr/bin/env bash
# Proof: last-stack-forge-pr-update-branch never updates a PR branch while a
# CI run on its head is pending/running, and updates it when CI is terminal
# (papercut-forge-pr-branch-update-cancels-in-flight-ci-20260922).
# Fake forge API; no network.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
helper="$ROOT/bin/last-stack-forge-pr-update-branch"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

sha="0123456789abcdef0123456789abcdef01234567"
cat >"$tmp/forge-api" <<EOF
#!/usr/bin/env bash
method=GET; path=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --method) method="\$2"; shift 2 ;;
    *) path="\$1"; shift ;;
  esac
done
case "\$method \$path" in
  "GET repos/EdgeVector/last-stack/pulls/7")
    printf '%s\n' "\${FAKE_PR:-{\"state\":\"open\",\"merged\":false,\"head\":{\"sha\":\"$sha\"}}}" ;;
  "GET repos/EdgeVector/last-stack/commits/$sha/status")
    printf '%s\n' "\${FAKE_STATUS:?}" ;;
  "POST repos/EdgeVector/last-stack/pulls/7/update")
    echo update >>"\${FAKE_UPDATES:?}"; printf '{}\n' ;;
  *) echo "unexpected: \$method \$path" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/forge-api"
export LAST_STACK_FORGE_API="$tmp/forge-api"
export FAKE_UPDATES="$tmp/updates"

fail=0
check() { # name expected_rc expected_verdict status_json [extra args]
  local name="$1" want_rc="$2" want="$3" status="$4"; shift 4
  : >"$FAKE_UPDATES"
  local out rc=0
  out="$(FAKE_STATUS="$status" "$helper" --repo EdgeVector/last-stack --pr 7 "$@")" || rc=$?
  if [ "$rc" != "$want_rc" ] || ! printf '%s' "$out" | grep -q "\"verdict\": \"$want\""; then
    echo "FAIL $name: rc=$rc out=$out" >&2
    fail=1
  fi
}

running='{"state":"pending","total_count":1,"statuses":[{"context":"Forge CI / ci-required (pull_request)","status":"pending"}]}'
green='{"state":"success","total_count":1,"statuses":[{"context":"Forge CI / ci-required (pull_request)","status":"success"}]}'
red='{"state":"failure","total_count":1,"statuses":[{"context":"Forge CI / ci-required (pull_request)","status":"failure"}]}'
none='{"state":"","total_count":0,"statuses":[]}'

check running-probe 3 deny "$running"
check running-apply 3 deny "$running" --apply
if [ -s "$FAKE_UPDATES" ]; then echo "FAIL: updated a branch while CI ran" >&2; fail=1; fi
check green-probe 0 allow "$green"
if [ -s "$FAKE_UPDATES" ]; then echo "FAIL: probe mode updated the branch" >&2; fail=1; fi
check green-apply 0 updated "$green" --apply
if [ ! -s "$FAKE_UPDATES" ]; then echo "FAIL: green --apply did not update" >&2; fail=1; fi
check red-apply 0 updated "$red" --apply
check no-status 0 allow "$none"
check unreadable 3 deny 'not json'
FAKE_PR='{"state":"closed","merged":true,"head":{"sha":"'"$sha"'"}}' check merged 3 deny "$green" --apply

[ "$fail" -eq 0 ] || exit 1
echo "ok last-stack-forge-pr-update-branch"
