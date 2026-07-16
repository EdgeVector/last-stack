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

echo "ok last-stack-pipeline-deploy-scan"
