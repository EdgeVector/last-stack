#!/usr/bin/env bash
# Compound proof: merged-card closeout honors Requires-Deploy and the deploy
# status reader stays bounded on large logs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
closeout="$ROOT/bin/last-stack-card-closeout"
scan="$ROOT/bin/last-stack-pipeline-deploy-scan"
chmod +x "$closeout" "$scan"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

board="$tmp/fkanban"
state="$tmp/column"
body="$tmp/body"
moves="$tmp/moves"
deploy_root="$tmp/deploy-root"
mkdir -p "$deploy_root/deploy-schema-infra"
printf 'doing\n' >"$state"
cat >"$body" <<'EOF'
Repo: EdgeVector/schema-infra
Base: main
Kind: pr
Requires-Status: ci-required
Requires-Deploy: deploy-pipeline

## DONE WHEN
Merged CR plus terminal deploy-pipeline success.
EOF

cat >"$board" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state="${FAKE_BOARD_STATE:?}"
body="${FAKE_BOARD_BODY:?}"
moves="${FAKE_BOARD_MOVES:?}"
case "${1:-}" in
  show)
    printf '{"slug":"%s","repo":"EdgeVector/schema-infra","column":"%s","body":%s}\n' \
      "$2" "$(cat "$state")" "$(python3 -c 'import json,sys; print(json.dumps(open(sys.argv[1]).read()))' "$body")"
    ;;
  move)
    printf '%s %s %s\n' "$2" "$3" "${4:-}" >>"$moves"
    printf '%s\n' "$3" >"$state"
    ;;
  add)
    exit 0
    ;;
  *)
    echo "unexpected fake board command: $*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$board"

{
  printf 'pending old deploy-pipeline from x:refs/heads/main:accepted\n'
  python3 - <<'PY'
for i in range(120000):
    print(f"noise {i:06d} " + ("x" * 80))
PY
  printf 'pending pending-sha deploy-pipeline from y:refs/heads/main:accepted\n'
} >"$deploy_root/deploy-schema-infra/deploy.log"

if LASTGIT_DEPLOY_ROOT="$deploy_root" \
   LAST_STACK_DEPLOY_SCAN_TAIL_BYTES=65536 \
   FAKE_BOARD_STATE="$state" \
   FAKE_BOARD_BODY="$body" \
   FAKE_BOARD_MOVES="$moves" \
   "$closeout" deploy-gated-card --board-cli "$board" >/tmp/deploy-closeout-pending.$$ 2>&1; then
  cat /tmp/deploy-closeout-pending.$$ >&2
  rm -f /tmp/deploy-closeout-pending.$$
  echo "expected pending Requires-Deploy to block closeout" >&2
  exit 1
fi
rm -f /tmp/deploy-closeout-pending.$$
[ ! -s "$moves" ] || {
  echo "pending deploy gate still moved the card:" >&2
  cat "$moves" >&2
  exit 1
}

printf 'success success-sha deploy-pipeline\n' >>"$deploy_root/deploy-schema-infra/deploy.log"
LASTGIT_DEPLOY_ROOT="$deploy_root" \
  LAST_STACK_DEPLOY_SCAN_TAIL_BYTES=65536 \
  FAKE_BOARD_STATE="$state" \
  FAKE_BOARD_BODY="$body" \
  FAKE_BOARD_MOVES="$moves" \
  "$closeout" deploy-gated-card --board-cli "$board" >/dev/null

grep -q '^deploy-gated-card done' "$moves"

out="$("$scan" --json --root "$deploy_root" --tail-bytes 65536)"
echo "$out" | jq -e '.[] | select(.repo=="schema-infra" and .status=="success" and .blocked==false)' >/dev/null

echo "ok last-stack-deploy-gated-closeout"
