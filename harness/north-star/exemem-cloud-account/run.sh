#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../common.sh
. "$ROOT/harness/north-star/common.sh"

SLUG=north-star-exemem-cloud-account
MODE="$(ns_mode)"
EVIDENCE_FILE="${EXEMEM_CLOUD_ACCOUNT_PROOF_EVIDENCE_FILE:-}"

fail() {
  ns_write_report "$SLUG" FAIL "$1" || exit 1
  exit 1
}

if [ -z "$EVIDENCE_FILE" ]; then
  fail "$(cat <<'EOF'
Live redacted evidence is required for the Exemem Cloud account proof.

Set EXEMEM_CLOUD_ACCOUNT_PROOF_EVIDENCE_FILE to a JSON file containing only
non-secret evidence:
- checkout.account_landing: true
- plan.before_storage_gb: 50
- plan.after_storage_gb: 100
- plan.displayed_storage_gb: 100
- upgrade.payment_confirmed: true
- privacy.exemem_pii_leak_count: 0
- privacy.checked_fields: array of checked Exemem-side fields

Do not persist raw Stripe tokens, Exemem session tokens, email addresses, names,
payment identifiers, API keys, or other PII/secrets. Retrieve secrets only at
the point of live collection with LastSecrets.
EOF
)"
fi

if [ ! -f "$EVIDENCE_FILE" ]; then
  fail "evidence file not found: $EVIDENCE_FILE"
fi

set +e
python_out="$(python3 - "$EVIDENCE_FILE" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
failures = []
notes = []

checkout = data.get("checkout", {})
if checkout.get("account_landing") is not True:
    failures.append("checkout.account_landing must be true")
else:
    notes.append("checkout/account landing evidence present")

plan = data.get("plan", {})
before = plan.get("before_storage_gb")
after = plan.get("after_storage_gb")
displayed = plan.get("displayed_storage_gb")
if before != 50 or after != 100 or displayed != 100:
    failures.append(
        "plan storage evidence must show 50 GB before, 100 GB after, "
        f"and 100 GB displayed; got before={before!r} after={after!r} displayed={displayed!r}"
    )
else:
    notes.append("plan/storage display evidence shows 50 GB -> 100 GB upgrade")

upgrade = data.get("upgrade", {})
if upgrade.get("payment_confirmed") is not True:
    failures.append("upgrade.payment_confirmed must be true")
else:
    notes.append("payment/upgrade completion evidence present")

privacy = data.get("privacy", {})
leak_count = privacy.get("exemem_pii_leak_count")
checked = privacy.get("checked_fields")
if leak_count != 0:
    failures.append(f"privacy.exemem_pii_leak_count must be 0; got {leak_count!r}")
if not isinstance(checked, list) or not checked:
    failures.append("privacy.checked_fields must be a non-empty array")
else:
    notes.append("Exemem-side PII absence check passed for fields: " + ", ".join(map(str, checked)))

for secretish in (
    "stripe_token",
    "session_token",
    "api_key",
    "email",
    "name",
    "payment_method",
    "customer_id",
):
    if secretish in json.dumps(data).lower():
        failures.append(f"evidence contains forbidden secret/PII-like key text: {secretish}")

print("\n".join(notes))
if failures:
    print("\nFAILURES:")
    print("\n".join(f"- {failure}" for failure in failures))
    raise SystemExit(1)
PY
)"
python_rc=$?
set -e

body="$(cat <<EOF
Exemem Cloud account proof.

Mode: $MODE
Evidence file: $EVIDENCE_FILE

\`\`\`text
$python_out
\`\`\`

Covered end-state surfaces:
- anonymous checkout lands in an account experience
- plan/storage UI shows the paid 100 GB state after upgrade from 50 GB
- payment/upgrade completion is represented by redacted evidence
- Exemem-side checks found zero persisted PII leaks in the checked fields
EOF
)"

if [ "$python_rc" -ne 0 ]; then
  ns_write_report "$SLUG" FAIL "$body" || exit 1
  exit 1
fi

verdict=PASS
[ "$MODE" = offline ] && verdict=PASS-OFFLINE
ns_write_report "$SLUG" "$verdict" "$body"
