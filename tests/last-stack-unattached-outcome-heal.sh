#!/usr/bin/env bash
# Smoke fixtures for last-stack-unattached-outcome-heal (no live board writes).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="$ROOT/bin/last-stack-unattached-outcome-heal"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ -x "$bin" ] || chmod +x "$bin"
"$bin" --help >/dev/null || fail "--help"

# Hermetic PATH: only our fake kanban + system jq/coreutils. Do not leak a
# host-track kanban that would hit the live board.
export PATH="$tmp/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
mkdir -p "$tmp/bin" "$tmp/home"
export HOME="$tmp/home"
: >"$tmp/add.log"
: >"$tmp/move.log"
: >"$tmp/mark.log"

# --- Case 1: attachable residual (repo default MS exists) ---
cat >"$tmp/bin/kanban" <<SH
#!/usr/bin/env bash
set -euo pipefail
cmd="\${1:-}"
shift || true
case "\$cmd" in
  pickup)
    cat <<'JSON'
{"ready":0,"scanned":1,"counts":{"unattached-outcome":1,"pickup-ready":0},"cards":[{"slug":"card-needs-ms","category":"unattached-outcome","column":"todo","repo":"EdgeVector/last-stack"}]}
JSON
    ;;
  show)
    cat <<'JSON'
{"slug":"card-needs-ms","board":"default","column":"todo","north_star":"","milestone":"","repo":"EdgeVector/last-stack","surfaces":[],"body":"Surfaces: bin/**,config/**\n\n## GOAL\nx\n\n## END STATE\ny\n"}
JSON
    ;;
  milestone)
    cat <<'JSON'
[{"slug":"ms-host-track-ops-hygiene-wave2","state":"active","north_star":"north-star-host-track"}]
JSON
    ;;
  add)
    printf '%s\n' "\$*" >>"$tmp/add.log"
    exit 0
    ;;
  move)
    printf '%s\n' "\$*" >>"$tmp/move.log"
    exit 0
    ;;
  mark)
    printf '%s\n' "\$*" >>"$tmp/mark.log"
    exit 0
    ;;
  *)
    echo "unexpected kanban \$cmd \$*" >&2
    exit 1
    ;;
esac
SH
chmod +x "$tmp/bin/kanban"

command -v jq >/dev/null || fail "jq required"

out="$("$bin" --json 2>/dev/null)" || fail "heal exit non-zero: $out"
echo "$out" | jq -e '.ok == true and .attached >= 1' >/dev/null \
  || fail "expected attached>=1: $out"
grep -q 'card-needs-ms --milestone ms-host-track-ops-hygiene-wave2' "$tmp/add.log" \
  || fail "add log missing milestone attach: $(cat "$tmp/add.log")"
# surfaces backfill from body
grep -q 'card-needs-ms --surfaces' "$tmp/add.log" \
  || fail "add log missing surfaces: $(cat "$tmp/add.log")"
# successful attach must NOT demote the card
if [ -s "$tmp/move.log" ]; then
  fail "attach path should not move cards: $(cat "$tmp/move.log")"
fi

dry="$("$bin" --dry-run --json 2>/dev/null)" || fail "dry-run failed"
echo "$dry" | jq -e '.dry_run == 1' >/dev/null \
  || fail "dry_run flag: $dry"

# --- Case 2: no-ms residual in default/todo → demote to backlog ---
: >"$tmp/add.log"
: >"$tmp/move.log"
: >"$tmp/mark.log"

cat >"$tmp/bin/kanban" <<SH
#!/usr/bin/env bash
set -euo pipefail
cmd="\${1:-}"
shift || true
case "\$cmd" in
  pickup)
    cat <<'JSON'
{"ready":0,"scanned":1,"counts":{"unattached-outcome":1,"pickup-ready":0},"cards":[{"slug":"card-no-ms","category":"unattached-outcome","column":"todo","repo":"EdgeVector/unknown-repo"}]}
JSON
    ;;
  show)
    # Unknown repo + empty ns/ms → no-ms residual still in default/todo
    cat <<'JSON'
{"slug":"card-no-ms","board":"default","column":"todo","north_star":"","milestone":"","repo":"EdgeVector/unknown-repo","surfaces":[],"body":"## GOAL\norphan residual\n\n## END STATE\nparked\n"}
JSON
    ;;
  milestone)
    cat <<'JSON'
[]
JSON
    ;;
  add)
    printf '%s\n' "\$*" >>"$tmp/add.log"
    exit 0
    ;;
  move)
    printf '%s\n' "\$*" >>"$tmp/move.log"
    exit 0
    ;;
  mark)
    printf '%s\n' "\$*" >>"$tmp/mark.log"
    exit 0
    ;;
  *)
    echo "unexpected kanban \$cmd \$*" >&2
    exit 1
    ;;
esac
SH
chmod +x "$tmp/bin/kanban"

out2="$("$bin" --json 2>/dev/null)" || fail "no-ms heal exit non-zero: $out2"
echo "$out2" | jq -e '.ok == true and .demoted >= 1 and .attached == 0' >/dev/null \
  || fail "expected demoted>=1 attached=0: $out2"
echo "$out2" | jq -e '.flagged | test("no-ms:card-no-ms")' >/dev/null \
  || fail "expected no-ms flag: $out2"
grep -q 'card-no-ms backlog' "$tmp/move.log" \
  || fail "move log missing demote: $(cat "$tmp/move.log")"
