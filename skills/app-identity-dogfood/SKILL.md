---
name: app-identity-dogfood
description: |
  Run the App Identity v3.1 app-creation flow end-to-end against the DEV
  environment, autonomously. Self-provisions a dev exemem API key + developer
  enrollment (DynamoDB, dev-only bypass), publishes the `fbrain` app namespace
  to the dev schema_service, registers + publishes fbrain's 8 schemas under
  `fbrain/*`, verifies namespacing via /v1/snapshot, and confirms fbrain can
  consume them — all on an EPHEMERAL folddb-dev node (never Tom's primary
  folddb_server brain). Files a Kanban task for every paper cut found.
  Use when asked to "dogfood app identity", "validate the app creation flow",
  "test schema registration + namespacing", or when the dogfood-fbrain routine
  fires.
allowed-tools:
  - Bash
  - Read
  - Edit
  - Write
  - Skill
triggers:
  - dogfood app identity
  - app identity dogfood
  - validate app creation flow
  - test schema registration namespacing
  - fbrain app creation
---

# App Identity dogfood (DEV, autonomous)

This skill exercises the full App Identity v3.1 app-creation flow against the
**dev** stack — the thing the `dogfood-fbrain` routine validates — and does it
without a human in the loop. Memory: [[project_app_identity]] (design + current
Lane-D state), [[project_fbrain]].

Team-facing runbook (the human-readable explanation of this flow + a per-run
log): `exemem-workspace/docs/dogfood/app-identity-dogfood-runbook.md`. This
skill is the canonical commands; that doc explains the *why* and records runs.
Append a row to its run log after each run.

## 🛑 Hard safety rules (read first)

1. **DEV ONLY.** Every endpoint, bucket, and table below is dev. NEVER target
   prod (`axo709qs11`, us-east-1, `*-prod`, `schema-service-prod-152335099025`).
   If any var resolves to a prod value, abort.
2. **Never touch the primary folddb_server brain.** That's Tom's live brain
   ([[feedback_dont_kill_primary_folddb_server]]), reached over the Unix socket
   `~/.folddb/data/folddb.sock`. This skill spins up its
   own **ephemeral** `folddb-dev start` session and stops it on the way out.
   Identify the primary brain by its socket
   (`lsof /Users/tomtang/.folddb/data/folddb.sock`) or process
   (`pgrep -fl folddb_server`) before/after — leave it exactly as you found it.
3. **Never run a local schema_service.** Always point at the deployed dev
   Lambda ([[feedback_no_local_schema_service]]).
4. **No destructive resets in this skill.** Registry/embeddings/Sled wipes are
   Tom-only and out of scope here — this skill *adds* the fbrain app + schemas
   idempotently; it does not reset. First-write-wins makes re-runs no-ops.
5. **Don't stash/reset shared worktrees** ([[feedback_no_stash_other_agents]]).

## Fixed dev coordinates (verified 2026-05-29)

| Thing | Value |
|---|---|
| dev schema_service | `https://y0q3m6vk75.execute-api.us-west-2.amazonaws.com` |
| dev exemem (dev-cert mint) | `https://ygyu7ritx8.execute-api.us-west-2.amazonaws.com` |
| dev region | `us-west-2` |
| AWS account | `152335099025` (local `aws` default = IAM user `tomtang-cli`, AdministratorAccess) |
| API-keys table | `ExememStack-dev-ApiKeysTable9F4DC7E7-ECJE82X9TR56` (PK `api_key_hash` = `sha256_hex(em_<key>)`, attr `user_hash`) |
| developers table | `ExememDevelopers-dev` (PK `user_hash`, attrs `dev_pubkey`,`status=active`,**`developer_access`(BOOL true)**,`enrolled_at`,`enrolled_by`) |
| `folddb-dev` binary | `~/code/edgevector/fold_dev_node/target/release/folddb-dev` (rebuild if stale: `cargo build --release -p ...` in `fold_dev_node`) |
| fbrain schemas | `~/code/edgevector/fbrain/src/schemas.ts` — `RECORD_TYPES` + `schemaFor(type)` (8: Concept,Task,Design,Preference,Reference,Agent,Project,Spike) |

