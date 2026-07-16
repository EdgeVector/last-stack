---
name: exemem-credentials
description: |
  Mint Exemem invites. Preferred: a shareable join link
  (https://exemem.com/join/<token>) via the authenticated POST /api/invite/link
  endpoint — the link you hand to a person. Fallback: a raw EXM-XXXX-XXXX invite
  code written straight to DynamoDB for offline dogfooding/testing.
  Use when asked to "create an exemem invite link/code", "invite a friend to
  exemem", "generate an invite", "make a dogfood code", "create exemem
  credentials", or "I need an invite for prod/dev".
allowed-tools:
  - Bash
triggers:
  - exemem invite link
  - exemem invite code
  - invite a friend to exemem
  - generate invite code
  - create invite code
  - dogfood invite code
  - exemem credentials
---

# Exemem credentials

Mint an Exemem invite. There are two outputs you might want:

1. **A shareable join link** (`https://exemem.com/join/<token>`) — the
   default, human-friendly output. This is what you hand to a person: they
   click it, land on the `/join` page, and sign up. Mint these via the
   authenticated `POST /api/invite/link` endpoint (see **Mint a shareable
   join link** below). Prefer this whenever you have a session token.
2. **A raw `EXM-XXXX-XXXX` code** — the offline / dogfooding fallback,
   written straight to DynamoDB. Use this only when you have no session token
   (no portal login) and need a redeemable code right now (see **Raw code,
   direct DynamoDB (fallback)** below).

> **Default to the link.** Tom's core ask is "create a link that goes to
> exemem that they can send to someone, rather than just showing the invite
> code." Print the `join_url` as the primary output; only fall back to the
> raw-code path when you genuinely can't authenticate.

## Mint a shareable join link (preferred)

`POST /api/invite/link` is authenticated (Bearer session token, same as the
developer API-key CRUD). It mints a real redeemable invite code under the
hood, stores a link row, and returns a ready-to-send URL.

| Env  | API base                                               |
|------|--------------------------------------------------------|
| dev  | `https://ygyu7ritx8.execute-api.us-west-2.amazonaws.com` |
| prod | `https://exemem.com`                                     |

You need an Exemem **session token** (from a passkey login). If you have a
portal browser session, it's in `localStorage.exemem_session_token`. Export it
as `EXEMEM_SESSION_TOKEN`.

```bash
ENV="${1:-prod}"
case "$ENV" in
  dev)  API="https://ygyu7ritx8.execute-api.us-west-2.amazonaws.com" ;;
  prod) API="https://exemem.com" ;;
  *) echo "ENV must be dev or prod"; exit 1 ;;
esac
: "${EXEMEM_SESSION_TOKEN:?set EXEMEM_SESSION_TOKEN (passkey session token)}"

# Optional: who's inviting (feeds the /join page's "invited by" card).
SENDER_NAME="${SENDER_NAME:-}"
CONTACT_HINT="${CONTACT_HINT:-}"

curl -fsS -X POST "$API/api/invite/link" \
  -H "Authorization: Bearer $EXEMEM_SESSION_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"sender_name\":\"$SENDER_NAME\",\"sender_contact_hint\":\"$CONTACT_HINT\"}"
# => {"ok":true,"token":"...","code":"EXM-XXXX-XXXX","join_url":"https://exemem.com/join/<token>","expires_at":...}
```

Hand the `join_url` to the recipient. The `code` in the response is the same
redeemable code (useful as a fallback if they can't open the link).

> The mint endpoint is implemented in `auth_service`
> (`fold/exemem_service/lambdas/auth_service/src/invite_links/`). If it returns
> `404`, that environment hasn't been deployed with the invite-link backend
> yet — use the raw-code fallback below until it ships.

## Raw code, direct DynamoDB (fallback)

When you have no session token (offline dogfooding, no portal login), write a
raw code straight into the `ExememInviteCodes-{env}` table. The auth_service
redeem path looks up the item by `code` and only checks
`attribute_exists(code) AND attribute_not_exists(redeemed_by)` — but the item
must use the schema written by `create_code`, otherwise some downstream paths
(listing, expiry sweeps) misbehave.

## Environments

| Env  | Region    | Table                    |
|------|-----------|--------------------------|
| dev  | us-west-2 | `ExememInviteCodes-dev`  |
| prod | us-east-1 | `ExememInviteCodes-prod` |

If the env isn't specified, ask before writing to prod.

## Code format

`EXM-XXXX-XXXX` where `X ∈ [A-HJ-KMNP-Z2-9]` (uppercase, excludes `0 1 I L O`
to avoid visual ambiguity). Match this format exactly — non-`EXM-` prefixes
or lowercase will be rejected by users / portal validators downstream.

## Required item schema

The auth_service writes items with these fields (see
[stores.rs:24-37](../../code/edgevector/exemem-infra/lambdas/auth_service/src/invite_codes/stores.rs)).
Match this schema; do **not** add `max_uses`, `used_count`, or `active` —
those are not part of the contract.

| Attribute           | Type | Value                                 |
|---------------------|------|---------------------------------------|
| `code`              | S    | `EXM-XXXX-XXXX`                       |
| `creator_user_hash` | S    | identifier of who created it          |
| `created_at`        | S    | RFC3339 (`date -u +%Y-%m-%dT%H:%M:%SZ`) |
| `expires_at`        | N    | unix epoch — table TTL drops past this |

## One-shot generator

```bash
ENV="${1:-prod}"   # dev | prod
case "$ENV" in
  dev)  REGION=us-west-2; TABLE=ExememInviteCodes-dev ;;
  prod) REGION=us-east-1; TABLE=ExememInviteCodes-prod ;;
  *) echo "ENV must be dev or prod"; exit 1 ;;
esac

CODE="EXM-$(LC_ALL=C tr -dc 'A-HJ-KMNP-Z2-9' </dev/urandom | head -c4)-$(LC_ALL=C tr -dc 'A-HJ-KMNP-Z2-9' </dev/urandom | head -c4)"
EXPIRES_AT=$(($(date +%s) + 30*24*3600))   # 30 days
CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
CREATOR="${USER:-manual}-manual"

aws dynamodb put-item \
  --table-name "$TABLE" \
  --item "{\"code\":{\"S\":\"$CODE\"},\"creator_user_hash\":{\"S\":\"$CREATOR\"},\"created_at\":{\"S\":\"$CREATED_AT\"},\"expires_at\":{\"N\":\"$EXPIRES_AT\"}}" \
  --region "$REGION"

echo "Code: $CODE  (env=$ENV, expires=$(date -r $EXPIRES_AT))"
```

## Verify

```bash
aws dynamodb get-item \
  --table-name "$TABLE" \
  --key "{\"code\":{\"S\":\"$CODE\"}}" \
  --region "$REGION"
```

The item should not have a `redeemed_by` field; the moment a user registers
with it, `redeem_code` adds that field and the code becomes single-use.

## Common mistakes

- **Wrong region.** Dev is us-west-2, prod is us-east-1 — they're different
  regions, not different account aliases. `aws dynamodb list-tables` in the
  wrong region returns "ResourceNotFoundException".
- **Wrong schema.** Adding `max_uses`/`active` looks fine to put-item but the
  validate/list endpoints will misreport state. Stick to the four fields above.
- **Wrong prefix.** Codes that don't start with `EXM-` are rejected by the
  portal validator before they ever hit DynamoDB.
- **Lowercase code.** Lookup is case-sensitive (line 51 of stores.rs).
