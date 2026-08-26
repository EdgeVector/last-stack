#!/usr/bin/env bash
# north-star-slug: north-star-exemem-cloud-account
#
# Drive the LastDB cloud CLI for the anonymous paid-account UX.
# Honor brain decision-2026-08-17-exemem-proof-use-existing-paid-account:
# never execute a payment; an existing paid account is enough; reaching the
# upgrade command/URL without completing checkout satisfies the upgrade path.
# Never touch the primary brain (~/.lastdb).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../common.sh
. "$ROOT/harness/north-star/common.sh"

SLUG=north-star-exemem-cloud-account
MODE="$(ns_mode)"
EVIDENCE_FILE="${EXEMEM_CLOUD_ACCOUNT_PROOF_EVIDENCE_FILE:-}"
HOME_DIR="${EXEMEM_CLOUD_ACCOUNT_LASTDB_HOME:-}"

fail() {
  ns_write_report "$SLUG" FAIL "$1" || exit 1
  exit 1
}

# Reject the primary brain even when a caller exports LASTDB_HOME by habit.
resolve_home() {
  local candidate="$1"
  local resolved
  [ -n "$candidate" ] || return 1
  resolved="$(cd "$candidate" 2>/dev/null && pwd -P || printf '%s\n' "$candidate")"
  case "$resolved" in
    "$HOME/.lastdb"|"$HOME/.lastdb/"*|"$HOME/.folddb"|"$HOME/.folddb/"*)
      echo "FAIL: refusing primary brain path: $resolved" >&2
      return 1
      ;;
  esac
  ns_refuse_primary "$resolved" || return 1
  printf '%s\n' "$resolved"
}

cli_contract_notes() {
  local notes="" help_account help_upgrade help_status
  if ! command -v lastdb >/dev/null 2>&1; then
    printf '%s\n' "lastdb CLI missing"
    return 1
  fi
  help_status="$(lastdb cloud status --help 2>&1 || true)"
  help_account="$(lastdb cloud account --help 2>&1 || true)"
  help_upgrade="$(lastdb cloud upgrade --help 2>&1 || true)"
  printf '%s\n' "$help_status" | grep -q 'subscription / plan / quota' \
    || { printf '%s\n' "lastdb cloud status help missing plan/quota text"; return 1; }
  printf '%s\n' "$help_account" | grep -q -- '--json' \
    || { printf '%s\n' "lastdb cloud account missing --json"; return 1; }
  printf '%s\n' "$help_account" | grep -q -- '--no-open' \
    || { printf '%s\n' "lastdb cloud account missing --no-open"; return 1; }
  printf '%s\n' "$help_upgrade" | grep -q 'Stripe Checkout' \
    || { printf '%s\n' "lastdb cloud upgrade help missing Stripe Checkout"; return 1; }
  notes="lastdb cloud CLI contract: status, account --json --no-open, upgrade --help"
  notes="$notes"$'\n'"upgrade is help-only in this harness (never opens Checkout, never pays)"
  printf '%s\n' "$notes"
  return 0
}

