#!/usr/bin/env bash
# Regenerate the redacted live evidence file for
# north-star-exemem-cloud-account from a throwaway copy of a connected
# identity.
#
# Honors brain decision-2026-08-17-exemem-proof-use-existing-paid-account:
# read-only observation of the account that is ALREADY paid. This script never
# runs `lastdb cloud setup-paid`, never runs `lastdb cloud upgrade` (only its
# --help), and never opens Stripe Checkout.
#
# The output holds ONLY the boolean and whole-number fields the proof
# validator reads. No
# URL, no bearer token, no key material, no plan identifier, no per-database
# scope hash, and no byte counts reach the file.
#
# Usage:
#   EXEMEM_CLOUD_ACCOUNT_LASTDB_HOME=/path/to/throwaway \
#     harness/north-star/exemem-cloud-account/collect-live-evidence.sh \
#     [--out <file>]
#
# Build the throwaway home by copying cloud_sync.json out of a connected home.
# Never pass the primary brain (~/.lastdb): this script refuses it.
set -euo pipefail

OUT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

HOME_DIR="${EXEMEM_CLOUD_ACCOUNT_LASTDB_HOME:-}"
if [ -z "$HOME_DIR" ]; then
  echo "EXEMEM_CLOUD_ACCOUNT_LASTDB_HOME is required (throwaway home)" >&2
  exit 2
fi
resolved="$(cd "$HOME_DIR" 2>/dev/null && pwd -P || printf '%s\n' "$HOME_DIR")"
case "$resolved" in
  "$HOME/.lastdb"|"$HOME/.lastdb/"*|"$HOME/.folddb"|"$HOME/.folddb/"*)
    echo "refusing primary brain path: $resolved" >&2
    exit 2
    ;;
esac
if [ ! -f "$resolved/cloud_sync.json" ]; then
  echo "throwaway home has no cloud_sync.json: $resolved" >&2
  echo "copy it from a connected home first (read-only copy)" >&2
  exit 2
fi

python3 - "$resolved" "$OUT" <<'PY'
import json
import os
import re
import subprocess
import sys

home, out_path = sys.argv[1], sys.argv[2]
env = os.environ.copy()
env["LASTDB_HOME"] = home
env.pop("FOLDDB_SOCKET_PATH", None)
env.pop("LASTDB_SOCKET", None)

GIB = 1024 ** 3
# The account payload must carry no person-identifying field. Anything here is
# a leak, and a leak must raise the count the validator refuses to pass.
PII_KEYS = {
    "email",
    "name",
    "full_name",
    "address",
    "phone",
    "customer_id",
    "payment_method",
}
EMAIL_SHAPE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")


def run(args):
    proc = subprocess.run(
        args, env=env, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False,
    )
    return proc.returncode, proc.stdout


def die(message):
    print(f"collect-live-evidence: {message}", file=sys.stderr)
    raise SystemExit(1)


account_rc, account_out = run(["lastdb", "cloud", "account", "--json", "--no-open"])
upgrade_rc, upgrade_out = run(["lastdb", "cloud", "upgrade", "--help"])
if account_rc != 0:
    die(f"lastdb cloud account failed (rc={account_rc})")

brace = account_out.find("{")
if brace < 0:
    die("lastdb cloud account printed no JSON object")
try:
    payload = json.loads(account_out[brace:])
except json.JSONDecodeError as err:
    die(f"account JSON not parseable: {err}")

leaks = []
inspected = []


def inspect(obj, path=""):
    if isinstance(obj, dict):
        for key, value in obj.items():
            here = f"{path}.{key}" if path else str(key)
            inspected.append(here)
            if str(key).lower() in PII_KEYS:
                leaks.append(here)
            elif isinstance(value, str) and EMAIL_SHAPE.search(value):
                leaks.append(here)
            inspect(value, here)
    elif isinstance(obj, list):
        for item in obj:
            inspect(item, path)


inspect(payload)

status = payload.get("account", {}).get("status", {})
quota_bytes = status.get("paid_quota_bytes")
if not isinstance(quota_bytes, int) or quota_bytes <= 0:
    die("account status carries no paid_quota_bytes")

evidence = {
    "checkout": {
        "account_url_present": bool(payload.get("url")),
    },
    "upgrade": {
        "existing_paid_account": status.get("plan") == "paid"
        and status.get("has_subscription") is True
        and status.get("access_allowed") is True,
        "path_reachable": upgrade_rc == 0 and "Stripe Checkout" in upgrade_out,
    },
    "plan": {
        "displayed_storage_gb": quota_bytes // GIB,
    },
    "privacy": {
        "exemem_pii_leak_count": len(leaks),
        # Deduplicated shapes, not values: a repeated list element carries the
        # same path, and the reviewer needs the surface, not the row count.
        "checked_fields": sorted({field for field in inspected}),
    },
}

text = json.dumps(evidence, indent=2, sort_keys=True) + "\n"
if out_path:
    with open(out_path, "w", encoding="utf-8") as handle:
        handle.write(text)
    print(f"wrote {out_path}", file=sys.stderr)
else:
    sys.stdout.write(text)
PY