**Names** — use a synthetic, removable dogfood identity so we never pollute
Tom's real exemem account:
- `USER_HASH="dogfood-appident"` (synthetic; carried in the DevCert as owner)
- `APP_ID="fbrain"` (the namespace under test)

## Trust chain (so you know why each step exists)

`Authorization: Bearer em_<key>` → `validate_api_key` hashes the key
(`sha256_hex`) and looks it up in the API-keys table → resolves a `user_hash` →
that `user_hash` must have a non-revoked row in `ExememDevelopers-dev` carrying
`developer_access=true` (the publish gate; fold PR #444 retired the old
bare-`status=active` allowlist) → exemem signs a **DevCert** (ES256, KMS root
key) stamping `authorized_publisher` = that grant → `folddb-dev` signs an
`app_register` / `schema_claim` envelope with the local Ed25519 dev key → posts
to schema_service, which verifies the DevCert offline against
`APP_IDENTITY_ROOT_PUBKEYS`, requires `authorized_publisher=true` to reserve the
namespace, and records `owner_app_id` into the identity hash so the canonical
name becomes `fbrain/<Schema>`.
(Source: `fold/exemem_service/lambdas/auth_service/src/dev_cert.rs`,
`fold/exemem_service/lambdas/exemem_common/src/api_key.rs`,
`fold_dev_node/crates/bin/src/cli/{app,schema}.rs`.)

## Step 0 — readiness gate (bail clean if the backend isn't app-identity-ready)

```bash
SS=https://y0q3m6vk75.execute-api.us-west-2.amazonaws.com
EX=https://ygyu7ritx8.execute-api.us-west-2.amazonaws.com
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

# Probe POST /v1/apps — NOT GET. The HTTP API mounts `POST /v1/apps` and
# `GET /v1/apps/{app_id}`; there is NO `GET /v1/apps` collection route, so a
# GET always 404s even on a healthy backend (false "blocked"). A live route
# replies 401/400/422 from the Lambda's own validation; only a 404 means the
# route isn't mounted at the gateway.
APPS=$(code -X POST "$SS/v1/apps" -H 'content-type: application/json' -d '{}')  # want NOT 404 (401/400/422 = ready)
DEVCERT=$(code -X POST "$EX/v1/dev-cert" -d '{}') # want 422 (live, validates body)
echo "apps=$APPS devcert=$DEVCERT"
```

- `apps == 404` → the app-identity build is **not deployed** to dev. This is the
  known deploy blocker (`AppIdentityRootPubkeyFetcher` CFN 4096-byte limit). Do
  **not** silently pass. Check whether a Kanban task already tracks it
  (`kanban task list --project-path ~/code/edgevector/schema-infra` — look for
  the `outputPaths` / `4096b` deploy-fix task). If none open, file one (see
  "Filing gaps"). Then **report blocked and stop** — the rest of the flow can't
  run. (Optional, only if explicitly asked to deploy: with the fix present in
  `schema-infra/fold` submodule, `cd schema-infra && GH_PAT="$(gh auth token)"
  ./deploy.sh dev --yes` — slow; never in an unattended routine without opt-in.)
- `devcert != 422/200` → exemem dev stack unhealthy; file a gap and stop.

## Step 1 — self-provision a dev exemem API key + developer enrollment (DEV bypass)

This is the dogfood bypass (same spirit as the `exemem-credentials` skill): we
write the rows `auth_service` expects directly into dev DynamoDB instead of the
web portal. **Dev tables only.** Idempotent.