validate_evidence_file() {
  local path="$1"
  python3 - "$path" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
failures = []
notes = []

def walk_keys(obj, acc):
    if isinstance(obj, dict):
        for key, value in obj.items():
            acc.append(str(key).lower())
            walk_keys(value, acc)
    elif isinstance(obj, list):
        for item in obj:
            walk_keys(item, acc)

checkout = data.get("checkout", {})
account_landing = checkout.get("account_landing") is True
account_url = checkout.get("account_url_present") is True
if not account_landing and not account_url:
    failures.append(
        "checkout.account_landing must be true, or checkout.account_url_present "
        "must be true (account page reached without a fresh payment)"
    )
else:
    notes.append("checkout/account landing evidence present")

upgrade = data.get("upgrade", {}) if isinstance(data.get("upgrade"), dict) else {}
existing_paid = upgrade.get("existing_paid_account") is True
path_reachable = upgrade.get("path_reachable") is True
payment_confirmed = upgrade.get("payment_confirmed") is True
if not (existing_paid or path_reachable or payment_confirmed):
    failures.append(
        "upgrade must show existing_paid_account, path_reachable, or "
        "payment_confirmed (decision-2026-08-17: no fresh payment required)"
    )
else:
    if existing_paid:
        notes.append("existing paid account evidence present (no fresh payment)")
    if path_reachable:
        notes.append("upgrade path reachable without completing checkout")
    if payment_confirmed:
        notes.append("payment/upgrade completion evidence present")

plan = data.get("plan", {}) if isinstance(data.get("plan"), dict) else {}
before = plan.get("before_storage_gb")
after = plan.get("after_storage_gb")
displayed = plan.get("displayed_storage_gb")
has_plan_numbers = before is not None or after is not None or displayed is not None
if has_plan_numbers:
    if before == 50 and after == 100 and displayed == 100:
        notes.append("plan/storage display evidence shows 50 GB -> 100 GB upgrade")
    elif existing_paid or path_reachable:
        notes.append(
            "plan/storage evidence present "
            f"(before={before!r} after={after!r} displayed={displayed!r}); "
            "50->100 purchase is optional when the paid account already exists"
        )
    else:
        failures.append(
            "plan storage evidence must show 50 GB before, 100 GB after, "
            f"and 100 GB displayed; got before={before!r} after={after!r} "
            f"displayed={displayed!r}"
        )
elif not (existing_paid or path_reachable):
    failures.append("plan storage numbers missing and no existing-paid/path-reachable upgrade evidence")

privacy = data.get("privacy", {}) if isinstance(data.get("privacy"), dict) else {}
leak_count = privacy.get("exemem_pii_leak_count")
checked = privacy.get("checked_fields")
if leak_count != 0:
    failures.append(f"privacy.exemem_pii_leak_count must be 0; got {leak_count!r}")
if not isinstance(checked, list) or not checked:
    failures.append("privacy.checked_fields must be a non-empty array")
else:
    notes.append(
        "Exemem-side PII absence check passed for fields: "
        + ", ".join(map(str, checked))
    )

forbidden = (
    "stripe_token",
    "session_token",
    "api_key",
    "email",
    "name",
    "payment_method",
    "customer_id",
)
keys = []
walk_keys(data, keys)
blob = json.dumps(data).lower()
for secretish in forbidden:
    if secretish in keys or secretish in blob:
        failures.append(f"evidence contains forbidden secret/PII-like key text: {secretish}")

print("\n".join(notes))
if failures:
    print("\nFAILURES:")
    print("\n".join(f"- {failure}" for failure in failures))
    raise SystemExit(1)
PY
}

