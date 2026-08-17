#!/usr/bin/env bash
# Drive shipped last-stack-ship-handoff against mocked brain/kanban.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-ship-handoff"
LEDGER="$ROOT/bin/last-stack-north-star-ledger-sync"
chmod +x "$BIN" "$LEDGER"
python3 -m py_compile "$BIN"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/ns"

: >"$tmp/ms-add.log"
: >"$tmp/brain.log"

cat >"$tmp/bin/brain" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${BRAIN_LOG}"
cmd="${1:-}"
shift || true
case "$cmd" in
  get)
    slug="${1:-}"
    if [ -f "${NS_DIR}/${slug}.md" ]; then
      cat "${NS_DIR}/${slug}.md"
      exit 0
    fi
    exit 1
    ;;
  put)
    slug="${1:-}"
    cat >"${NS_DIR}/${slug}.md"
    exit 0
    ;;
  append)
    slug="${1:-}"
    cat >>"${NS_DIR}/${slug}.md"
    exit 0
    ;;
  *)
    exit 2
    ;;
esac
SH

cat >"$tmp/bin/kanban" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"; shift || true
case "$cmd" in
  milestone)
    sub="${1:-}"; shift || true
    case "$sub" in
      show)
        if [ -f "${MS_EXISTS}" ]; then
          printf '{"slug":"%s","state":"planned"}\n' "${1:-}"
          exit 0
        fi
        exit 1
        ;;
      add)
        printf '%s\n' "$*" >>"${MS_ADD_LOG}"
        : >"${MS_EXISTS}"
        exit 0
        ;;
      detail)
        printf '%s\n' '{"slug":"'"${1:-}"'","driver":"last-stack-milestone-driver","children":[{"slug":"pr-frontier","kind":"pr"}]}'
        exit 0
        ;;
      *)
        exit 2
        ;;
    esac
    ;;
  pickup)
    sub="${1:-}"; shift || true
    [ "$sub" = "explain" ] || exit 2
    if [ "${EXPLAIN_MODE}" = "eligible" ]; then
      printf '%s\n' '{"slug":"pr-frontier","ready":true,"eligible_for_claim":true}'
    elif [ "${EXPLAIN_MODE}" = "ready-only" ]; then
      printf '%s\n' '{"slug":"pr-frontier","ready":true,"eligible_for_claim":false}'
    else
      printf '%s\n' '{"slug":"pr-frontier","ready":false,"eligible_for_claim":false}'
    fi
    exit 0
    ;;
  *)
    exit 2
    ;;
esac
SH
chmod +x "$tmp/bin/brain" "$tmp/bin/kanban"

export PATH="$tmp/bin:/usr/bin:/bin"
export BRAIN_BIN="$tmp/bin/brain"
export KANBAN_BIN="$tmp/bin/kanban"
export BRAIN_LOG="$tmp/brain.log"
export NS_DIR="$tmp/ns"
export MS_ADD_LOG="$tmp/ms-add.log"
export MS_EXISTS="$tmp/ms.exists"

handoff() {
  python3 "$BIN" \
    --north-star north-star-demo \
    --milestone demo-v1 \
    --title "Demo outcome" \
    --outcome "thing works" \
    --acceptance "run the app" \
    --end-state "thing works" \
    --create-ns \
    --skip-driver \
    --wait-ready 0 \
    --frontier pr-frontier \
    --json
}

# Two successful launches with eligible_for_claim.
: >"$MS_ADD_LOG"
rm -f "$MS_EXISTS" "$NS_DIR/north-star-demo.md"
EXPLAIN_MODE=eligible handoff >"$tmp/ok1.json"
adds1="$(wc -l <"$MS_ADD_LOG" | tr -d ' ')"
EXPLAIN_MODE=eligible handoff >"$tmp/ok2.json"
python3 - "$tmp/ok1.json" "$tmp/ok2.json" "$adds1" "$NS_DIR/north-star-demo.md" "$LEDGER" <<'PY'
import json, subprocess, sys
r1 = json.load(open(sys.argv[1]))
r2 = json.load(open(sys.argv[2]))
assert r1["eligible_for_claim"] is True
assert r2["eligible_for_claim"] is True
assert int(sys.argv[3]) == 1, sys.argv[3]
assert r1["milestone_add_count"] == 1
body = open(sys.argv[4]).read()
assert "## MILESTONE_REQUEST" in body
assert "slug=demo-v1" in body
assert "MILESTONE_REQUEST slug=demo-v1 status=pending" not in body
cp = subprocess.run(
    [sys.argv[5], "--parse-body", sys.argv[4]],
    text=True, capture_output=True, check=True,
)
parsed = json.loads(cp.stdout)
assert parsed["requests"] == [{"slug": "demo-v1", "status": "pending"}], parsed
print("ship-handoff eligible path ok")
PY

# Ready-only is a walk-away refusal.
: >"$MS_ADD_LOG"
rm -f "$MS_EXISTS" "$NS_DIR/north-star-demo.md"
set +e
EXPLAIN_MODE=ready-only handoff >"$tmp/ready-only.json"
ready_rc=$?
set -e
[ "$ready_rc" -ne 0 ] || { echo "ready-only must fail"; exit 1; }
python3 - "$tmp/ready-only.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["ready"] is True
assert r["eligible_for_claim"] is False
print("ship-handoff ready-only refused")
PY

# Missing explain / ineligible also fails.
: >"$MS_ADD_LOG"
rm -f "$MS_EXISTS" "$NS_DIR/north-star-demo.md"
set +e
EXPLAIN_MODE=none handoff >"$tmp/none.json"
none_rc=$?
set -e
[ "$none_rc" -ne 0 ] || { echo "missing-eligible must fail"; exit 1; }

echo "last-stack-ship-handoff tests ok"