```bash
REGION=us-west-2
API_TBL=ExememStack-dev-ApiKeysTable9F4DC7E7-ECJE82X9TR56
DEV_TBL=ExememDevelopers-dev
USER_HASH=dogfood-appident
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
NOW_EPOCH=$(date -u +%s)

# 1a. Mint an em_<48 hex> key, hash it, register it → user_hash.
# NB: `created_at` MUST be type N — it is the sort key of the table's
# `user_hash_index` GSI, and DynamoDB rejects a String there ("Type mismatch
# for Index Key created_at Expected: N"). `is_active` MUST be BOOL true —
# `exemem_common::api_key::validate_api_key` reads `is_active` with
# `unwrap_or(false)`, so a key without it authenticates as "deactivated" (401).
API_KEY="em_$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c48)"
KEY_HASH=$(printf '%s' "$API_KEY" | shasum -a 256 | cut -d' ' -f1)
aws dynamodb put-item --region "$REGION" --table-name "$API_TBL" \
  --item "{\"api_key_hash\":{\"S\":\"$KEY_HASH\"},\"user_hash\":{\"S\":\"$USER_HASH\"},\"created_at\":{\"N\":\"$NOW_EPOCH\"},\"is_active\":{\"BOOL\":true},\"label\":{\"S\":\"app-identity-dogfood\"}}"
export EXEMEM_DEV_API_KEY="$API_KEY"
echo "minted dev key (last6 …${API_KEY: -6}) → user_hash=$USER_HASH"
```

`dev_pubkey` for the enrollment comes from Step 2's `developer init` — so run
2a first, then enroll:

```bash
# 1b. After developer init prints the pubkey (DEV_PUBKEY), enroll it.
# NB: `developer_access` MUST be BOOL true. The dev-cert gate flipped (fold
# PR #444, 2026-06-01) from the old allowlist model (a bare `status=active`
# row was enough) to a **paid-plan-OR-developer_access** gate. auth_service
# now stamps a signed `authorized_publisher` flag onto the DevCert; in dev it
# equals `has_developer_access(user_hash)` (the `developer_access=true`
# attribute), and schema_service REQUIRES `authorized_publisher=true` to
# reserve an app namespace (dev↔prod parity). Without `developer_access=true`
# the cert mints fine but `app publish` 403s `not_authorized_publisher`.
# `status=active` is kept only as a non-revocation marker (an explicit
# `status="revoked"` row blocks the mint).
aws dynamodb put-item --region "$REGION" --table-name "$DEV_TBL" \
  --item "{\"user_hash\":{\"S\":\"$USER_HASH\"},\"dev_pubkey\":{\"S\":\"$DEV_PUBKEY\"},\"status\":{\"S\":\"active\"},\"developer_access\":{\"BOOL\":true},\"enrolled_at\":{\"S\":\"$NOW\"},\"enrolled_by\":{\"S\":\"$USER_HASH\"}}"

# Verify the grant took — the minted cert must carry authorized_publisher=true:
curl -s -X POST "$EX/v1/dev-cert" -H "Authorization: Bearer $EXEMEM_DEV_API_KEY" \
  -H 'content-type: application/json' -d "{\"dev_pubkey\":\"$DEV_PUBKEY\"}" \
  | jq '.cert.authorized_publisher'   # want: true
```

> If a put-item is rejected by a conditional guard on a re-run, that's the
> idempotency guard — treat as success and continue.

## Step 2 — developer identity + app scaffold (offline)

```bash
BIN=~/code/edgevector/fold_dev_node/target/release/folddb-dev
WORK=$(mktemp -d /tmp/appident-dogfood.XXXX); cd "$WORK"

# 2a. Developer keypair (Ed25519). Reuse the existing one if present.
"$BIN" developer init --handle app-identity-dogfood
DEV_PUBKEY=$("$BIN" developer init 2>/dev/null | awk -F': *' '/public key/{print $2}')
echo "DEV_PUBKEY=$DEV_PUBKEY"   # feed this into Step 1b

# 2b. App metadata + scaffold.
cat > fbrain.app.json <<'JSON'
{"display_name":"FBrain","description":"Local-first knowledge brain for EdgeVector.","homepage_url":"https://github.com/EdgeVector/fbrain"}
JSON
"$BIN" app new --id fbrain --metadata-file fbrain.app.json --out app.json --force
```

