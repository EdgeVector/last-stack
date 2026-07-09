---
name: app-identity-dogfood
description: |
  Run the App Identity app-creation flow end-to-end against the DEV
  environment, autonomously. Uses the consolidated `folddb` developer CLI,
  isolated persistent dogfood state, and the fbrain 9-schema knowledge-record
  set including Sop. Validates that `folddb login`, `folddb init`, and
  `folddb push` can publish the `fbrain` app namespace without touching Tom's
  primary LastDB brain or leaking secrets.
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

# App Identity Dogfood (DEV, Consolidated CLI)

This skill exercises the supported App Identity developer journey on the
deployed DEV stack:

1. `folddb login --env dev` establishes the developer identity and DevCert.
2. `folddb init fbrain` writes the local app manifest.
3. `folddb push --env dev` registers the app and publishes the fbrain schemas.
4. Snapshot/status checks prove the live registry has the owned fbrain schema
   set and the local manifest is in sync.

This file is the canonical runbook for commands. The older team-facing
`exemem-workspace/docs/dogfood/app-identity-dogfood-runbook.md` is historical
context and run log only until a separate docs PR refreshes it to point here.
When the two disagree, follow this skill.

Memory: `project_app_identity`, `project_fbrain`.

## Hard Safety Rules

1. DEV only. Every endpoint and credential must target the dev environment.
   Abort if anything resolves to prod.
2. Never use Tom's primary LastDB/F-Brain state. Do not read or write
   `$HOME/.lastdb`, `$HOME/.folddb`, `$HOME/.fbrain`, or the primary socket as
   part of this dogfood.
3. Use a dedicated persistent dogfood home, not a temp home, for the developer
   identity:
   `FOLDDB_HOME=$HOME/.last-stack/dogfood/app-identity/fbrain`.
   This is intentionally stable so reruns use the same owner key. Do not pass
   `folddb login --force` unless Tom explicitly asks for an owner rotation.
4. Keep secrets out of chat, Brain, Kanban, docs, logs, and PR bodies. If a run
   needs a raw API key, retrieve it from LastSecrets at the point of use and do
   not print it. Prefer an already-persisted key in the dedicated dogfood home
   or an invite path that stores the key into that home.
5. Do not run local registry services or destructive registry/data resets.
6. Do not stash, reset, clean, or otherwise modify shared worktrees.

## Fixed Dev Coordinates

| Thing | Value |
|---|---|
| dev schema service | `https://y0q3m6vk75.execute-api.us-west-2.amazonaws.com` |
| dev Exemem API | `https://ygyu7ritx8.execute-api.us-west-2.amazonaws.com` |
| dev region | `us-west-2` |
| dogfood app id | `fbrain` |
| dogfood handle | `app-identity-dogfood-fbrain` |
| dogfood home | `$HOME/.last-stack/dogfood/app-identity/fbrain` |
| fbrain schema source | `$HOME/code/edgevector/fbrain/src/schemas.ts` |
| fbrain pass set | Concept, Task, Design, Preference, Reference, Agent, Project, Spike, Sop |

The pass set is nine user-facing knowledge-record schemas. Include `Sop`.
Do not use the old eight-type list. `Decision` is intentionally outside this
dogfood pass while workspace guidance keeps decision writes disabled.

## Step 0 - Readiness Gate

Verify that the deployed dev routes are mounted before doing any writes:

```bash
SS=https://y0q3m6vk75.execute-api.us-west-2.amazonaws.com
EX=https://ygyu7ritx8.execute-api.us-west-2.amazonaws.com
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

APPS=$(code -X POST "$SS/v1/apps" -H 'content-type: application/json' -d '{}')
DEVCERT=$(code -X POST "$EX/v1/dev-cert" -H 'content-type: application/json' -d '{}')
echo "apps=$APPS devcert=$DEVCERT"
```

Expected:

- `apps` is not `404`. `401`, `400`, or `422` means the route reached the
  Lambda and validation fired.
- `devcert` is `422` or `200`.

If either route is not ready, stop and file or reference the existing Kanban
gap. Do not report a dogfood pass.

## Step 1 - Isolate Persistent Dogfood State

Set the CLI home before every `folddb` command. This home is persistent across
runs by design; it owns the `fbrain` app registration.

```bash
export FOLDDB_HOME="$HOME/.last-stack/dogfood/app-identity/fbrain"
export FOLDDB_DISABLE_KEYCHAIN=1
mkdir -p "$FOLDDB_HOME"

echo "dogfood home: $FOLDDB_HOME"
test "$FOLDDB_HOME" != "$HOME/.lastdb"
test "$FOLDDB_HOME" != "$HOME/.folddb"
test "$FOLDDB_HOME" != "$HOME/.fbrain"

for sock in "$HOME/.lastdb/data/folddb.sock" "$HOME/.folddb/data/folddb.sock"; do
  if [ -S "$sock" ]; then
    echo "primary socket observed and left untouched: $sock"
  fi
done
```

Do not use `mktemp` for `FOLDDB_HOME`; a temporary home creates a new developer
owner and can fail the registry's first-write-wins ownership model.

## Step 2 - Login

Use the consolidated CLI credential boundary:

```bash
folddb login --env dev --handle app-identity-dogfood-fbrain
```

If the dedicated home already has a developer key and persisted API key, this
refreshes the dev cert and keeps the same owner identity.

If the command reports a missing API key, use the approved credential path for
the run:

- With an invite code: `folddb login --env dev --handle app-identity-dogfood-fbrain --invite "$INVITE_CODE"`.
- With an API key from LastSecrets: retrieve it point-of-use, pass it with
  `--api-key`, and do not echo it.

