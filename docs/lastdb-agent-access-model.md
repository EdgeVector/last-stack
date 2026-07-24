# LastDB access model for agents

**Won't-undo:** treat LastDB as **Dynamo-style NoSQL with access-pattern design**, not SQL and not “mystery novel storage.”

| Durable homes | |
|---|---|
| This file (Last Stack install) | `~/.last-stack/docs/lastdb-agent-access-model.md` (this file in the last-stack tree) |
| Brain (personal node, if seeded) | `brain get concepts-lastdb-agent-access-model` |
| Public site | https://thelastdb.com/docs/agent-access-model · https://thelastdb.com/llms.txt |
| Deep internals (schema→molecules→atoms, ENC) | https://thelastdb.com/docs/agent-access-model#storage-depth (summary) · product repo docs |

**Portable brief** for any LastDB / Last Stack install (not EdgeVector-private).

**Audience:** every agent that reads or writes LastDB Mini (`lastdbd` on `~/.lastdb/data/folddb.sock`), fkanban/kanban, brain/fbrain, lastgit metadata, situations, etc.

---

## 1. One-sentence model

**Design for the query you need.** Primary data is keyed one way (e.g. card by slug). Other queries (list by board/column) use a **second schema** that is **dual-written** as a thin projection — same idea as DynamoDB base table + GSI / second table, except **the app maintains the secondary path**.

This is intentional NoSQL. It is not “almost SQL.” Do not invent field-equality filters, JOINs, or full-table scans as the default.

---

## 2. Dynamo map (use this vocabulary)

| Dynamo | LastDB / fold_db |
|--------|------------------|
| Table | Schema (`DeclarativeSchemaDefinition`) |
| Partition key | HashKey (or HashRange **hash** component) |
| Sort key | RangeKey (HashRange **range** component) |
| Item attributes | Fields (assembled at query time from tips + atoms) |
| `GetItem` / `Query` on PK | `filter: { HashKey: "…" }` |
| Query PK + SK prefix | `HashRangePrefix` / range scans under a hash |
| GSI / second table for another access pattern | **Second schema**, dual-written by the app |
| `Scan` | Full scan — **last resort**, admin/seed only |
| LSI/GSI dual-write (platform) | **App dual-write** (e.g. fkanban `upsertBoardCard`) |

If you already know Dynamo access-pattern design, you already know 80% of how to use this database.

---

## 3. How a “record” is stored (just enough)

You do **not** need the full engine lecture for day-to-day CRUD. Minimum:

1. **Schema** — names fields and keying mode (`Single` | `Hash` | `Range` | `HashRange`). Catalog, not the row store.
2. **Field** — each field has its own **molecule** (tip index): “for this key, which atom is current?”
3. **Atom** — immutable, content-addressed field value (`atom:{uuid}`).
4. **Query** — resolve tips for the keys you care about, batch-fetch atoms, zip fields into the JSON the API returns.

Multi-field “rows” (a Card with title+body+column) are **co-keyed at read time**, not one physical row blob.

Deeper: open `docs/lastdb-storage-schema-to-atoms.html` (encryption layers, `mk:` keys, ENC).

---

## 4. Access patterns — do / don't

### Do

| Intent | How |
|--------|-----|
| Load one card / brain record by slug | **HashKey** on the primary schema (`Card`, Concept, …) via CLI `show` / `get` or query with `HashKey` |
| List a board / column | Use the **board-scoped secondary** (BoardCards): partition hash = board, optional range prefix = `column#` — via `kanban list` / `list --column`, never “scan all cards and filter” |
| Point update | Mutate **primary** fields; let the product CLI dual-write secondaries (prefer `kanban` / `fkanban` / `brain` over raw multi-schema surgery) |
| Health / load | `lastdb status` + socket `/api/status` request_ops (CLI may lag daemon kinds); playbook `sop-lastdb-request-ops-telemetry` |

### Don't

| Anti-pattern | Why |
|--------------|-----|
| Full scan as list | O(all data); historical node meltdowns |
| Field-equality filter like `{ column: "todo" }` as if SQL WHERE | Node HashRangeFilter is key-shaped only; fake filters 400 or force client fallbacks |
| N+1 point-get every slug after a bad list | Same class of load storms |
| “Fix” empty list by bulk re-upserting secondaries while primary HashKey is broken | Destructive dual-write/heal thrash |
| Restart primary for `:9001` / busy errors | Socket is the plane; TCP is retired; busy ≠ dead |
| Upgrade lastdbd by pointing a new binary at live `~/.lastdb` first | `lastdb-safe-upgrade` only |

