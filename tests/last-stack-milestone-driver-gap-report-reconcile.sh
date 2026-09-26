#!/usr/bin/env bash
# Fixtures for last-stack-milestone-driver-snapshot's gap-report reconciliation:
#
# 1. idle_empty staleness: a milestone reports action=decompose (no direct
#    children) while a real Kind:pr child already sits in todo/doing linked
#    only to the North Star (no --milestone). The stale entry must drop out
#    of work_queue and counts must move idle_empty -> in_flight.
#    papercut-milestone-driver-idle-empty-stale-vs-northstar-checkpoints-20250925
#
# 2. safety-cap starvation: two decompose entries for two different North
#    Stars. Only one is admitted. The report lists the unadmitted entry
#    first. Reconciliation must move the admitted entry first so a small
#    SAFETY_CAP spends its budget on admitted work, not whichever milestone
#    happened to sort first.
#    papercut-milestone-driver-safety-cap-starves-admitted-north-star-20260925
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
HELPER="${MILESTONE_DRIVER_TEST_HELPER:-$ROOT/bin/last-stack-milestone-driver-snapshot}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$TMP/bin"

cat >"$TMP/bin/preflight" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/bin/preflight"

# ---------------------------------------------------------------------------
# Scenario 1: idle_empty staleness against North-Star-only children
# ---------------------------------------------------------------------------
S1="$TMP/s1"
mkdir -p "$S1/run"
cat >"$S1/kanban" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'list --column backlog --json') echo '{"cards":[],"total":0,"truncated":false}';;
  'list --column todo --json')
    echo '{"cards":[{"slug":"pr-child-1","kind":"pr","column":"todo","milestone":"","north_star":"ns-a"}],"total":1,"truncated":false}';;
  'list --column doing --json') echo '{"cards":[],"total":0,"truncated":false}';;
  'milestone portfolio --json') echo '{"entries":[],"total":0,"truncated":false}';;
  'milestone gap-report --json')
    echo '{"counts":{"idle_empty":1,"in_flight":0},"work_queue":[{"slug":"ms-idle","action":"decompose"}]}';;
  'milestone show ms-idle --json') echo '{"slug":"ms-idle","north_star":"ns-a"}';;
  *) echo "unexpected fixture command: $*" >&2; exit 9;;
esac
EOF
chmod +x "$S1/kanban"
cat >"$S1/admission" <<'EOF'
#!/usr/bin/env bash
echo '{"admitted_outcomes":[]}'
EOF
chmod +x "$S1/admission"

capture_json="$("$HELPER" capture --run-dir "$S1/run" --run-id s1 \
  --preflight-bin "$TMP/bin/preflight" --kanban-bin "$S1/kanban" --admission-bin "$S1/admission")"
artifact="$(printf '%s\n' "$capture_json" | jq -r '.artifact')"

jq -e '.work_queue == []' "$artifact" >/dev/null \
  || fail 'stale idle_empty decompose entry survived reconciliation'
jq -e '.counts.idle_empty == 0' "$artifact" >/dev/null \
  || fail 'idle_empty count not decremented for the stale entry'
jq -e '.counts.in_flight == 1' "$artifact" >/dev/null \
  || fail 'in_flight count not incremented for the reclassified milestone'

# A child already attached to this exact milestone does not count as staleness
# evidence -- gap-report would not have reported idle_empty for that case, and
# a bug here must not delete a genuinely different milestone's real gap.
S1B="$TMP/s1b"
mkdir -p "$S1B/run"
cat >"$S1B/kanban" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'list --column backlog --json') echo '{"cards":[],"total":0,"truncated":false}';;
  'list --column todo --json')
    echo '{"cards":[{"slug":"pr-child-1","kind":"pr","column":"todo","milestone":"ms-idle","north_star":"ns-a"}],"total":1,"truncated":false}';;
  'list --column doing --json') echo '{"cards":[],"total":0,"truncated":false}';;
  'milestone portfolio --json') echo '{"entries":[],"total":0,"truncated":false}';;
  'milestone gap-report --json')
    echo '{"counts":{"idle_empty":1,"in_flight":0},"work_queue":[{"slug":"ms-idle","action":"decompose"}]}';;
  'milestone show ms-idle --json') echo '{"slug":"ms-idle","north_star":"ns-a"}';;
  *) echo "unexpected fixture command: $*" >&2; exit 9;;
esac
EOF
chmod +x "$S1B/kanban"
capture_json_b="$("$HELPER" capture --run-dir "$S1B/run" --run-id s1b \
  --preflight-bin "$TMP/bin/preflight" --kanban-bin "$S1B/kanban" --admission-bin "$S1/admission")"
