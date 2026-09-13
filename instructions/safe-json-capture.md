## Capture `--json` output BEFORE you parse it (the hook denies a merged stream)

Do not merge stderr into a `--json` stream that `jq` (or `last-stack-json-get`,
or `last-stack-forge-json-jq`) reads. The PreToolUse hook
`unsafe-inline-json.sh` denies both shapes:

```bash
<cmd> --json 2>&1 | jq .            # DENIED — merged stream goes to a parser
<cmd> --json 2>&1 > out.json        # DENIED — a later `jq out.json` reads it
<cmd> --json > out.json 2>&1        # DENIED — same file, same poison
```

### Why (measured 2026-09-07)

The daily self-improvement pass counted **135 denials in 118 distinct Claude
sessions in 24 hours** — 21% of all sessions in the window. `situations` caused
67, `kanban` 42, `routines` 13. The agents wanted the error text, so they added
`2>&1`, and the guard stopped them one step later. The guard is correct. The
prevention was missing: no document taught the safe form, so each agent learned
it only after a denial.

### Second measurement (2026-09-13): the shape moved to `kanban show`

Six days later the same hook denied **74 commands in 70 distinct sessions in
24 hours**. All of them were scheduled routines (milestone-driver 20,
kanban-watch 10, groom-board 7, pipeline-health 7, routine-fleet-health 6).
The dominant shape was no longer `situations list`; it was a point read:

```bash
kanban show <slug> --json 2>&1 | jq -r '.body'                 # DENIED
kanban milestone detail <slug> --json 2>&1 | jq '.milestone'   # DENIED
```

The rule is the same for EVERY `--json` command, not only the first one in a
session. Never write `2>&1` on a line that carries `--json`.

### The safe form

Use `last-stack-json-capture`. It writes stdout to the file, stderr to
`<file>.err`, reports whether the capture parsed, and exits with the command's
status. You keep the error text AND the parser gets clean JSON.

```bash
last-stack-json-capture /tmp/sit.json -- situations list --json
jq -r '.[] | "\(.slug) \(.status) \(.severity)"' /tmp/sit.json
cat /tmp/sit.json.err        # the stderr you wanted, on its own
```

The helper is on `~/.local/bin`. A sandbox shell can lose `$PATH`; name the
install path when it does:

```bash
"$HOME/.last-stack/bin/last-stack-json-capture" /tmp/board.json -- kanban list --column todo --json
jq -r '.total, .truncated' /tmp/board.json
last-stack-json-capture /tmp/card.json -- kanban show <slug> --json
jq -r '.body' /tmp/card.json
```

For one field over a socket or an API, pipe to `last-stack-json-get` instead:

```bash
curl -s --unix-socket "$HOME/.lastdb/data/folddb.sock" http://localhost/api/status \
  | "$HOME/.last-stack/bin/last-stack-json-get" .status.uptime_s
```

### Plain redirection also works

`2>` sends stderr somewhere else. Only `2>&1` merges it.

```bash
situations list --json > /tmp/sit.json 2>/tmp/sit.err
jq -r '.[].slug' /tmp/sit.json
```

### The escape hatch

A merge is sometimes correct — a command that prints JSON on stderr by design.
State the reason on the line:

```bash
<cmd> --json 2>&1 | jq .   # json-guard-ok: <why the merge is correct>
```

Do not use the hatch to silence a denial you did not read.