---

## 5. Primary vs secondary (dual-write)

### Primary

- **Source of truth** for the entity (e.g. Card by slug, including body).
- Access: HashKey(slug) / show / get.

### Secondary index (here)

- A **second schema** laid out for a **different query** (e.g. BoardCards: hash=board, range=`column#pos#slug`).
- Usually a **thin projection** (titles, columns, positions — **not** full body).
- **Dual-written:** on every logical create/move/update of the primary, the app **also** updates the secondary (put new tip keys, delete old sort keys, purge orphans).

### Important: not “shared molecule pointers”

Atoms/molecules are addressable, so **in theory** a new schema could only store pointers into existing molecules. **That is not how fkanban BoardCards works today.**

BoardCards is a **denormalized projection**: separate schema, separate molecules/tips, separate atoms for the thin fields (app dual-write). Same idea as a Dynamo GSI projection the app maintains, not a free zero-copy alias of Card atoms.

Implications:

- **Write amplification** is expected.
- **Drift** (list ≠ show) is a real failure mode.
- **Heal** tools re-sync secondary from primary **truth**. Only run heals when primary point-reads are healthy.
- Primary remains truth; secondary is disposable structure for list queries.

---

## 6. Product map (EdgeVector daily driver)

| Product | Primary access | Secondary / notes |
|---------|----------------|-------------------|
| **fkanban / kanban** | Card HashKey(slug) | **BoardCards** HashRange(board, `col#pos#slug`); CardListIndex; prefer CLI over inventing raw queries |
| **brain / fbrain** | Concept (etc.) by slug / type | Search/ask need app capability; after restart may need consent once — never grant from unattended routines |
| **lastgit** | Repo / CR / policy schemas | Chatty CR polling is normal; cheap queries ≠ “node on fire” by themselves |
| **situations** | Situation/index schemas | Preflight before mutating shared systems |

Socket: `~/.lastdb/data/folddb.sock`. Use installed CLIs from `~/.local/bin` (host-track), not random WIP checkouts.

Config hashes for fkanban live in `~/.fkanban/config.json` (`schemaHashes.card`, `board_cards`, …).

---

## 7. Encryption (agent-relevant only)

- Values may appear as `ENC:…` at rest (store seam and/or atom **content** seal).
- Readers must **open/decrypt before JSON parse**. Seeing `Failed to deserialize … expected value at line 1 column 1` on a catalog key often means ciphertext (or failed open) hit `serde_json`, not “schema JSON is garbage.”
- Optional: HashKey blinding / Range OPE via env — default homes are often **plain** key segments.
- Details: `docs/lastdb-storage-schema-to-atoms.html`.

---

## 8. Agent checklist (copy into plans)

```text
[ ] Access pattern named (point / board-list / search) — not “SELECT *”
[ ] Using primary HashKey for single-entity truth
[ ] Using product secondary (BoardCards / CLI list) for board list — not full scan
[ ] Mutations go through product CLI when dual-write is required
[ ] No bulk secondary heal while primary reads fail
[ ] Socket health: kanban list / targeted brain get — not brain doctor / :9001
[ ] Load: lastdb status / ops (or /api/status request_ops) before blaming “node down”
[ ] Secrets: LastSecrets only — never put secrets in brain/kanban bodies
```

---

## 9. Related records / docs

| What | Where |
|------|--------|
| This concept (brain) | `concepts-lastdb-agent-access-model` |
| Last Stack source | `docs/lastdb-agent-access-model.md` in the last-stack repo |
| Public docs | https://thelastdb.com/docs/agent-access-model |
| Ops telemetry | `sop-lastdb-request-ops-telemetry` |
| Safe Mini upgrade | `sop-lastdb-safe-upgrade` / skill `lastdb-safe-upgrade` |
| Repo / workspace map | `concepts-edgevector-repo-layout` |

---

## 10. Framing for humans and agents

> LastDB is **Dynamo-shaped NoSQL**. Design for access patterns. Primary key = one query shape. Secondary schemas dual-written by apps for other shapes. Scan is an emergency. Field/molecule/atom is how values are stored under the hood; day-to-day you think **table + PK/SK + optional projection table**.

That framing is accurate and lower cognitive load than “it’s not SQL so everything is novel.” The novel parts are **app-owned dual-write**, **field-assembled items**, and **layered ENC** — not the idea of partition/sort keys.