artifact_b="$(printf '%s\n' "$capture_json_b" | jq -r '.artifact')"
jq -e '.work_queue | length == 1' "$artifact_b" >/dev/null \
  || fail 'a directly-attached child must not be mistaken for North-Star-only staleness'

# ---------------------------------------------------------------------------
# Scenario 2: safety-cap starvation across two North Stars
# ---------------------------------------------------------------------------
S2="$TMP/s2"
mkdir -p "$S2/run"
cat >"$S2/kanban" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'list --column backlog --json') echo '{"cards":[],"total":0,"truncated":false}';;
  'list --column todo --json') echo '{"cards":[],"total":0,"truncated":false}';;
  'list --column doing --json') echo '{"cards":[],"total":0,"truncated":false}';;
  'milestone portfolio --json') echo '{"entries":[],"total":0,"truncated":false}';;
  'milestone gap-report --json')
    echo '{"counts":{"idle_empty":2,"in_flight":0},"work_queue":[{"slug":"ms-unadmitted","action":"decompose"},{"slug":"ms-admitted","action":"decompose"}]}';;
  'milestone show ms-unadmitted --json') echo '{"slug":"ms-unadmitted","north_star":"ns-paused"}';;
  'milestone show ms-admitted --json') echo '{"slug":"ms-admitted","north_star":"ns-primary"}';;
  *) echo "unexpected fixture command: $*" >&2; exit 9;;
esac
EOF
chmod +x "$S2/kanban"
cat >"$S2/admission" <<'EOF'
#!/usr/bin/env bash
echo '{"admitted_outcomes":["ns-primary"]}'
EOF
chmod +x "$S2/admission"

capture_json2="$("$HELPER" capture --run-dir "$S2/run" --run-id s2 \
  --preflight-bin "$TMP/bin/preflight" --kanban-bin "$S2/kanban" --admission-bin "$S2/admission")"
artifact2="$(printf '%s\n' "$capture_json2" | jq -r '.artifact')"

jq -e '.work_queue | length == 2' "$artifact2" >/dev/null \
  || fail 'safety-cap reordering must not drop an entry'
jq -e '.work_queue[0].slug == "ms-admitted"' "$artifact2" >/dev/null \
  || fail 'admitted North Star decompose entry must sort before the unadmitted one'
jq -e '.work_queue[1].slug == "ms-unadmitted"' "$artifact2" >/dev/null \
  || fail 'unadmitted entry must remain queued (skipped, not deleted)'

# An entry carrying an action this code does not enumerate must survive
# untouched at its original position -- never rebuild the array from a fixed
# action allowlist (that silently drops it).
S3="$TMP/s3"
mkdir -p "$S3/run"
cat >"$S3/kanban" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'list --column backlog --json') echo '{"cards":[],"total":0,"truncated":false}';;
  'list --column todo --json') echo '{"cards":[],"total":0,"truncated":false}';;
  'list --column doing --json') echo '{"cards":[],"total":0,"truncated":false}';;
  'milestone portfolio --json') echo '{"entries":[],"total":0,"truncated":false}';;
  'milestone gap-report --json')
    echo '{"counts":{"idle_empty":0,"in_flight":0,"proof_pending":1},"work_queue":[{"slug":"ms-await","action":"await_proof"},{"slug":"ms-admitted","action":"decompose"}]}';;
  'milestone show ms-admitted --json') echo '{"slug":"ms-admitted","north_star":"ns-primary"}';;
  *) echo "unexpected fixture command: $*" >&2; exit 9;;
esac
EOF
chmod +x "$S3/kanban"
capture_json3="$("$HELPER" capture --run-dir "$S3/run" --run-id s3 \
  --preflight-bin "$TMP/bin/preflight" --kanban-bin "$S3/kanban" --admission-bin "$S2/admission")"
artifact3="$(printf '%s\n' "$capture_json3" | jq -r '.artifact')"
jq -e '.work_queue | length == 2' "$artifact3" >/dev/null \
  || fail 'an unrecognized action entry must not be dropped'
jq -e '.work_queue[0] == {"slug":"ms-await","action":"await_proof"}' "$artifact3" >/dev/null \
  || fail 'an unrecognized action entry must keep its original position and shape'

printf '%s\n' 'ok: gap-report reconciliation drops North-Star-stale idle_empty entries, keeps directly-attached children, prioritizes admitted decompose work, and never drops an unrecognized queue entry'
