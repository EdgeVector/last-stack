---
name: app-identity-dev-enroll
description: |
  Self-provision a developer for app_identity v3.1: mint an EXEMEM_DEV_API_KEY
  (em_<48 hex>) into Exemem's API-keys DynamoDB table, run
  `folddb-dev developer init` to materialize the local Ed25519 keypair, and
  enroll the resulting pubkey into ExememDevelopers-{env} so the developer
  can mint DevCerts and publish apps + schemas. Dev env: fully autonomous
  (writes the DDB rows directly). Prod env: refuses to write the developers
  row (admin gate per design); produces a runbook for the human admin.
  Use when asked to "enroll developer", "register developer", "set up dev
  cert", "mint exemem dev api key", "developer init", "onboard dev for app
  identity", or whenever a publish path errors with `not_a_developer`.
allowed-tools:
  - Bash
triggers:
  - enroll developer
  - register developer
  - set up dev cert
  - mint exemem dev api key
  - mint dev api key
  - developer init
  - onboard developer for app identity
  - not a developer
  - app identity developer enrollment
---

# App Identity dev enrollment

Bring a fresh developer (or a fresh machine for an existing developer) to
the state where `folddb-dev app publish` + `folddb-dev schema publish
--app <id>` work. The output is a populated `~/.folddb-dev/developer/`
keypair + a row in `ExememDevelopers-{env}` + (dev only) an
`EXEMEM_DEV_API_KEY` minted into the API-keys DynamoDB table.

This is the "Step 1 + 2a/2b" subset of the larger `app-identity-dogfood`
flow, factored out for reuse: any app developer (brain, kanban, future
third-party) onboards through this skill, then runs the publish steps for
their own app.

Authoritative spec: `~/code/edgevector/exemem-workspace/docs/designs/app_identity.md`
(v3.1). Sections: *Developer enrollment & cert minting*, *Two keys, one
consent-token model*.

## 🛑 Hard safety rules (read first)

1. **Prod row writes are admin-gated by design.** The skill refuses to put
   a row into `ExememDevelopers-prod` no matter how it's invoked — if the
   target env is prod, the skill prints the exact `aws dynamodb put-item`
   command for a human admin to run and stops. The prod *API key* mint is
   also refused (same reason — prod keys are issued via the portal +
   billing flow, not by an autonomous skill).
2. **Idempotent re-runs.** Existing rows are not overwritten; existing
   keypairs are not rotated. If the developer keypair already exists, the
   skill reuses it. If the developer is already enrolled, the skill is a
   no-op. Pass `--rotate-key` to opt into key rotation (NOT default —
   rotating invalidates every DevCert minted from the old key).
3. **Never run `folddb-dev developer init --force`** unless the user
   explicitly asks. `--force` rotates the keypair, the old one stops
   minting DevCerts, and every published-app row that names the old
   `owner_dev_pubkey` becomes orphaned (those apps can no longer be
   re-published or have their schemas extended by this machine).
4. **Don't touch the primary fold_db_node daemon (the folddb_server brain)** — this skill writes
   to DynamoDB and runs `folddb-dev` CLI verbs; it does NOT start a dev
   session and does NOT need the homebrew daemon.

## Inputs

Resolved from arguments / env / sensible defaults, in order:

| Variable | Default | How resolved |
|---|---|---|
| `ENV`        | `dev` | First positional arg or `--env`. Accepts `dev` or `prod`. |
| `USER_HASH`  | required | Second positional arg or `--user-hash`. Must be a stable identifier for this developer (e.g. `tomtang-brain-dev`, `kanban-rust-dev`). Ask if not provided. |
| `HANDLE`     | `$USER_HASH` | `--handle`. Cosmetic; recorded in the local keypair file alongside the key, never sent on the wire. |

If `USER_HASH` is ambiguous (no arg + ambiguous from the prompt), ASK the
user — don't pick one. Re-running with a different `USER_HASH` is fine
(it provisions a separate enrollment) but wastes a DDB row.

## Tables (canonical names)

Match these EXACTLY — the CDK uses generated names with random suffixes.

