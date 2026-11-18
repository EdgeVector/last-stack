## This is LastDB. Here is how you use it.

LastDB is a local database that runs as the daemon `lastdbd`. Apps and agents
reach it over a unix socket. This guide was written against API 40. Older notes
about its API and CLI are stale.

The contract is `docs/app-api.md` in `EdgeVector/lastdb`, and
`lastdb_node/app-api.json` wins when the two differ. Before you rely on a
command, run `lastdb <command> --help`. `GET /api/version` on the owner socket
gives the API version and the extensions of the running node.

### The model

- One record per key. A key is a hash, or a hash plus a range.
- A read names a schema and a key, or a range under one hash.
- There is no scan and no filter on a field value. Do not design for one.
- A schema can declare named alternate keys that reach the same records.
- A file belongs to its record. It moves as a path, never as bytes.

### Sockets

| Socket | File | Serves |
|---|---|---|
| Owner | `~/.lastdb/data/folddb.sock` | The app API, plus databases, sharing, status, schemas, backup and admin |
| App | `~/.lastdb/data/apps.sock` | Only `/v1/read`, `/v1/write` and `/v1/x/<name>`, to an installed app |

- On the owner socket, send `X-LastDB-Client: <your name>` so `lastdb ops` can name you.
- On the app socket, send `X-LastDB-App: <app id>`. The node serves the app only the schemas and extensions it declared.
- There is no TCP port. A refused TCP connection is not an outage.

### Read: `POST /v1/read`

```
{ "reads": [
    { "schema": "notes/Note", "key": { "hash": "n1" } },
    { "schema": "notes/Tag",  "range": { "hash": "work" }, "limit": 100, "keys_only": true },
    { "schema": "notes/Note", "via": "by_author", "range": { "hash": "tom" } },
    { "schema": "notes/Note", "keys_only": true, "limit": 100 },
    { "database": "work", "schema": "notes/Note", "key": { "hash": "n1" } }
] }
```

- One list holds at most 64 reads. Each read gets its own result or its own error, in order.
- `key` is one record. `range` is the records under one hash: all of them, those with a `prefix`, or those from `start` to `end` (send both together).
- `via` reads through a named alternate key.
- `limit` bounds a page. Send `next_cursor` back as `cursor` until it is null.
- `keys_only` returns keys without records. With no `key` and no `range` it pages every primary key of the schema (100 per page, at most 1000).
- Each record comes back with its `revision`. Keep it for the next write.
- `database` selects a named database by id or name. Without it, the read uses the personal database.

### Write: `POST /v1/write`

```
{ "mutations": [
    { "schema": "notes/Note", "op": "create",  "key": { "hash": "n4" }, "record": { } },
    { "schema": "notes/Note", "op": "replace", "key": { "hash": "n1" }, "revision": "9c2e", "record": { },
      "alternates": { "by_author": { "hash": "tom", "range": "n1" } } },
    { "schema": "notes/Tag",  "op": "delete",  "key": { "hash": "work", "range": "2026-11-16" }, "revision": "41ab" }
] }
```

- Every write carries a condition. `create` writes only when no record holds the key. `replace` and `delete` act only when the record is still at the `revision` you read.
- `replace` carries the complete record.
- A schema with alternate keys takes their addresses in `alternates` on every `create` and `replace`.
- The list is all or nothing, and every mutation in it names the same database.
- The reply comes after the write is on disk. It holds `revisions`, the new revision of each record in order.
- A failed condition refuses the whole list with `409 conflict`, plus `index` and `reason` (`exists`, `absent` or `revision`). Read the record again and decide. Do not retry blindly.
- A received (shared) database is read only on this route.

### Files

- A `create` or a `replace` can carry `"file": { "path", "name", "media_type" }`. LastDB keeps a reference and makes no copy, so the file must stay where it is.
- On a `replace`, no `file` key keeps the record's file and `"file": null` clears it.
- Every record in a read reply has `file`: null, or `name`, `media_type`, `size` and `local`.
- A read item with `"file": true` also returns `path`. On the owner socket, name an existing private directory in `file_dir` to get a copy of a file that LastDB holds as its own bytes.
- A path inside the LastDB home is refused.

### Extensions: `POST /v1/x/<name>`

