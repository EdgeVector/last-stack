#!/usr/bin/env bash
# Regression cover for last-stack-scratch-reclaim, the policy-approved
# implementation of disk-reclaim step 4b
# (papercut-disk-reclaim-deletion-policy-blocks-approved-candidates).
#
# Every protect gate is asserted TOGETHER WITH the vacuity companion: the
# eligible sibling in the same run must actually be deleted. A protect test
# without a companion passes when the guard has swallowed everything
# (2026-08-15 lesson).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="$ROOT/bin/last-stack-scratch-reclaim"

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required for this test"; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/scratch-reclaim-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

H="$tmp/home"
mkdir -p "$H/.lastdb/data" "$H/.lastdb-test-copies"
echo primary >"$H/.lastdb/data/marker"

old() { touch -t 202001010000 "$1"; }

# Eligible: real dir, old, unreferenced — MUST be deleted on --execute.
mkdir -p "$H/.lastdb-test-copies/old-eligible"
echo r >"$H/.lastdb-test-copies/old-eligible/VALIDATE-REPORT.md"
old "$H/.lastdb-test-copies/old-eligible"

# Protected candidates — each MUST survive.
mkdir -p "$H/.lastdb-test-copies/young"
mkdir -p "$H/.lastdb-test-copies/flip-records"; old "$H/.lastdb-test-copies/flip-records"
mkdir -p "$H/.lastdb-test-copies/pin-probe";    old "$H/.lastdb-test-copies/pin-probe"
mkdir -p "$H/.lastdb-test-copies/keep-probe";   old "$H/.lastdb-test-copies/keep-probe"
mkdir -p "$H/.lastdb-test-copies/doing-copy";   old "$H/.lastdb-test-copies/doing-copy"
ln -s "$H/.lastdb" "$H/.lastdb-test-copies/into-primary"

# Other scopes: both old — MUST be deleted on --execute.
mkdir -p "$H/lastdb-ephemeral-old"; old "$H/lastdb-ephemeral-old"
mkdir -p "$H/.lastdb.broken-old";   old "$H/.lastdb.broken-old"

# Stubs: a board whose one doing card names doing-copy, and an lsof that
# reports no open files (CI sandboxes deny the real lsof).
stub="$tmp/stub"
mkdir -p "$stub"
cat >"$stub/kanban" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"cards":[{"slug":"probe-card","title":"probe","body":"validating doing-copy on the primary"}]}'
EOF
cat >"$stub/lsof" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$stub/kanban" "$stub/lsof"

run() {
  env HOME="$H" PATH="$stub:$PATH" bash "$bin" "$@"
}

# --- Dry run deletes nothing and names the eligible candidate ---------------
out="$(run)"
printf '%s\n' "$out" | grep -q 'WOULD-DELETE old-eligible' || { echo "FAIL: dry run must name old-eligible"; exit 1; }
printf '%s\n' "$out" | grep -q 'scratch_reclaimed=0' || { echo "FAIL: dry run must reclaim nothing"; exit 1; }
[ -d "$H/.lastdb-test-copies/old-eligible" ] || { echo "FAIL: dry run deleted a directory"; exit 1; }

# --- Execute deletes the eligible set and keeps every protected one ---------
out="$(run --execute)"
[ ! -e "$H/.lastdb-test-copies/old-eligible" ] || { echo "FAIL: old-eligible not deleted"; exit 1; }
[ ! -e "$H/lastdb-ephemeral-old" ] || { echo "FAIL: lastdb-ephemeral-old not deleted"; exit 1; }
[ ! -e "$H/.lastdb.broken-old" ] || { echo "FAIL: .lastdb.broken-old not deleted"; exit 1; }
for keep in young flip-records pin-probe keep-probe doing-copy into-primary; do
  [ -e "$H/.lastdb-test-copies/$keep" ] || { echo "FAIL: protected $keep was deleted"; exit 1; }
done
[ -d "$H/.lastdb" ] && [ -f "$H/.lastdb/data/marker" ] || { echo "FAIL: primary touched"; exit 1; }
[ -f "$H/.lastdb-test-copies/flip-records/old-eligible-VALIDATE-REPORT.md" ] || { echo "FAIL: report not salvaged before deletion"; exit 1; }
printf '%s\n' "$out" | grep -q 'scratch_reclaimed=3' || { echo "FAIL: expected scratch_reclaimed=3; got: $out"; exit 1; }

# --- Board unreadable fails CLOSED: eligible candidate is kept --------------
mkdir -p "$H/.lastdb-test-copies/old-eligible-2"; old "$H/.lastdb-test-copies/old-eligible-2"
cat >"$stub/kanban" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$stub/kanban"
out="$(run --execute)"
[ -d "$H/.lastdb-test-copies/old-eligible-2" ] || { echo "FAIL: deleted with board unreadable"; exit 1; }
printf '%s\n' "$out" | grep -q 'scratch_board_unavailable=1' || { echo "FAIL: missing board-unavailable token"; exit 1; }

echo "PASS last-stack-scratch-reclaim"
