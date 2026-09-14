#!/usr/bin/env bash
# The DEV photograph step must govern its own deadline.
#
# Regression guard for 2026-09-14 execution lx-20260914T211906.601-58215-1:
# the step budgeted itself 900s, the CLI kept its 600s socket default because
# nothing set it, and every attempt died at 600s. The 900s budget was
# unreachable, three attempts burned 30 minutes, and a candidate that had
# already passed PROBE green failed its live cutover.
set -euo pipefail

ROOT="$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd -P)"
PROOF="$ROOT/skills/lastdb-safe-upgrade/scripts/dev-photograph-candidate-proof.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[ -f "$PROOF" ] && [ ! -L "$PROOF" ] \
  || fail "the DEV photograph proof script is absent or unsafe"

bash -n "$PROOF" || fail "the DEV photograph proof script does not parse"

# 1. The snapshot invocation must hand the CLI a deadline. Without this the
#    transport's default silently caps the step.
grep -q 'LASTDB_UDS_ADMIN_TIMEOUT_SECS="\$snapshot_client_timeout"' "$PROOF" \
  || fail "the snapshot invocation does not pass a client socket deadline to the CLI"

# 2. That deadline must be derived from the step budget, not another constant.
grep -q 'snapshot_client_timeout=\$((snapshot_timeout + snapshot_client_margin))' "$PROOF" \
  || fail "the client deadline is not derived from the snapshot budget"

# 3. The derived deadline must sit ABOVE the step budget, so the step's own
#    timer fires first and classifies the failure. A client deadline at or
#    below the budget returns us to a transport deciding the outcome.
margin_default="$(sed -n 's/.*LASTDB_DEV_PHOTOGRAPH_SNAPSHOT_CLIENT_MARGIN_SECS:-\([0-9]\{1,\}\)}.*/\1/p' "$PROOF" | head -1)"
[ -n "$margin_default" ] || fail "the client margin has no numeric default"
[ "$margin_default" -gt 0 ] \
  || fail "the client margin must be positive so the step deadline binds first"

# 4. An explicit override below the budget must be refused, not honoured
#    silently. Honouring it recreates the exact defect.
grep -q 'is below the DEV snapshot budget of' "$PROOF" \
  || fail "an explicit client deadline below the step budget is not refused"

# 5. The failure summary must name both deadlines, or the next reader is sent
#    to the wrong one — which is what happened on 2026-09-14.
grep -q 'client_timeout_secs=%s' "$PROOF" \
  || fail "the failure summary does not report the client deadline"

# 6. Exercise the arithmetic the script uses, with its own default budget.
snapshot_timeout="$(sed -n 's/.*LASTDB_DEV_PHOTOGRAPH_SNAPSHOT_TIMEOUT_SECS:-\([0-9]\{1,\}\)}.*/\1/p' "$PROOF" | head -1)"
[ -n "$snapshot_timeout" ] || fail "the snapshot budget has no numeric default"
derived=$((snapshot_timeout + margin_default))
[ "$derived" -gt "$snapshot_timeout" ] \
  || fail "the derived client deadline ($derived) does not exceed the budget ($snapshot_timeout)"
# The historical default that caused the incident must no longer be able to bind.
[ "$derived" -gt 600 ] \
  || fail "the derived client deadline ($derived) is still at or below the 600s CLI default"

printf 'PASS: the DEV photograph step governs its own deadline (budget=%ss client=%ss)\n' \
  "$snapshot_timeout" "$derived"
