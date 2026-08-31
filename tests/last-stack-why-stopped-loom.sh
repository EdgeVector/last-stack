#!/usr/bin/env bash
# last-stack-why-stopped-loom: mock loom, check JSON contract + fallback exit 3.
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-why-stopped-loom"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

bash -n "$BIN"
[ -x "$BIN" ] || chmod +x "$BIN"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- no loom → exit 3 ---
# The helper prepends $HOME/.local/bin; isolate HOME so the host loom is gone.
set +e
HOME="$tmp" PATH="/usr/bin:/bin" "$BIN" --json --quiet >"$tmp/out" 2>"$tmp/err"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "expected exit 3 without loom, got $rc $(cat "$tmp/err")"

# --- mock loom ---
mkdir -p "$tmp/bin" "$tmp/install/dist" "$tmp/install/scripts" "$tmp/install/definitions"
cat >"$tmp/bin/loom" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
case "$cmd" in
  ping) echo ok; exit 0 ;;
  publish)
    echo "published $(basename "$2" .json)"
    exit 0
    ;;
  run)
    cat <<'VIEW'
lx-test-1
lx-test-1
status: succeeded
state: DONE
context.classes: "A"
context.detail: "install:stale"
context.actions: "host-track refresh last-stack"
context.heal: "heal skipped (print-only; set LOOM_WHY_HEAL=1 to run Class A only)"
VIEW
    exit 0
    ;;
  *) echo "unexpected $*" >&2; exit 2 ;;
esac
SH
chmod 755 "$tmp/bin/loom"
ln -s "$tmp/bin/loom" "$tmp/install/dist/loom"
printf '%s\n' 'echo classify' >"$tmp/install/scripts/loom-why-classify.sh"
printf '%s\n' '{}' >"$tmp/install/definitions/why-stopped.json"
printf '%s\n' '{}' >"$tmp/install/definitions/why-stopped-probe.json"

# Isolate HOME so the helper's $HOME/.local/bin prepend cannot pick host loom.
export HOME="$tmp"
export PATH="$tmp/bin:/usr/bin:/bin"
export LOOM_DEFS="$tmp/install/definitions"
export LOOM_SCRIPTS="$tmp/install/scripts"
export LOOM_WHY_KEY="why-stopped-test-key"

set +e
out="$("$BIN" --json --quiet)"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "loom path exit $rc"
printf '%s\n' "$out" | grep -q '"classes":"A"' || fail "json missing classes=A: $out"
printf '%s\n' "$out" | grep -q '"engine":"loom"' || fail "json missing engine=loom: $out"
printf '%s\n' "$out" | grep -q 'ROUTINE_RESULT' || fail "missing ROUTINE_RESULT: $out"

# failed loom exec → exit 3
cat >"$tmp/bin/loom" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  ping) echo ok; exit 0 ;;
  publish) exit 0 ;;
  run)
    cat <<'VIEW'
lx-fail
status: failed
state: CLASSIFY
VIEW
    exit 0
    ;;
  *) exit 2 ;;
esac
SH
chmod 755 "$tmp/bin/loom"
set +e
"$BIN" --json --quiet >/dev/null
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "failed exec should exit 3, got $rc"

# --status reads the stamp written on the failed exec
st="$("$BIN" --status)"
printf '%s\n' "$st" | grep -q '"status": "failed"' || fail "status stamp missing failed: $st"
printf '%s\n' "$st" | grep -q '"missing": false' || fail "status should see stamp: $st"

# A non-terminal execution that DID classify → exit 4, and the classification
# still reaches the caller. Exit 3 used to cover this and "loom is missing",
# so the fleet surface reported a live loom as unavailable.
cat >"$tmp/bin/loom" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  ping) echo ok; exit 0 ;;
  publish) exit 0 ;;
  run)
    cat <<'VIEW'
lx-incomplete
status: running
state: REPORT
context.classes: "D+F"
context.detail: "pickup:stalled"
context.actions: "check the board"
VIEW
    echo "execution lx-incomplete is incomplete" >&2
    exit 4
    ;;
  *) exit 2 ;;
esac
SH
chmod 755 "$tmp/bin/loom"
set +e
out="$("$BIN" --json --quiet)"
rc=$?
set -e
[ "$rc" -eq 4 ] || fail "incomplete exec should exit 4, not $rc: $out"
printf '%s\n' "$out" | grep -q '"classes":"D+F"' || fail "exit 4 dropped its classification: $out"
printf '%s\n' "$out" | grep -q 'ROUTINE_RESULT' || fail "exit 4 missing ROUTINE_RESULT: $out"

st="$("$BIN" --status)"
printf '%s\n' "$st" | grep -q '"status": "running"' || fail "stamp lost the real status: $st"

# An incomplete run with nothing to classify is still a fallback case.
cat >"$tmp/bin/loom" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  ping) echo ok; exit 0 ;;
  publish) exit 0 ;;
  run)
    cat <<'VIEW'
lx-blank
status: running
state: HEAL
VIEW
    exit 4
    ;;
  *) exit 2 ;;
esac
SH
chmod 755 "$tmp/bin/loom"
set +e
"$BIN" --json --quiet >/dev/null
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "incomplete exec with no classes should exit 3, got $rc"

# No view at all is the real "loom gave us nothing" case.
cat >"$tmp/bin/loom" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  ping) echo ok; exit 0 ;;
  publish) exit 0 ;;
  run) exit 1 ;;
  *) exit 2 ;;
esac
SH
chmod 755 "$tmp/bin/loom"
set +e
"$BIN" --json --quiet >/dev/null
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "empty view should exit 3, got $rc"

echo ok