| Env  | Region    | API-keys table                                       | Developers table        |
|------|-----------|------------------------------------------------------|-------------------------|
| dev  | us-west-2 | `ExememStack-dev-ApiKeysTable9F4DC7E7-ECJE82X9TR56`  | `ExememDevelopers-dev`  |
| prod | us-east-1 | (find via `aws dynamodb list-tables` — name carries a different CDK suffix) | `ExememDevelopers-prod` |

If a table name above is stale (the CDK was redeployed and the suffix
changed), find the current name via
`aws dynamodb list-tables --region us-west-2 --query "TableNames[?contains(@, \`ApiKeys\`)]"`
and update the skill — don't silently fall back to a guess.

## Step 1 — guard prod (refuses + emits runbook)

```bash
if [ "$ENV" = "prod" ]; then
  cat <<'EOF'
PROD ENROLLMENT IS ADMIN-GATED — this skill refuses to write production
rows. Send the following two commands to a human Exemem admin (or run
them yourself with admin credentials):

  # 1. Mint an EXEMEM_DEV_API_KEY (issued via portal/Stripe in steady
  #    state; this is the dev-only bypass shape).
  REGION=us-east-1
  API_TBL=$(aws dynamodb list-tables --region "$REGION" \
    --query "TableNames[?contains(@, 'ApiKeys')]" --output text)
  USER_HASH=<the developer's identifier>
  NOW_EPOCH=$(date -u +%s)
  API_KEY="em_$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c48)"
  KEY_HASH=$(printf '%s' "$API_KEY" | shasum -a 256 | cut -d' ' -f1)
  aws dynamodb put-item --region "$REGION" --table-name "$API_TBL" \
    --item "{\"api_key_hash\":{\"S\":\"$KEY_HASH\"},\"user_hash\":{\"S\":\"$USER_HASH\"},\"created_at\":{\"N\":\"$NOW_EPOCH\"},\"is_active\":{\"BOOL\":true},\"label\":{\"S\":\"app-identity-dev-enroll prod\"}}"
  echo "API_KEY=$API_KEY  (send securely to the developer)"

  # 2. Enroll the developer's local pubkey (the developer first runs
  #    `folddb-dev developer init` on their machine and ships you the
  #    base64 pubkey).
  DEV_PUBKEY=<base64 ed25519 pubkey from the developer>
  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # developer_access=true is the publish gate (fold PR #444): without it the
  # cert mints but schema_service 403s not_authorized_publisher. (In prod a
  # paid billing plan also satisfies the gate; the explicit grant is the
  # invite/admin path.)
  aws dynamodb put-item --region "$REGION" --table-name ExememDevelopers-prod \
    --item "{\"user_hash\":{\"S\":\"$USER_HASH\"},\"dev_pubkey\":{\"S\":\"$DEV_PUBKEY\"},\"status\":{\"S\":\"active\"},\"developer_access\":{\"BOOL\":true},\"enrolled_at\":{\"S\":\"$NOW\"},\"enrolled_by\":{\"S\":\"<admin user_hash>\"}}"
EOF
  exit 0
fi
```

## Step 2 — mint EXEMEM_DEV_API_KEY (dev only)