Never mint an ad-hoc owner for convenience, and never rotate with `--force`
unless Tom explicitly asks for owner rotation.

## Step 3 - Scaffold the fbrain Manifest

Use a temporary project directory for the manifest and schema files. The project
can be temporary because the owner identity lives in the persistent dogfood
home.

```bash
WORK=$(mktemp -d /tmp/appident-dogfood.XXXXXX)
cd "$WORK"

folddb init fbrain --env dev --force
```

Edit `folddb.toml` so the metadata is publishable:

```toml
app_id = "fbrain"
schemas = ["schemas/*.json"]

[metadata]
display_name = "FBrain"
description = "Local-first knowledge brain for EdgeVector."
homepage_url = "https://github.com/EdgeVector/fbrain"
```

`folddb init` writes an example schema. Remove it after replacing the directory
with fbrain's real schemas.

## Step 4 - Emit the Current fbrain Schemas

Write one top-level schema JSON file per pass-set schema:

```bash
rm -rf "$WORK/schemas"
mkdir -p "$WORK/schemas"

( cd "$HOME/code/edgevector/fbrain" && WORK="$WORK" bun -e '
  import { RECORD_TYPES, schemaFor } from "./src/schemas.ts";
  import { writeFileSync } from "fs";

  const passSet = [
    "concept",
    "task",
    "design",
    "preference",
    "reference",
    "agent",
    "project",
    "spike",
    "sop",
  ];

  const seen = [];
  for (const type of RECORD_TYPES) {
    if (!passSet.includes(type)) continue;
    const req = schemaFor(type);
    const schema = req.schema;
    writeFileSync(`${process.env.WORK}/schemas/${schema.descriptive_name}.json`,
      JSON.stringify(schema, null, 2));
    seen.push(schema.descriptive_name);
  }

  if (seen.length !== 9 || !seen.includes("Sop")) {
    throw new Error(`expected 9 schemas including Sop, got ${seen.length}: ${seen.join(", ")}`);
  }
  console.log(`emitted ${seen.length} schemas: ${seen.join(", ")}`);
' )
```

Each schema must carry non-empty `descriptive_name`, `purpose_statement`, and
per-field `field_descriptions`; `folddb push` runs a client-side preflight and
fails before writing if those are missing.

## Step 5 - Push to Dev

Dry-run first, then publish:

```bash
folddb push --env dev --dir "$WORK" --dry-run
folddb push --env dev --dir "$WORK"
```

Expected outcomes:

- First run may register the app and publish schemas.
- Reruns may report the app/schemas already exist or are in sync.
- Both are pass outcomes as long as the owner is the stable dogfood identity
  from Step 1 and all nine pass-set schemas are represented.

## Step 6 - Verify Registry State

Check local-vs-live status:

```bash
folddb app status --env dev --dir "$WORK"
```

Then verify the registry snapshot. Use the dogfood API key only from the secure
store or LastSecrets; do not print it.

```bash
SKEY="$(lastsecrets get <approved-dogfood-api-key-slug>)"
curl -s -H "X-API-Key: $SKEY" "$SS/v1/snapshot" > "$WORK/snapshot.json"

jq -r '
  [.schemas[]
   | select(.owner_app_id == "fbrain")
   | .descriptive_name]
  | unique
  | .[]' "$WORK/snapshot.json"
```

PASS criteria:

- `folddb app status --env dev --dir "$WORK"` reports the app registered on dev
  and no schema drift for the manifest.
- Snapshot contains `fbrain` app metadata.
- Snapshot contains all nine `owner_app_id == "fbrain"` schemas:
  Concept, Task, Design, Preference, Reference, Agent, Project, Spike, Sop.
- The owned schema identity hashes are stable across reruns. A rerun must not
  create a second owner key or require reclaiming the app id.

Serialization note: snapshot `.schemas[].name` is the canonical identity hash,
not a literal `fbrain/Concept` string. Namespacing is proven by
`owner_app_id == "fbrain"` and the hash stability.

## Step 7 - Cleanup

```bash
rm -rf "$WORK"

for sock in "$HOME/.lastdb/data/folddb.sock" "$HOME/.folddb/data/folddb.sock"; do
  if [ -S "$sock" ]; then
    echo "primary socket still present and untouched: $sock"
  fi
done
```

Keep `$FOLDDB_HOME` and the dogfood developer identity. That state is the
idempotency anchor for future runs. Do not delete it unless Tom asks for a full
owner reset and accepts the registry consequences.

## Filing Gaps

For each failure or rough edge, file a focused Kanban card with:

- Repo and base branch.
- Observed command and exact error.
- Narrow goal and verification command.
- Out-of-scope guardrails.

Route failures this way:

| Symptom | Repo |
|---|---|
| deployed app registry route missing or unhealthy | `EdgeVector/schema-infra` |
| consolidated CLI behavior, manifest, login, init, push, status | `EdgeVector/fold` |
| fbrain schema source or schema count mismatch | `EdgeVector/fbrain` |
| Exemem dev credential or invite behavior | `EdgeVector/exemem-infra` |
| this dogfood recipe | `EdgeVector/last-stack` |

Do not file Tom-only manual gates as bugs; report them plainly.

## Output

End with a tight report:

- Step 0 readiness result.
- Dedicated `FOLDDB_HOME` used, with confirmation that primary sockets were not
  touched.
- `folddb login`, `folddb init`, `folddb push`, and `folddb app status` result.
- The nine schema names observed, including `Sop`.
- Any Kanban cards filed.
- Anything genuinely human-only.

A clean rerun on a healthy dev backend should be all-pass with zero new Kanban
cards and the same dogfood owner identity.
