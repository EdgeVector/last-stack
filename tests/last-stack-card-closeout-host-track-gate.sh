#!/usr/bin/env bash
# papercut-card-closeout-helper-blocks-merged-deferred-cards-20260922
#
# `Requires-Deploy: host-track` used to fail with unsupported-deploy-gate.
# It now passes when the PR merge commit is an ancestor of the host-track
# installed head for the repo's app, and stays pending when it is not.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="$ROOT/bin/last-stack-card-closeout"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/path" "$tmp/cache"

# A bare mirror with two commits: merge (older) and head (newer).
git init -q "$tmp/src"
git -C "$tmp/src" -c user.email=t@t -c user.name=t commit -q --allow-empty -m merge
merge_sha="$(git -C "$tmp/src" rev-parse HEAD)"
git -C "$tmp/src" -c user.email=t@t -c user.name=t commit -q --allow-empty -m later
head_sha="$(git -C "$tmp/src" rev-parse HEAD)"
git clone -q --bare "$tmp/src" "$tmp/cache/widget.git"
export EDGEVECTOR_GIT_CACHE="$tmp/cache"

cat >"$tmp/forge-api" <<EOF
#!/usr/bin/env bash
case "\$*" in *.merged*) echo true ;; *) echo '"$merge_sha"' ;; esac
EOF
chmod +x "$tmp/forge-api"
export LAST_STACK_FORGE_API="$tmp/forge-api"

export HT_HEAD="$head_sha"
cat >"$tmp/path/host-track" <<'EOF'
#!/usr/bin/env bash
printf '[{"app":"widget","gate_main":"http://localhost:3300/EdgeVector/widget.git#main","host_head":"%s"}]\n' "$HT_HEAD"
EOF
chmod +x "$tmp/path/host-track"
export PATH="$tmp/path:$PATH"

export HG_COL="$tmp/col"
board="$tmp/board"
cat >"$board" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  show)
    jq -n --arg slug "${2:-}" --arg col "$(cat "$HG_COL")" \
      '{slug:$slug, column:$col, repo:"EdgeVector/widget", pr_url:"http://localhost:3300/EdgeVector/widget/pulls/7", branch:"", body:"Repo: EdgeVector/widget\nRequires-Deploy: host-track\n"}'
    ;;
  add|mark) exit 0 ;;
  move) printf '%s\n' "${3:-}" >"$HG_COL" ;;
  *) echo "unexpected board call: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$board"

echo doing >"$HG_COL"
out="$("$bin" hg-card --board-cli "$board" 2>&1)" || { echo "FAIL: installed merge must close: $out" >&2; exit 1; }
printf '%s\n' "$out" | grep -q 'deploy gate host-track installed' || { echo "FAIL: $out" >&2; exit 1; }
[ "$(cat "$HG_COL")" = done ]

# Installed head older than the merge: pending, no move.
echo doing >"$HG_COL"
export HT_HEAD="$merge_sha"
cat >"$tmp/forge-api" <<EOF
#!/usr/bin/env bash
case "\$*" in *.merged*) echo true ;; *) echo '"$head_sha"' ;; esac
EOF
set +e
out="$("$bin" hg-card --board-cli "$board" 2>&1)"
rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "FAIL: an uninstalled merge must not close: $out" >&2; exit 1; }
printf '%s\n' "$out" | grep -q 'requires=host-track status=not-installed' || { echo "FAIL: $out" >&2; exit 1; }
[ "$(cat "$HG_COL")" = doing ]

echo "ok last-stack-card-closeout-host-track-gate"