- `changes`: one numbered list of changed record keys for each database. Send `{ "after": N, "limit": 500, "schemas": [...] }`. Save `through` as your position. When `id` differs from the one you saved, or `gap` is true, rebuild from `keys_only` pages. An entry holds no record values; read the records through `/v1/read`.
- `databases`: list and create named databases, place a schema in one (`declare_schema`), and use a whole-database share (`share_config`, `invite`, `accept`, `submit`).

### Errors

A refusal is an HTTP status and `{ "error": { "code", "message" } }`.

| Status | Code |
|---|---|
| 400 | `invalid_request` |
| 403 | `permission_denied` |
| 404 | `not_found` |
| 409 | `conflict` |
| 413 | `too_large` |
| 503 | `busy` |
| 500, 507 | `internal` |

Branch on the code. The message is for people and can change. `busy` means the
node is loaded, not down: retry a read, and retry a write only when it is safe
to repeat.

### Batch your calls

- Collect all keys first, then send one read list.
- Collect all writes first, then send one write list.
- Send independent calls in parallel.
- Do not write a loop that sends one call for each record. Each call pays a fixed cost for the socket, the queue and the disk write.

### The CLI

```
lastdb status [--json]                 # is the daemon up, build, uptime, cloud sync
lastdb ops [--by-count] [--json]       # completed requests by caller and by schema
lastdb get <SCHEMA> --key-hash H [--key-range R] [--json] [--hydrate <existing dir>]
lastdb get-keys <SCHEMA> [--key-hash H] [--limit N] [--cursor C] [--json]
lastdb mutate --request-file <file>    # one conditional record write; - reads stdin
lastdb db list | db create <NAME>      # named databases; lastdb --db <id or name> <command>
lastdb app list | install | upgrade | status | rollback | run | publish
lastdb share ...   lastdb backup ...   lastdb cloud ...   lastdb admin ...
```

- These commands do not exist any more: `lastdb schema`, `lastdb backup status`, `lastdb backup policy`, `lastdb ops --by-app`. Read a schema with `GET /api/schema/<name>` on the owner socket.
- `lastdb mutate` takes a mutation document: `{ "type": "mutation", "schema", "record", "key_value": { "hash", "range" }, "alternates", "mutation_type": "create", "expected": { "type": "absent" } }`. A replace uses `"expected": { "type": "revision", "revision": "<revision you read>" }`. To link a file, wrap it as `{ "mutation": { ... }, "file": { "source": "<path relative to the request file>" } }`.
- For more than a few records, send one `/v1/read` or `/v1/write` list instead of several CLI calls.
- Write `--json` output to a file, then parse the file. Do not merge stderr into it.

### Local development

Local development uses the owner socket. It needs no app id, no grant, no app
registry listing and no Schema Service registration.

1. Start `lastdbd` on a throwaway home with generated data. Do not develop against a home that holds real data.
2. Place each schema with `POST /api/apps/declare-schema` on the owner socket: `{ "app_id": "<app>", "schema": { ... } }`.
3. Read and write with `/v1/read` and `/v1/write`.

A program you start by hand is not restricted. Only an app installed from the
registry is.

### Publish and install an app

- The manifest states the access the app asks for: `"access": { "read": [...], "write": [...], "extensions": [...] }`. Use `"*"` only when the app cannot name its schemas in advance. Declaring is the permission.
- `lastdb app publish --manifest lastdb-app.json --env dev --channel next` lists the app. The running node must already hold the schemas, because publish reads their definition ids from it. `--prepare` produces the declaration and publishes nothing.
- `lastdb app install <app>` places the declared schemas and registers the app's grant. An installed app starts through the launcher, which sets `LASTDB_SOCKET_PATH` to the app socket, `LASTDB_APP` to the app id and `LASTDB_APP_DATA` to the app's data folder.
- When an app's calls answer `the app socket needs a registered app`, run `lastdb app install <app>` or `lastdb app upgrade <app>` again.
- An installed app must not call an `/api` route. The app socket answers `not_found` for them.

### Care of a running node

- The health check is `lastdb status`. When the node is slow, run `lastdb ops` and name the caller before you guess.
- Do not stop, restart or upgrade a `lastdbd` that you did not start.
- Do not copy a home that holds real data, and do not run a second node on such a copy.
- A timeout or `busy` is load. It is not a reason to restart anything.