```bash
REGION=us-west-2
API_TBL=ExememStack-dev-ApiKeysTable9F4DC7E7-ECJE82X9TR56
NOW_EPOCH=$(date -u +%s)

# Idempotency check: if a row with label "app-identity-dev-enroll" already
# exists for this USER_HASH, reuse it instead of minting a new key. This
# avoids leaving orphan keys in DynamoDB across re-runs.
existing=$(aws dynamodb query --region "$REGION" --table-name "$API_TBL" \
  --index-name user_hash_index \
  --key-condition-expression "user_hash = :u" \
  --expression-attribute-values "{\":u\":{\"S\":\"$USER_HASH\"}}" \
  --query 'Items[?label.S==`app-identity-dev-enroll` && is_active.BOOL==`true`] | [0].api_key_hash.S' \
  --output text 2>/dev/null)

if [ -n "$existing" ] && [ "$existing" != "None" ]; then
  echo "found existing dev API key for user_hash=$USER_HASH (last8 of hash …${existing: -8})"
  echo "    NOTE: original key plaintext is NOT recoverable from DDB"
  echo "    (hash-only at rest). If you don't have the plaintext, pass"
  echo "    --rotate-key to mint a fresh one (the old hash is left in"
  echo "    place; the old plaintext stops authenticating only if you"
  echo "    explicitly delete its row)."
  if [ "$ROTATE_KEY" != "1" ]; then exit 0; fi
fi

# Mint + write.
API_KEY="em_$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c48)"
KEY_HASH=$(printf '%s' "$API_KEY" | shasum -a 256 | cut -d' ' -f1)
aws dynamodb put-item --region "$REGION" --table-name "$API_TBL" \
  --item "{\"api_key_hash\":{\"S\":\"$KEY_HASH\"},\"user_hash\":{\"S\":\"$USER_HASH\"},\"created_at\":{\"N\":\"$NOW_EPOCH\"},\"is_active\":{\"BOOL\":true},\"label\":{\"S\":\"app-identity-dev-enroll\"}}"

# Persist the plaintext where the user can pick it up — DDB only keeps the
# hash, so this is the one and only chance to capture it. Use a per-USER_HASH
# path so re-runs for different developers don't collide.
OUT=/tmp/app-identity-dev-enroll/$ENV/$USER_HASH
mkdir -p "$OUT"
printf '%s\n' "$API_KEY" > "$OUT/EXEMEM_DEV_API_KEY"
chmod 600 "$OUT/EXEMEM_DEV_API_KEY"
echo "wrote EXEMEM_DEV_API_KEY → $OUT/EXEMEM_DEV_API_KEY (last6 …${API_KEY: -6})"
```

**Schema requirements (must match `exemem_common::api_key::validate_api_key`):**

- `api_key_hash` (S) — `sha256_hex(em_<48 hex>)`, primary key
- `user_hash` (S) — supplied above; GSI partition key
- `created_at` (N) — unix epoch seconds; GSI sort key. **MUST be N** —
  `validate_api_key` reads it as a number and reject-mismatches a String.
- `is_active` (BOOL) — true. `validate_api_key` reads with `unwrap_or(false)`,
  so a missing value authenticates as deactivated → 401.
- `label` (S) — used by this skill to find existing rows on idempotent
  re-runs. Keep the literal string `"app-identity-dev-enroll"`.

## Step 3 — `folddb-dev developer init` (local keypair)

```bash
BIN=$(command -v folddb-dev || echo ~/code/edgevector/fold_dev_node/target/release/folddb-dev)
if [ ! -x "$BIN" ]; then
  echo "ERROR: folddb-dev not on PATH and no release build at the fallback."
  echo "  Build it first: cd ~/code/edgevector/fold_dev_node && cargo build --release"
  exit 1
fi

# Idempotent. Re-running with the same handle is a no-op; output names the
# existing public key. `--force` rotates the key — never use unless the user
# explicitly asks (see safety rule #3).
"$BIN" developer init --handle "$HANDLE"

# Read the pubkey (base64 ed25519). The init output formats are:
#   public key:  <base64>
#   key id:      <hex sha256>
# Grab the first; that's what gets enrolled.
DEV_PUBKEY=$("$BIN" developer init 2>/dev/null | awk -F': *' '/public key/{print $2; exit}')
if [ -z "$DEV_PUBKEY" ]; then
  echo "ERROR: could not read DEV_PUBKEY from \`folddb-dev developer init\` output."
  echo "  Run it manually and copy the 'public key:' value."
  exit 1
fi
echo "DEV_PUBKEY=$DEV_PUBKEY"
```

## Step 4 — enroll the dev pubkey in ExememDevelopers-{env}