grep -q 'card-no-ms PROGRESS: unattached-outcome-heal demoted todo→backlog (no-ms)' "$tmp/mark.log" \
  || fail "mark log missing PROGRESS note: $(cat "$tmp/mark.log")"
# no-ms must not invent a milestone attach
if [ -s "$tmp/add.log" ]; then
  fail "no-ms path should not add/attach: $(cat "$tmp/add.log")"
fi

# dry-run demote counts without writing move/mark
: >"$tmp/move.log"
: >"$tmp/mark.log"
dry2="$("$bin" --dry-run --json 2>/dev/null)" || fail "no-ms dry-run failed"
echo "$dry2" | jq -e '.dry_run == 1 and .demoted >= 1' >/dev/null \
  || fail "dry demoted: $dry2"
if [ -s "$tmp/move.log" ] || [ -s "$tmp/mark.log" ]; then
  fail "dry-run must not move/mark: move=$(cat "$tmp/move.log") mark=$(cat "$tmp/mark.log")"
fi

# --- Case 3: no-ms residual already in backlog → leave alone ---
: >"$tmp/add.log"
: >"$tmp/move.log"
: >"$tmp/mark.log"
cat >"$tmp/bin/kanban" <<SH
#!/usr/bin/env bash
set -euo pipefail
cmd="\${1:-}"
shift || true
case "\$cmd" in
  pickup)
    cat <<'JSON'
{"ready":0,"scanned":1,"counts":{"unattached-outcome":1,"pickup-ready":0},"cards":[{"slug":"card-already-backlog","category":"unattached-outcome","column":"backlog","repo":"EdgeVector/unknown-repo"}]}
JSON
    ;;
  show)
    cat <<'JSON'
{"slug":"card-already-backlog","board":"default","column":"backlog","north_star":"","milestone":"","repo":"EdgeVector/unknown-repo","surfaces":[],"body":"x"}
JSON
    ;;
  milestone)
    echo '[]'
    ;;
  add)
    printf '%s\n' "\$*" >>"$tmp/add.log"
    exit 0
    ;;
  move)
    printf '%s\n' "\$*" >>"$tmp/move.log"
    exit 0
    ;;
  mark)
    printf '%s\n' "\$*" >>"$tmp/mark.log"
    exit 0
    ;;
  *)
    echo "unexpected kanban \$cmd \$*" >&2
    exit 1
    ;;
esac
SH
chmod +x "$tmp/bin/kanban"

out3="$("$bin" --json 2>/dev/null)" || fail "backlog residual heal failed: $out3"
echo "$out3" | jq -e '.ok == true and .demoted == 0' >/dev/null \
  || fail "backlog residual must not demote: $out3"
if [ -s "$tmp/move.log" ]; then
  fail "backlog residual must not move: $(cat "$tmp/move.log")"
fi

# --- Case 4: card has NS but no live milestone → create ops MS then attach ---
: >"$tmp/add.log"
: >"$tmp/move.log"
: >"$tmp/mark.log"
: >"$tmp/ms-add.log"
cat >"$tmp/bin/kanban" <<SH
#!/usr/bin/env bash
set -euo pipefail
cmd="\${1:-}"
shift || true
case "\$cmd" in
  pickup)
    cat <<'JSON'
{"ready":0,"scanned":1,"counts":{"unattached-outcome":1,"pickup-ready":0},"cards":[{"slug":"card-has-ns","category":"unattached-outcome","column":"todo","repo":"EdgeVector/fkanban"}]}
JSON
    ;;
  show)
    cat <<'JSON'
{"slug":"card-has-ns","board":"default","column":"todo","north_star":"north-star-kanban-socket-consistency","milestone":"","repo":"EdgeVector/fkanban","surfaces":[],"body":"## GOAL\\nx\\n\\n## END STATE\\ny\\n"}
JSON
    ;;
  milestone)
    sub="\${1:-}"
    shift || true
    if [ "\$sub" = "add" ]; then
      printf '%s\\n' "\$*" >>"$tmp/ms-add.log"
      exit 0
    fi
    echo '[]'
    ;;
  add)
    printf '%s\\n' "\$*" >>"$tmp/add.log"
    exit 0
    ;;
  move)
    printf '%s\\n' "\$*" >>"$tmp/move.log"
    exit 0
    ;;
  mark)
    printf '%s\\n' "\$*" >>"$tmp/mark.log"
    exit 0
    ;;
  *)
    echo "unexpected kanban \$cmd \$*" >&2
    exit 1
    ;;
esac
SH
chmod +x "$tmp/bin/kanban"

out4="$("$bin" --json 2>/dev/null)" || fail "ns-create heal exit non-zero: $out4"
echo "$out4" | jq -e '.ok == true and .attached >= 1' >/dev/null \
  || fail "expected create+attach: $out4"
grep -q 'ms-kanban-socket-consistency-ops' "$tmp/ms-add.log" \
  || fail "expected ops milestone create: $(cat "$tmp/ms-add.log")"
grep -q 'card-has-ns --milestone ms-kanban-socket-consistency-ops' "$tmp/add.log" \
  || fail "expected attach to created ms: $(cat "$tmp/add.log")"
if [ -s "$tmp/move.log" ]; then
  fail "create+attach must not demote: $(cat "$tmp/move.log")"
fi

echo "ok last-stack-unattached-outcome-heal"
