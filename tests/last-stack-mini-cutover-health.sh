#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home"

cat >"$tmp/bin/kanban" <<'EOF_KANBAN'
#!/usr/bin/env bash
if [[ "${MC_TEST_KANBAN_FAIL:-0}" == 1 ]]; then
  echo "simulated board read failure" >&2
  exit 1
fi
if [[ "$1" == search ]]; then
  printf '%s\n' "${MC_TEST_CARDS:-[]}"
  exit 0
fi
exit 1
EOF_KANBAN

cat >"$tmp/bin/brain" <<'EOF_BRAIN'
#!/usr/bin/env bash
case "${2:-}" in
  active-programs) echo 'program-mini-cutover-lastdb-core' ;;
  open-decisions) echo "${MC_TEST_OPEN_DECISIONS:-}" ;;
  north-star-lastdb-no-sled-document-store) printf '%s\n' "${MC_TEST_NS:-}" ;;
  *) exit 1 ;;
esac
EOF_BRAIN
chmod +x "$tmp/bin/kanban" "$tmp/bin/brain" "$ROOT/bin/mini-cutover-health-check"

cards='[
 {"slug":"mini-cutover-p1-laststore-kv-adapter","column":"done"},
 {"slug":"mini-cutover-p1-factory-engine-flag","column":"done"},
 {"slug":"mini-cutover-p1-empty-home-boot-smoke","column":"done"},
 {"slug":"mini-cutover-p2-domain-encrypt-laststore","column":"done"},
 {"slug":"mini-cutover-p2-cow-real-data-green","column":"done"},
 {"slug":"mini-cutover-p4-primary-flip","column":"done"},
 {"slug":"mini-cutover-p5-remove-sled","column":"done"}
]'
checkpoints=$'F-Kanban completion checkpoint: mini-cutover-p0-namespace-inventory\nF-Kanban completion checkpoint: mini-cutover-p0-cow-offline-baseline\nF-Kanban completion checkpoint: mini-cutover-p3-sled-to-laststore-migrator\nF-Kanban completion checkpoint: mini-cutover-p4-cutover-safety-package'

HOME="$tmp/home" PATH="$tmp/bin:$PATH" LAST_STACK_ROOT="$tmp/none" \
  MC_TEST_CARDS="$cards" MC_TEST_NS="$checkpoints" \
  "$ROOT/bin/mini-cutover-health-check" --json >"$tmp/healthy.json"
grep -q '"status": "HEALTHY"' "$tmp/healthy.json"
grep -q '"mini-cutover-p0-namespace-inventory": "brain-completion-checkpoint"' "$tmp/healthy.json"
grep -q '"done_phases": 11' "$tmp/healthy.json"

set +e
HOME="$tmp/home" PATH="$tmp/bin:$PATH" LAST_STACK_ROOT="$tmp/none" \
  MC_TEST_CARDS="$cards" MC_TEST_NS='' \
  "$ROOT/bin/mini-cutover-health-check" --json >"$tmp/missing.json"
missing_ec=$?
set -e
[[ "$missing_ec" == 1 ]]
grep -q 'missing phase evidence' "$tmp/missing.json"

set +e
HOME="$tmp/home" PATH="$tmp/bin:$PATH" LAST_STACK_ROOT="$tmp/none" \
  MC_TEST_KANBAN_FAIL=1 MC_TEST_NS="$checkpoints" \
  "$ROOT/bin/mini-cutover-health-check" --json >"$tmp/read-fail.out" 2>"$tmp/read-fail.err"
read_ec=$?
set -e
[[ "$read_ec" == 2 ]]
grep -q 'cards read failed' "$tmp/read-fail.err"
! grep -q 'missing' "$tmp/read-fail.out"

grep -q 'change that line to `status=resolved`' "$ROOT/routines/mini-cutover-health.md"
grep -q 'Never page for an exit-2 read failure' "$ROOT/routines/mini-cutover-health.md"

echo "ok last-stack-mini-cutover-health"
