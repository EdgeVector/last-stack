#!/usr/bin/env bash
# Dogfood the legacy-residue closeout gate without touching the live board.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
closeout="$ROOT/bin/last-stack-card-closeout"
probe="$ROOT/bin/last-stack-legacy-residue-probe"
chmod +x "$closeout" "$probe"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

remote="$tmp/origin.git"
repo="$tmp/repo"
git init --bare "$remote" >/dev/null
git init -b main "$repo" >/dev/null
git -C "$repo" config user.name "Last Stack Test"
git -C "$repo" config user.email "last-stack-test@example.invalid"
printf 'OLD_TOKEN still exists\n' >"$repo/source.txt"
git -C "$repo" add source.txt
git -C "$repo" commit -m "seed legacy marker" >/dev/null
git -C "$repo" remote add origin "$remote"
git -C "$repo" push -u origin main >/dev/null 2>&1
git -C "$repo" fetch origin main --quiet
sha="$(git -C "$repo" rev-parse --short origin/main)"

board="$tmp/fkanban"
state="$tmp/column"
body="$tmp/body"
moves="$tmp/moves"
printf 'doing\n' >"$state"

cat >"$board" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state="${FAKE_BOARD_STATE:?}"
body="${FAKE_BOARD_BODY:?}"
moves="${FAKE_BOARD_MOVES:?}"
repo="${FAKE_BOARD_REPO:?}"
case "${1:-}" in
  show)
    printf '{"slug":"%s","repo":"%s","column":"%s","body":%s}\n' \
      "$2" "$repo" "$(cat "$state")" "$(python3 -c 'import json,sys; print(json.dumps(open(sys.argv[1]).read()))' "$body")"
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

cat >"$body" <<EOF
Repo: $repo
Base: main
Kind: pr

## LEGACY REMOVAL
Markers: OLD_TOKEN

## OUTCOME
- $repo@$sha: \`$probe $repo OLD_TOKEN\` -> 0 hits
EOF

if FAKE_BOARD_STATE="$state" \
   FAKE_BOARD_BODY="$body" \
   FAKE_BOARD_MOVES="$moves" \
   FAKE_BOARD_REPO="$repo" \
   "$closeout" residue-hit-card --board-cli "$board" >/tmp/residue-hit.$$ 2>&1; then
  cat /tmp/residue-hit.$$ >&2
  rm -f /tmp/residue-hit.$$
  echo "expected legacy residue hit to block closeout" >&2
  exit 1
fi
rm -f /tmp/residue-hit.$$
[ ! -s "$moves" ] || {
  echo "legacy residue hit still moved the card:" >&2
  cat "$moves" >&2
  exit 1
}

cat >"$body" <<EOF
Repo: $repo
Base: main
Kind: pr

## LEGACY RESIDUE
Markers: NO_SUCH_TOKEN

## OUTCOME
- $repo@$sha: \`$probe $repo NO_SUCH_TOKEN\` -> 0 hits
EOF

FAKE_BOARD_STATE="$state" \
  FAKE_BOARD_BODY="$body" \
  FAKE_BOARD_MOVES="$moves" \
  FAKE_BOARD_REPO="$repo" \
  "$closeout" residue-clean-card --board-cli "$board" >/dev/null

grep -q '^residue-clean-card done' "$moves"

echo "ok last-stack-legacy-residue-closeout"