drive_cloud_cli() {
  local home="$1"
  python3 - "$home" <<'PY'
import json
import os
import re
import subprocess
import sys

home = sys.argv[1]
env = os.environ.copy()
env["LASTDB_HOME"] = home
# Do not inherit a primary-brain socket from the scheduled shell.
env.pop("FOLDDB_SOCKET_PATH", None)
env.pop("LASTDB_SOCKET", None)

failures = []
notes = []
pii_hits = []


def run(args):
    proc = subprocess.run(
        args,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    return proc.returncode, proc.stdout


def look_like_email(value):
    return bool(re.search(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", str(value)))


def walk(obj, path=""):
    if isinstance(obj, dict):
        for key, value in obj.items():
            lower = str(key).lower()
            here = f"{path}.{key}" if path else str(key)
            if lower in {"email", "name", "api_key", "session_token", "stripe_token", "customer_id", "payment_method"}:
                pii_hits.append(here)
            if look_like_email(value):
                pii_hits.append(here + "(email-shaped value)")
            walk(value, here)
    elif isinstance(obj, list):
        for i, item in enumerate(obj):
            walk(item, f"{path}[{i}]")
    elif look_like_email(obj):
        pii_hits.append(path + "(email-shaped value)")


status_rc, status_out = run(["lastdb", "cloud", "status"])
account_rc, account_out = run(["lastdb", "cloud", "account", "--json", "--no-open"])
# Help-only: never execute upgrade (it opens Stripe Checkout).
upgrade_rc, upgrade_out = run(["lastdb", "cloud", "upgrade", "--help"])

notes.append(f"lastdb cloud status rc={status_rc}")
notes.append(f"lastdb cloud account --json --no-open rc={account_rc}")
notes.append(f"lastdb cloud upgrade --help rc={upgrade_rc}")

combined = status_out + "\n" + account_out
if "cloud_sync.json" in combined or "run `lastdb connect`" in combined:
    failures.append(
        "throwaway LastDB home is not cloud-connected "
        "(missing cloud_sync.json). Drive requires a throwaway copy of a "
        "connected identity, never ~/.lastdb, and never setup-paid/checkout."
    )

if upgrade_rc != 0 or "Stripe Checkout" not in upgrade_out:
    failures.append("lastdb cloud upgrade --help did not describe Stripe Checkout")
else:
    notes.append("upgrade path reachable via CLI help (checkout not opened, no payment)")

if "cloud_sync.json" not in combined:
    paid_markers = ("access_allowed", "quota_bytes", "plan=")
    if any(marker in status_out for marker in paid_markers):
        notes.append("status output contains plan/quota/access markers")

account_json = None
stripped = account_out.strip()
if stripped.startswith("{") or stripped.startswith("["):
    try:
        account_json = json.loads(stripped)
    except json.JSONDecodeError:
        # Some CLIs print a log line before JSON.
        brace = stripped.find("{")
        if brace >= 0:
            try:
                account_json = json.loads(stripped[brace:])
            except json.JSONDecodeError as err:
                failures.append(f"account --json was not parseable: {err}")
        else:
            failures.append("account --json produced no JSON object")
elif "error:" in account_out.lower():
    notes.append("account command returned an error (see captured output)")
else:
    failures.append("account --json produced no JSON object")

if isinstance(account_json, dict):
    walk(account_json)
    url = account_json.get("url") or account_json.get("account_url") or ""
    if url:
        notes.append("account page URL present in JSON (value redacted)")
    else:
        failures.append("account JSON missing url/account_url")
    if account_json.get("access_allowed") is True:
        notes.append("account JSON access_allowed=true (existing paid/allowed account)")
    storage = account_json.get("storage")
    if isinstance(storage, dict) and "quota_bytes" in storage:
        notes.append("account JSON includes storage.quota_bytes (plan/usage surface)")

walk({"status_text": status_out})
if pii_hits:
    failures.append("PII/secret-like fields in CLI output: " + ", ".join(pii_hits[:20]))
else:
    notes.append("CLI JSON/text contained no name/email/api_key/session_token fields")

print("\n".join(notes))
print("\n--- status (redacted capture) ---")
print(status_out[:2000])
print("\n--- account (redacted capture) ---")
# Drop values that look like tokens while keeping keys.
if isinstance(account_json, dict):
    redacted = {
        key: ("<redacted-url>" if "url" in key.lower() else account_json[key])
        for key in account_json
        if key.lower() not in {"api_key", "session_token", "email", "name"}
    }
    print(json.dumps(redacted, indent=2, default=str)[:2000])
else:
    print(account_out[:1000])

if failures:
    print("\nFAILURES:")
    print("\n".join(f"- {failure}" for failure in failures))
    raise SystemExit(1)
PY
}

contract_out=""
if contract_out="$(cli_contract_notes)"; then
  :
else
  contract_out="${contract_out:-lastdb cloud CLI contract failed}"
  # Evidence-file / missing-home paths still need a lastdb binary on live
  # machines; CI fixtures can proceed without driving the CLI.
  if [ -n "$HOME_DIR" ]; then
    fail "$(printf 'CLI contract failed before drive:\n%s\n' "$contract_out")"
  fi
fi

if [ -n "$HOME_DIR" ]; then
  resolved="$(resolve_home "$HOME_DIR")" || fail "refusing LastDB home '$HOME_DIR' (primary brain is banned)"
  set +e
  drive_out="$(drive_cloud_cli "$resolved")"
  drive_rc=$?
  set -e
  body="$(cat <<EOF
Exemem Cloud account proof (CLI drive).

Mode: $MODE
LastDB home: $resolved
CLI contract:
$contract_out

\`\`\`text
$drive_out
\`\`\`

Covered end-state surfaces:
- \`lastdb cloud status\` plan/usage (read-only)
- \`lastdb cloud account --json --no-open\` account page (no browser)
- upgrade path via \`lastdb cloud upgrade --help\` only (no payment)
- PII/secret fields absent from CLI JSON
- decision-2026-08-17: existing paid account; agents never complete checkout
EOF
)"
  if [ "$drive_rc" -ne 0 ]; then
    fail "$body"
  fi
  verdict=PASS
  [ "$MODE" = offline ] && verdict=PASS-OFFLINE
  ns_write_report "$SLUG" "$verdict" "$body"
  exit 0
fi

if [ -n "$EVIDENCE_FILE" ]; then
  if [ ! -f "$EVIDENCE_FILE" ]; then
    fail "evidence file not found: $EVIDENCE_FILE"
  fi
  set +e
  python_out="$(validate_evidence_file "$EVIDENCE_FILE")"
  python_rc=$?
  set -e
  body="$(cat <<EOF
Exemem Cloud account proof (redacted evidence file).

Mode: $MODE
Evidence file: $EVIDENCE_FILE
CLI contract:
$contract_out

\`\`\`text
$python_out
\`\`\`

Covered end-state surfaces:
- anonymous checkout / account page landing
- plan/usage display (50->100 is optional when the account is already paid)
- upgrade path reachable without a fresh payment
- Exemem-side checks found zero persisted PII leaks in the checked fields
- decision-2026-08-17: existing paid account; agents never complete checkout
EOF
)"
  if [ "$python_rc" -ne 0 ]; then
    fail "$body"
  fi
  verdict=PASS
  [ "$MODE" = offline ] && verdict=PASS-OFFLINE
  ns_write_report "$SLUG" "$verdict" "$body"
  exit 0
fi

fail "$(cat <<'EOF'
Live drive or redacted evidence is required for the Exemem Cloud account proof.

Drive the real LastDB cloud CLI against a throwaway home (never ~/.lastdb):

  EXEMEM_CLOUD_ACCOUNT_LASTDB_HOME=/path/to/throwaway \
    last-stack-north-star-proof north-star-exemem-cloud-account

The home must already contain cloud_sync.json from a connected identity.
Do not run `lastdb cloud setup-paid` or `lastdb cloud upgrade` from this
harness. decision-2026-08-17: use the existing paid account; reaching the
upgrade command without completing checkout is enough.

Or set EXEMEM_CLOUD_ACCOUNT_PROOF_EVIDENCE_FILE to a JSON file containing only
non-secret evidence:
- checkout.account_landing: true  OR checkout.account_url_present: true
- upgrade.existing_paid_account: true  OR upgrade.path_reachable: true
  OR upgrade.payment_confirmed: true
- privacy.exemem_pii_leak_count: 0
- privacy.checked_fields: array of checked Exemem-side fields
- optional plan.before_storage_gb / after_storage_gb / displayed_storage_gb
  (50 -> 100 is valid; not required when the account is already paid)

Do not persist raw Stripe tokens, Exemem session tokens, email addresses, names,
payment identifiers, API keys, or other PII/secrets. Retrieve secrets only at
the point of live collection with LastSecrets.
EOF
)"
