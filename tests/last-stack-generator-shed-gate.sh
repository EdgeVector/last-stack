#!/usr/bin/env bash
# Shed-gate fixtures: last-stack-generator-preflight + last-stack-lastdb-pressure.
#
# Both halves of this chain shipped broken at once (2026-08-15):
#   - preflight read `rc=$?` inside `if ! cmd`, so its shed branch was
#     unreachable and it ALWAYS exited 0;
#   - pressure forced level=hot on the bare `sync_degraded` liveness flag, so a
#     deliberately paused cloud sync read as node load.
# The firing path had no test, which is how an unreachable branch survived.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------- preflight --
# preflight resolves its sibling probe via its own dirname/.., so stand up a
# fake root holding a scriptable pressure stub next to the real gate.
mkdir -p "$tmp/root/bin"
cp "$ROOT/bin/last-stack-generator-preflight" "$tmp/root/bin/"

make_pressure_stub() {
  cat >"$tmp/root/bin/last-stack-lastdb-pressure" <<SH
#!/usr/bin/env bash
exit $1
SH
  chmod +x "$tmp/root/bin/last-stack-lastdb-pressure"
}

run_preflight() {
  local rc=0
  "$tmp/root/bin/last-stack-generator-preflight" test-reason >"$tmp/out.txt" 2>&1 || rc=$?
  printf '%s' "$rc"
}

# A. hot (1) -> shed with 75. This is the case that never fired.
make_pressure_stub 1
got="$(run_preflight)"
[ "$got" = "75" ] || fail "hot probe should shed with 75, got $got"
grep -q 'ROUTINE_RESULT' "$tmp/out.txt" \
  || fail "shed should print ROUTINE_RESULT; got: $(cat "$tmp/out.txt")"
grep -q 'reason=test-reason' "$tmp/out.txt" \
  || fail "shed should echo the caller reason"

# B. cool (0) -> proceed.
make_pressure_stub 0
got="$(run_preflight)"
[ "$got" = "0" ] || fail "cool probe should proceed with 0, got $got"

# C. probe unavailable (2) -> proceed, never shed on unknown.
make_pressure_stub 2
got="$(run_preflight)"
[ "$got" = "0" ] || fail "unavailable probe must not shed, got $got"

# ----------------------------------------------------------------- pressure --
mkdir -p "$tmp/bin"
export PATH="$tmp/bin:$PATH"

# $1 = degraded (true|false), $2 = in_flight
make_lastdb_stub() {
  cat >"$tmp/bin/lastdb" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = "status" ] || exit 0
cat <<'OUT'
node: primary
qos in_flight=$2 rejects=0 sheds_i=0 sheds_b=0
warm=100/1000 (10.0%)
cloud sync: degraded=$1
OUT
SH
  chmod +x "$tmp/bin/lastdb"
}

run_pressure() {
  local rc=0
  "$ROOT/bin/last-stack-lastdb-pressure" --json >"$tmp/p.json" 2>/dev/null || rc=$?
  printf '%s' "$rc"
}

# D. degraded sync, everything else cool -> COOL, but still reported.
make_lastdb_stub true 1
got="$(run_pressure)"
[ "$got" = "0" ] || fail "sync_degraded alone must not be hot, got exit $got"
grep -q 'sync_degraded_info' "$tmp/p.json" \
  || fail "degraded sync should still be reported: $(cat "$tmp/p.json")"
grep -q '"level":"cool"' "$tmp/p.json" \
  || fail "level should be cool: $(cat "$tmp/p.json")"

# E. explicit opt-in restores the old gating.
got=0
LASTSTACK_PRESSURE_HOT_ON_SYNC_DEGRADED=1 \
  "$ROOT/bin/last-stack-lastdb-pressure" --json >"$tmp/p.json" 2>/dev/null || got=$?
[ "$got" = "1" ] || fail "opt-in should make degraded sync hot, got $got"
grep -q '"level":"hot"' "$tmp/p.json" || fail "opt-in level should be hot"

# F. a real load signal is still hot, degraded or not.
make_lastdb_stub false 999
got="$(run_pressure)"
[ "$got" = "1" ] || fail "in_flight over threshold must stay hot, got $got"
grep -q 'in_flight=999' "$tmp/p.json" || fail "hot reason should name in_flight"

printf 'ok last-stack-generator-shed-gate\n'
