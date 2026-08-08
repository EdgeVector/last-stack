#!/usr/bin/env bash
# north-star-slug: north-star-org-cloud-principal-membership
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
SLUG=north-star-org-cloud-principal-membership
MODE="${NORTH_STAR_PROOF_MODE:-offline}"
REPORT_DIR="${NORTH_STAR_PROOF_DIR:-$HOME/.last-stack/north-star-proofs}"
REPORT="$REPORT_DIR/$SLUG.md"
mkdir -p "$REPORT_DIR"

write_report() {
  first="$1"
  shift
  {
    printf '%s\n' "$first"
    printf '%s\n' "$@"
  } >"$REPORT"
}

if [ "$MODE" = "offline" ]; then
  if bash "$ROOT/tests/last-stack-org-cloud-membership-dogfood.sh" >/dev/null; then
    write_report "PASS-OFFLINE org cloud membership harness contract" \
      "live_product_proof=false" \
      "fixture_contract=grant-member-list-presign-revoke-403-owner-list-e2e-unchanged" \
      "live_command=NORTH_STAR_PROOF_MODE=live last-stack-north-star-proof $SLUG"
    cat "$REPORT"
    exit 0
  fi
  write_report "FAIL org cloud membership harness contract" "offline fixture contract failed"
  exit 1
fi

missing=""
for name in ORG_CLOUD_MEMBERSHIP_ORG_SLUG ORG_CLOUD_MEMBERSHIP_MEMBER_USER_HASH \
  ORG_CLOUD_MEMBERSHIP_OWNER_API_KEY_REF ORG_CLOUD_MEMBERSHIP_MEMBER_API_KEY_REF \
  ORG_CLOUD_MEMBERSHIP_STORAGE_URL ORG_CLOUD_MEMBERSHIP_OWNER_SOCKET; do
  eval "value=\${$name:-}"
  [ -n "$value" ] || missing="$missing $name"
done
if [ -n "$missing" ]; then
  write_report "FAIL org cloud membership live prerequisites" \
    "missing_env=$missing" \
    "API keys must be lastsecrets:// locators; never raw values."
  exit 1
fi

args=(
  --org-slug "$ORG_CLOUD_MEMBERSHIP_ORG_SLUG"
  --member-user-hash "$ORG_CLOUD_MEMBERSHIP_MEMBER_USER_HASH"
  --owner-api-key-ref "$ORG_CLOUD_MEMBERSHIP_OWNER_API_KEY_REF"
  --member-api-key-ref "$ORG_CLOUD_MEMBERSHIP_MEMBER_API_KEY_REF"
  --storage-url "$ORG_CLOUD_MEMBERSHIP_STORAGE_URL"
  --owner-socket "$ORG_CLOUD_MEMBERSHIP_OWNER_SOCKET"
  --artifact "$REPORT"
)
[ -z "${ORG_CLOUD_MEMBERSHIP_ORG_HASH:-}" ] || args+=(--org-hash "$ORG_CLOUD_MEMBERSHIP_ORG_HASH")
[ -z "${ORG_CLOUD_MEMBERSHIP_E2E_KEY_REF:-}" ] || args+=(--e2e-key-ref "$ORG_CLOUD_MEMBERSHIP_E2E_KEY_REF")
[ -z "${ORG_CLOUD_MEMBERSHIP_ROLE:-}" ] || args+=(--role "$ORG_CLOUD_MEMBERSHIP_ROLE")

exec "$ROOT/bin/last-stack-org-cloud-membership-dogfood" "${args[@]}"