(Do Step 1b enrollment now that `DEV_PUBKEY` exists, then continue.)

## Step 3 — publish the `fbrain` app namespace to dev schema_service

```bash
"$BIN" app publish --id fbrain --app-file app.json \
  --schema-service-url "$SS" \
  --exemem-url "$EX" \
  --dev-api-key "$EXEMEM_DEV_API_KEY"
```

Expect `201` + `mirrored_envs` on first run, or "already registered"
(first-write-wins is immutable) on re-runs — both are PASS.

`401 cert_invalid` here is **most often a STALE `folddb-dev` binary**, not a
backend fault. The DevCert struct is shared across three serde'd surfaces
(auth_service minter ↔ schema_service verifier ↔ folddb-dev client); if the
local binary was built against a fold rev predating a signed-field addition
(e.g. `authorized_publisher`, fold PR #444), folddb-dev deserializes the cert
into its OLD struct, silently drops the field, re-serializes it into the
`X-Exemem-Dev-Cert` header via `header_b64(&cert)`, and schema_service's
required-field decode then fails → `cert_invalid`. Diagnose:
`strings $(command -v folddb-dev) | grep -c authorized_publisher` (0 = stale).
Confirm the backend is fine by replaying a full exemem-minted cert straight to
`POST /v1/apps` with a dummy `X-Signature` — a healthy backend returns
`envelope_invalid` (cert verified), not `cert_invalid`. Fix = bump
`fold_dev_node/Cargo.toml`'s fold pin to current `fold/main` + rebuild
(tracked by fold_dev_node task `3bff9` / PR #122). Only if those rule it out:
enrollment didn't take, or the backend lacks `APP_IDENTITY_ROOT_PUBKEYS`
(back to Step 0).

## Step 4 — register + publish the 8 schemas under `fbrain/*`

The real CLI is **two-phase**: `schema register --file <f> --app fbrain` onto a
**running** dev node, then `schema publish --schema <name> --app fbrain`. So:

```bash
# 4a. Emit the 8 schema JSONs from fbrain's source of truth.
mkdir -p "$WORK/schemas"
( cd ~/code/edgevector/fbrain && bun -e '
  import { RECORD_TYPES, schemaFor } from "./src/schemas";
  import { writeFileSync } from "fs";
  for (const t of RECORD_TYPES) {
    const req = schemaFor(t);                 // { schema, mutation_mappers }
    writeFileSync(process.env.WORK + "/schemas/" + req.schema.name + ".json",
                  JSON.stringify(req.schema, null, 2));
  }
  console.log("emitted", RECORD_TYPES.length, "schemas");
' )
# If `schema register --help` shows it wants the full AddSchemaRequest
# ({schema, mutation_mappers}) rather than the bare definition, emit `req`
# instead of `req.schema`. Check the help and adapt.

# 4b. Start an EPHEMERAL dev node (NOT the primary brain) wired to dev schema_service.
# Default --port 0 = OS-picked ephemeral port + its own session/socket, so this
# never collides with or touches the primary folddb_server brain.
# CAPTURE the session id and pin it on EVERY later subcommand (--session $SESS):
# other agents may start their own sessions concurrently, so "most-recent"
# default is unsafe, and a bare `stop` could kill the wrong session.
"$BIN" start --schema-service-url "$SS" --dev-api-key "$EXEMEM_DEV_API_KEY"
SESS=$("$BIN" list | awk '$NF=="alive"{id=$1} END{print id}')   # newest alive = ours
echo "my session: $SESS"

# 4c. Register then publish each schema, tagged --app fbrain.
# NB: `schema publish` is an app-OWNED outward write — it MUST get the exemem
# dev key (`--dev-api-key`, or EXEMEM_DEV_API_KEY exported in THIS shell) and
# `--exemem-url` so the dev node can mint the DevCert. Omitting the key 400s
# `missing_api_key`. Each Bash tool call is a fresh shell, so pass the flags
# explicitly rather than relying on a prior `export`.
for f in "$WORK"/schemas/*.json; do
  name=$(jq -r .name "$f")   # the schema's actual `name` (e.g. "Concept"),
                             # NOT the lowercase filename (concept.json)
  "$BIN" --session "$SESS" schema register --file "$f" --app fbrain
  "$BIN" --session "$SESS" schema publish --schema "$name" --app fbrain \
    --schema-service-url "$SS" --exemem-url "$EX" --dev-api-key "$EXEMEM_DEV_API_KEY"
done
```

Each schema JSON must carry non-empty `descriptive_name` + `purpose_statement` +
per-field `field_descriptions` or publish 400s `incomplete_schema` — fbrain's
schemas already satisfy this (the per-kind `purpose_statement` is what lets the
dual-signal gate keep the 6 same-shape Phase-6 kinds distinct).

## Step 5 — verify namespacing

```bash
# /v1/snapshot is X-API-Key gated. The minted exemem dev key from Step 1
# ($EXEMEM_DEV_API_KEY) works directly as the X-API-Key (verified 2026-05-30).
# Don't rely on a fbrain config key — it's usually absent on dev boxes (→ 401).
SKEY="$EXEMEM_DEV_API_KEY"
curl -s -H "X-API-Key: $SKEY" "$SS/v1/snapshot" > /tmp/snap.json
jq '{version, fbrain_app: (.apps[]?|select(.app_id=="fbrain")),
     fbrain_schemas: [.schemas[]|select(.owner_app_id=="fbrain")|{descriptive_name,name,owner_app_id}]}' /tmp/snap.json
# Decisive namespacing proof — same shape, different identity hash by owner:
jq '[.schemas[]|select(.descriptive_name=="Concept")|{hash:.name,owner:.owner_app_id}]' /tmp/snap.json
```

PASS criteria (NB on serialization: the snapshot's `.schemas[].name` is the
64-hex **identity_hash**, NOT a literal `fbrain/Concept` string — `fbrain/<X>`
is the CLI display form. Namespacing lives in the sibling `owner_app_id` field
+ the fact that owner is folded INTO the identity_hash. Don't grep for a
`fbrain/` name prefix — it won't appear):
- `apps[]` contains `fbrain` with the metadata from Step 2.
- The 8 schemas (`descriptive_name` Concept/Task/Design/Preference/Reference/
  Agent/Project/Spike) each carry `owner_app_id: "fbrain"`.
- The owner is in the hash: a same-shape `descriptive_name=="Concept"` schema
  with `owner_app_id==null` has a DIFFERENT `identity_hash` than fbrain's. If
  the owned and un-owned Concept shared a hash, the gate didn't apply.
- `version` advanced monotonically.

If `SKEY` is unavailable, verify instead via the running dev node's schema list
(`"$BIN" schema list` or its GET endpoint) — the canonical names appear there too.

## Step 6 — confirm fbrain can consume the namespaced schemas

The loop closes when **fbrain's own schema definitions resolve to the
`fbrain`-owned canonicals** that are live in the registry. The decisive,
read-only proof is the schema-identity round-trip you already ran in Step 4:
each `fbrain/src/schemas.ts` definition, emitted and `schema register --app
fbrain`'d, computes the SAME `identity_hash` that's published under
`owner_app_id=fbrain` (publish reports `outcome: already_present`), and those
hashes show as **`Available`** in the dev node's `schema list`:

```bash
# Each fbrain canonical is loaded + Available on the node, hash == published.
"$BIN" --session "$SESS" schema list | grep -E 'Concept|Task|Design|Preference|Reference|Agent|Project|Spike'
```

PASS = all 8 names appear `Available` with the identity hashes Step 4 reported,
and (Step 5) those same hashes carry `owner_app_id: fbrain` and differ from any
bare/un-owned same-shape schema. That agreement — schemas.ts → canonical hash →
owned + Available — is fbrain consuming the namespaced schemas.

> ⚠️ Do **not** try `fbrain init`/`doctor` against the `folddb-dev` node.
> `folddb-dev` speaks the `/dev/*` HTTP dialect; fbrain's client speaks the
> production `fold_db_node` `/api/*` dialect (`/api/system/auto-identity`,
> `/api/setup/bootstrap`, `/api/schemas/load`), which folddb-dev 404s on. So
> `fbrain init` cannot bootstrap against an ephemeral dev node — verify
> consumption via the hash round-trip above, not via fbrain's bootstrap.
>
> ⚠️ If you ever DO run an fbrain CLI command, the throwaway-config env var is
> **`FBRAIN_CONFIG`** (full path to a config.json), NOT `FBRAIN_CONFIG_DIR`
> (which fbrain ignores → it would read/write Tom's real `~/.fbrain/config.json`).
> And `doctor` takes no `--schema-service-url` flag.

## Step 7 — cleanup (always, even on failure)

```bash
"$BIN" --session "$SESS" stop   # stop OUR ephemeral session by id (never a bare
                                # `stop` — that targets most-recent, maybe another
                                # agent's). Do NOT run `clean` unattended: it can
                                # reap another agent's dead session/data dir.
lsof /Users/tomtang/.folddb/data/folddb.sock >/dev/null 2>&1 && echo "primary brain still up (good — left untouched)"
rm -rf "$WORK"
```

Leave the dogfood DynamoDB rows in place (idempotent, reused next run) — or, if
asked to leave no trace, delete the two items:
`aws dynamodb delete-item --region us-west-2 --table-name "$API_TBL" --key "{\"api_key_hash\":{\"S\":\"$KEY_HASH\"}}"`
and the `ExememDevelopers-dev` row keyed by `user_hash`. The local Ed25519 dev
key under `~/.folddb-dev/developer/` is fine to keep (reused next run).

## Filing gaps (paper cuts → Kanban)

For EACH failure or rough edge (deploy not ready, 401/400/incomplete_schema,
bare/un-namespaced canonical, fbrain can't resolve, CLI syntax drift, missing
DynamoDB attr, etc.):

1. Pick the right repo: schema-stack/deploy → `schema-infra`; CLI verbs / publish
   path → `fold` (fold_dev_node lives in the monorepo); fbrain consumption →
   `fbrain`; exemem dev-cert/tables → `exemem-infra`.
2. Create a started Kanban task via the `kanban` skill. Prompt MUST begin with
   "Follow the `kanban-agent` skill — manage your own process end-to-end from
   worktree to merge." Include: GOAL, ROOT CAUSE (with the exact error +
   file:line), STEPS, VERIFY, DEFINITION OF DONE, OUT OF SCOPE. Ground every
   claim in observed output — re-verify against current `origin/main`
   ([[feedback_verify_origin_main_before_drafting_tasks]]).
3. `kanban task start --task-id <id>` so it's in_progress.

Don't file Tom-only-by-design manual gates (prod reset, real-account
enrollment) as bugs — note them in the report instead.

## Output

End with a tight report: per-step PASS/FAIL, the canonical names observed, any
Kanban task IDs filed (with repo), and what (if anything) remains genuinely
Tom-only. If Step 0 gated you out, say so plainly and name the blocking task —
do not report success.

## Idempotency & re-runs

Every write is first-write-wins or guarded: re-running is safe and converges to
the same state. A clean re-run on a healthy dev backend should be all-PASS with
zero new Kanban tasks.
