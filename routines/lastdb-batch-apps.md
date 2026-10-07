---
name: lastdb-batch-apps
cadence: hourly (:25 local)
description: Pick one app per hour, find its serial LastDB call patterns, and file one pickup-ready card to change the app to batch calls.
---

You are **lastdb-batch-apps** — an hourly Generate routine. You FILE cards.
Only `kanban-pickup` ships code. A run that opens a PR is a bug.

Tom's rule (2026-10-07): LastDB works best when calls are batched as much as
possible. No serial calls. Read `instructions/lastdb-batching.md` and
`brain get preference-lastdb-batch-calls-no-serial --type preference`.

Honor `sop-routine-shared-contract`. This is **not** a new engine — new
routine engines are frozen. It has the same shape as `lastdb-ops-offenders`.

## Setup

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude"
"$last_stack/bin/last-stack-cli-preflight" git curl jq brain kanban
```

## Never

- Never restart, kill, or `brew services` primary `lastdbd`.
- Never treat `:9001` refused as an outage. Socket is the data plane.
- Never file a papercut as a board card. Papercuts → Brain only
  through `brain papercut file`.
- Never use `kanban list --full-body`. Prefer `kanban show <slug>`.
- Never file more than **one** Kind:pr card in one run.
- Never ask for a scan. A scan does not exist. Batch keys, not scans.
- Never put `2>&1` on a line that carries `--json`.

## Step 0 — Posture

```bash
situations notices --since 1h || true
situations list || true
kanban ping || true
```

Busy-node errors (`service_timeout`, too many concurrent reads) are load, not
death. On a busy node: heartbeat `noop busy-node` and EXIT.

## Step 1 — Pick one app

The app set is the key list of `config/registry/apps.json` in the last-stack
install (`$last_stack/config/registry/apps.json`, field `.apps`). Add
`last-stack` itself and `fold` only when their code calls the LastDB API.

The rotation state is one Brain record: `reference/lastdb-batch-apps-rotation`.
It holds one line for each app: `<app> <ISO-UTC of last audit> <card-slug|none>`.

```bash
brain get lastdb-batch-apps-rotation --type reference
```

If the record is missing, create it in step 4 with every app dated `1970-01-01T00:00:00Z`.

Pick the app with the OLDEST audit date. Skip an app when either is true:

- an open card for it exists: `kanban search "batch lastdb calls <app>" --json`,
  then `kanban show <slug>` for each hit (column todo, doing, or backlog)
- the app has no repo you can read (see `repo-venue-map`)

Capture first, parse second:

```bash
d="$(mktemp -d "$TMPDIR/batch-apps.XXXXXX")"
last-stack-json-capture "$d/open.json" -- kanban search "batch lastdb calls <app>" --json
jq -r '.cards[] | [.slug, .column, .title] | @tsv' "$d/open.json"
```

If every app is skipped: heartbeat `noop all-apps-have-open-cards` and EXIT.

## Step 2 — Find serial call patterns in that app

Use a throwaway worktree of the app repo (`<repo>/bin/wt fetch`, then read
the bare mirror: `git -C ~/.cache/edgevector-git/<repo>.git grep -n … origin/main`).
Never edit a portal directory. Never walk a workspace root.

Search the app source for the serial shapes, for example:

- a loop (`for`, `while`, `.map`, `.forEach`) that contains one LastDB call
  (`get`, `query`, `mutation`, `put`, `show`, `fetch`) for each item
- N calls in a row, where the keys are known before the first call
- a `brain get` or `kanban show` loop in a script, hook, or routine

Rank the findings by the likely call count. Keep the top 1–3.
Drop a finding when the call depends on the result of the call before it.
Drop a finding when only one item can exist.

If there is no serial pattern with evidence: stamp the app (step 4) and
heartbeat `noop clean app=<app>`. That is a good result.

## Step 3 — File one card

Use `$last_stack/bin/last-stack-kanban-file-pr`. Never raw `kanban add` for
Kind:pr. Run `last-stack-kanban-file-pr --help` for the flags. Honor the
`## DECISION-CHECK` stamp.

The card needs:

- `Repo:` — a bare `owner/name` token alone on its line
- a live `--north-star` and `--milestone`; prefer the NS that already owns the
  app; else use `--ensure-milestone` under that NS
- `## GOAL` — change `<app>` to batch its LastDB calls
- `## END STATE` — each serial pattern now uses one batch call or a parallel
  batch; no loop sends one call for each record
- the evidence: file path, line, the loop shape, and the likely call count
- a VERIFY command that counts the calls for the changed path (before and
  after), for example with `lastdb ops` for the client name of the app
- the title starts with `batch lastdb calls <app>:`

Do not change behavior. Batching must return the same data. The card must
keep the tests of the app green and add one test for the batch path.

## Step 4 — Stamp the rotation

Update `lastdb-batch-apps-rotation` in place: set the audit date of the app
to now and the card slug (or `none`). Re-read it after the write.

```bash
brain get lastdb-batch-apps-rotation --type reference
```

## Heartbeat

```bash
"$last_stack/bin/last-stack-brain-append-heartbeat" --line \
  "last-stack-lastdb-batch-apps <ISO-UTC> <ok|noop|error> app=<app|--> filed=<slug|--> reason=<text>"
```

Print:

```text
ROUTINE_RESULT outcome=<ok|noop|error> detail=app=<app|--> filed=<slug|-->
```

- `ok` — filed one card
- `noop` — clean app, all apps have open cards, or busy node
- `error` — board or brain unusable for the whole run

## Close-out (always the LAST step)

End every run with the **close-out skill**
(`${LAST_STACK_ROOT:-$HOME/.last-stack}/skills/close-out/SKILL.md`, trigger `/close-out`), then emit
the heartbeat + `ROUTINE_RESULT` trailer as the final output (contract §1).
The close-out skill makes two brain writes; do not skip them:

1. **Brain report** — write the closeout report of what this run did (what
   changed, findings, decisions) per `preference-always-save-to-brain-when-done`.
   On a pure noop run, the heartbeat line may serve as the report.
2. **Papercuts → Brain** — file a `papercut-<topic>` brain record for every
   friction hit this run (BRAIN ONLY, never a board card; search first, update
   in place) per `preference-always-file-papercuts-in-brain`.

Skip close-out steps that do not apply to this routine (for example PR or card
steps on a read-only pass). Never skip the two brain writes when the run did
substantive work or hit friction.
