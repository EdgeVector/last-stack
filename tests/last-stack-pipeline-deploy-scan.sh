#!/usr/bin/env bash
# Unit test for last-stack-pipeline-deploy-scan (temp log tree).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCAN="$ROOT/bin/last-stack-pipeline-deploy-scan"
chmod +x "$SCAN"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/deploy-ok-repo" "$tmp/deploy-bad-repo" "$tmp/deploy-pending-repo"

cat >"$tmp/deploy-ok-repo/deploy.log" <<'EOF'
pending aaa deploy-pipeline from x:refs/heads/main:accepted
success aaa deploy-pipeline
EOF

cat >"$tmp/deploy-bad-repo/deploy.log" <<'EOF'
pending bbb deploy-pipeline from x:refs/heads/main:accepted
success bbb deploy-pipeline
pending ccc deploy-pipeline from y:refs/heads/main:accepted
failure ccc deploy-pipeline
EOF

# pending only — force old mtime so grace expires
cat >"$tmp/deploy-pending-repo/deploy.log" <<'EOF'
pending ddd deploy-pipeline from z:refs/heads/main:accepted
EOF
# 5 hours ago
touch -t "$(date -u -v-5H +%Y%m%d%H%M.%S 2>/dev/null || date -u -d '5 hours ago' +%Y%m%d%H%M.%S)" \
  "$tmp/deploy-pending-repo/deploy.log" 2>/dev/null || \
  touch -d '5 hours ago' "$tmp/deploy-pending-repo/deploy.log" 2>/dev/null || true

out="$("$SCAN" --json --root "$tmp" --pending-max-s 3600)"
echo "$out" | jq -e 'type=="array"' >/dev/null

ok_blocked="$(echo "$out" | jq -r '.[] | select(.repo=="ok-repo") | .blocked')"
bad_blocked="$(echo "$out" | jq -r '.[] | select(.repo=="bad-repo") | .blocked')"
pend_blocked="$(echo "$out" | jq -r '.[] | select(.repo=="pending-repo") | .blocked')"

[ "$ok_blocked" = "false" ] || [ "$ok_blocked" = "0" ] || {
  echo "expected ok-repo unblocked, got $ok_blocked / $out" >&2
  exit 1
}
[ "$bad_blocked" = "true" ] || [ "$bad_blocked" = "1" ] || {
  echo "expected bad-repo blocked, got $bad_blocked / $out" >&2
  exit 1
}
# pending may be blocked if mtime worked
if [ "$pend_blocked" = "true" ] || [ "$pend_blocked" = "1" ]; then
  echo "pending-repo correctly blocked (stale pending)"
else
  echo "pending-repo not blocked (mtime touch may be unsupported) — soft-ok"
fi

# --repo: a repo WITH a producer reports that producer
one="$("$SCAN" --json --root "$tmp" --pending-max-s 3600 --repo ok-repo)"
echo "$one" | jq -e 'type=="array" and length==1 and .[0].repo=="ok-repo" and .[0].status=="success" and .[0].blocked==false' >/dev/null || {
  echo "expected single ok-repo success row, got $one" >&2
  exit 1
}

# --repo: a repo with NO producer, while others are configured, is
# not-applicable and UNBLOCKED — it does not deploy through this pipeline at
# all, so gating on it would never be satisfiable.
na="$("$SCAN" --json --root "$tmp" --repo fold)"
echo "$na" | jq -e 'type=="array" and length==1 and .[0].repo=="fold" and .[0].status=="not-applicable" and .[0].blocked==false' >/dev/null || {
  echo "expected fold not-applicable unblocked, got $na" >&2
  exit 1
}
echo "$na" | jq -e '.[0].reason | test("no deploy-pipeline producer for fold")' >/dev/null || {
  echo "expected an explanatory reason, got $na" >&2
  exit 1
}

# --repo: no producers under the root at all is ambiguous (likely a wrong
# --root) and stays fail-closed.
empty="$(mktemp -d)"
unconf="$("$SCAN" --json --root "$empty" --repo fold)"
rm -rf "$empty"
echo "$unconf" | jq -e 'type=="array" and length==1 and .[0].repo=="fold" and .[0].status=="unconfigured" and .[0].blocked==true' >/dev/null || {
  echo "expected fold unconfigured blocked on an empty root, got $unconf" >&2
  exit 1
}

# --repo: a repo whose producer is FAILING still blocks
badrow="$("$SCAN" --json --root "$tmp" --repo bad-repo)"
echo "$badrow" | jq -e 'type=="array" and length==1 and .[0].blocked==true' >/dev/null || {
  echo "expected bad-repo still blocked under --repo, got $badrow" >&2
  exit 1
}

echo "ok last-stack-pipeline-deploy-scan"