```bash
DEV_TBL=ExememDevelopers-$ENV
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Idempotency: if the user_hash is already enrolled with the SAME pubkey,
# backfill the `developer_access` grant (a row enrolled before fold PR #444
# may lack it) and finish. If the user_hash is enrolled with a DIFFERENT
# pubkey (key rotation scenario), bail loudly — the human needs to decide
# whether to revoke the old enrollment first.
existing_pubkey=$(aws dynamodb get-item --region "$REGION" --table-name "$DEV_TBL" \
  --key "{\"user_hash\":{\"S\":\"$USER_HASH\"}}" \
  --query 'Item.dev_pubkey.S' --output text 2>/dev/null)

if [ -n "$existing_pubkey" ] && [ "$existing_pubkey" != "None" ]; then
  if [ "$existing_pubkey" = "$DEV_PUBKEY" ]; then
    echo "developer already enrolled with the same pubkey — ensuring developer_access grant"
    aws dynamodb update-item --region "$REGION" --table-name "$DEV_TBL" \
      --key "{\"user_hash\":{\"S\":\"$USER_HASH\"}}" \
      --update-expression "SET developer_access = :t" \
      --expression-attribute-values "{\":t\":{\"BOOL\":true}}"
    exit 0
  else
    echo "ERROR: user_hash=$USER_HASH is already enrolled with a DIFFERENT pubkey:"
    echo "  on file: $existing_pubkey"
    echo "  local:   $DEV_PUBKEY"
    echo "  This usually means the local keypair was rotated. Revoke the"
    echo "  old enrollment first (set status=revoked), or pick a different"
    echo "  USER_HASH for this machine."
    exit 1
  fi
fi

# Fresh enrollment.
# NB: `developer_access` MUST be BOOL true — it is the publish gate. fold PR
# #444 (2026-06-01) retired the old bare-`status=active` allowlist: the dev
# cert now stamps a signed `authorized_publisher` flag (in dev = this grant),
# and schema_service requires it `true` to reserve a namespace. A row with
# only `status=active` mints a cert but `app publish`/`schema publish` 403s
# `not_authorized_publisher`. `status` is now just the revocation marker
# (`status=revoked` blocks the mint).
aws dynamodb put-item --region "$REGION" --table-name "$DEV_TBL" \
  --item "{\"user_hash\":{\"S\":\"$USER_HASH\"},\"dev_pubkey\":{\"S\":\"$DEV_PUBKEY\"},\"status\":{\"S\":\"active\"},\"developer_access\":{\"BOOL\":true},\"enrolled_at\":{\"S\":\"$NOW\"},\"enrolled_by\":{\"S\":\"$USER_HASH\"}}"

echo "enrolled $USER_HASH with dev_pubkey=$DEV_PUBKEY (status=active, developer_access=true)"
```

## Step 5 — verify the enrollment

```bash
# Verify the row landed.
aws dynamodb get-item --region "$REGION" --table-name "$DEV_TBL" \
  --key "{\"user_hash\":{\"S\":\"$USER_HASH\"}}" --query 'Item'

# Cross-check: can the local key mint a DevCert? (Smoke test against the
# exemem-dev cert endpoint, if reachable.)
# TODO once the /v1/dev-cert URL is settled; for now `folddb-dev app
# publish` is the live cert-minting path.
```

## Definition of done

- `~/.folddb-dev/developer/` holds an Ed25519 keypair.
- `/tmp/app-identity-dev-enroll/$ENV/$USER_HASH/EXEMEM_DEV_API_KEY` holds
  the freshly-minted plaintext key (0600 perms; one-shot capture).
- The dev's row in `ExememDevelopers-$ENV` has `status: active` with the
  local pubkey.
- The next `folddb-dev app publish` from this machine succeeds (no
  `not_a_developer` 403).

## After this skill — what's next

This skill stops at "developer is enrolled". The downstream steps live in
other places:

- `folddb-dev app new --id <id> --metadata-file app.json` — scaffold app
  metadata.
- `folddb-dev app publish --id <id> --schema-service-url <url>` — register
  the app namespace in schema_service. First-write-wins.
- `folddb-dev schema register --file <name>.json --app <id>` then
  `folddb-dev schema publish --schema <name> --app <id>
  --schema-service-url <url>` for each schema.

For an autonomous brain-specific end-to-end loop (this skill +
publish steps + verify), see the `app-identity-dogfood` skill.

## Memory hooks

If you save findings from a run, key them under
`projects/app-identity-dev-enroll-<env>-<user_hash>-<YYYY-MM-DD>` so a
later run for the same developer can avoid re-discovery. Don't memorize
the API key plaintext — it's at the 0600 path above; memory is wrong
storage for secrets.

## Out of scope

- Provisioning a prod EXEMEM_DEV_API_KEY (admin/portal).
- Writing the prod developers row (admin/portal).
- Anything beyond enrollment: app publish, schema publish, fold_db_node
  consent flow — those are downstream of this skill.
- Key rotation. v1: re-run with `--rotate-key`; the old pubkey row stays
  in the developers table at `status: active` until a human revokes it
  (today's process). v2: automated rotation flow with overlap window.
