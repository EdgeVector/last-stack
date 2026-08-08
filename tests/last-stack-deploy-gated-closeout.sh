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

# --- a repo with NO deploy-pipeline producer must not gate forever ----------
# Regression for 2026-08-08: a merged AND deployed fold card sat in `doing` for
# 10h because `Requires-Deploy: deploy-pipeline` read as "missing|blocked" —
# fold deploys via lastdb-safe-upgrade and has no ~/.lastgit/deploy-fold log, so
# the gate could never be satisfied. board-closeout flagged close-failed on every
# pass, and the 24h park expiry would then have bounced finished work to todo.
# Brain: papercut-deploy-pipeline-gate-has-no-producer-for-non-lastgit-repos
na_state="$tmp/na-column"
na_body="$tmp/na-body"
na_moves="$tmp/na-moves"
na_board="$tmp/na-fkanban"
printf 'doing\n' >"$na_state"
: >"$na_moves"
cat >"$na_body" <<'EOF'
Repo: EdgeVector/fold
Base: main
Kind: pr
Requires-Deploy: deploy-pipeline
EOF

cat >"$na_board" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state="${FAKE_BOARD_STATE:?}"
body="${FAKE_BOARD_BODY:?}"
moves="${FAKE_BOARD_MOVES:?}"
case "${1:-}" in
  show)
    printf '{"slug":"%s","repo":"EdgeVector/fold","column":"%s","body":%s}\n' \
      "$2" "$(cat "$state")" "$(python3 -c 'import json,sys; print(json.dumps(open(sys.argv[1]).read()))' "$body")"
    ;;
  move)
    printf '%s %s %s\n' "$2" "$3" "${4:-}" >>"$moves"
    printf '%s\n' "$3" >"$state"
    ;;
  add|mark)
    exit 0
    ;;
  *)
    echo "unexpected fake board command: $*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$na_board"

na_out="/tmp/deploy-closeout-na.$$"
LASTGIT_DEPLOY_ROOT="$deploy_root" \
  FAKE_BOARD_STATE="$na_state" \
  FAKE_BOARD_BODY="$na_body" \
  FAKE_BOARD_MOVES="$na_moves" \
  "$closeout" fold-card --board-cli "$na_board" >"$na_out" 2>&1 || {
    cat "$na_out" >&2
    rm -f "$na_out"
    echo "expected closeout to pass a not-applicable deploy gate" >&2
    exit 1
  }
grep -q 'deploy gate not-applicable slug=fold-card repo=fold' "$na_out" || {
  cat "$na_out" >&2
  rm -f "$na_out"
  echo "expected an explicit not-applicable gate line" >&2
  exit 1
}
rm -f "$na_out"
grep -q '^fold-card done' "$na_moves"

# The scan reports the same judgement, and says which producers DO exist.
na_scan="$("$scan" --json --root "$deploy_root" --repo fold)"
echo "$na_scan" | jq -e 'length==1 and .[0].status=="not-applicable" and .[0].blocked==false' >/dev/null

# But an empty deploy root is ambiguous (likely a wrong LASTGIT_DEPLOY_ROOT),
# so it stays fail-closed rather than waving every card through.
empty_root="$tmp/empty-root"
mkdir -p "$empty_root"
printf 'doing\n' >"$na_state"
: >"$na_moves"
if LASTGIT_DEPLOY_ROOT="$empty_root" \
   FAKE_BOARD_STATE="$na_state" \
   FAKE_BOARD_BODY="$na_body" \
   FAKE_BOARD_MOVES="$na_moves" \
   "$closeout" fold-card --board-cli "$na_board" >/dev/null 2>&1; then
  echo "expected an unconfigured deploy root to still block closeout" >&2
  exit 1
fi
[ ! -s "$na_moves" ] || {
  echo "unconfigured deploy root still moved the card:" >&2
  cat "$na_moves" >&2
  exit 1
}

echo "ok last-stack-deploy-gated-closeout"
