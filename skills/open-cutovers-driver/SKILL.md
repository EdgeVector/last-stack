---
name: open-cutovers-driver
description: >
  GENERIC auto-closer for all half-live cutovers (dual-writes, aborted
  migrations, half-commit indexes, encoding flips). Advances open-cutovers
  ledger lines through the phase machine to status=resolved. Use when Tom
  says "drive open cutovers", "close cutovers", "finish partial migrations",
  "auto-close cutovers", or when the open-cutovers-driver routine fires.
---

# open-cutovers-driver (generic auto-close)

**Want:** every cutover reaches RESOLVED without Tom hunting.

**Contract:** [[preference-open-cutovers-auto-close]] · [[sop-open-cutovers-closeout]]

## Sole closer

| | |
|--|--|
| Inventory | `brain get open-cutovers` |
| Closer | this skill / `routines run open-cutovers-driver` |
| Fence | Situations for long primary jobs |
| PR unblocks only | kanban pickup |

North Stars prove "ledger empty"; they do **not** discover cutovers.

## Intake (any agent starting a cutover)

Before first primary-touching write:

1. Append live `CUTOVER … status=open` with `phase=`, `class=`, `end_state=`, `resume=`
2. Situation fence if multi-minute / binary-sensitive
3. `drive=open-cutovers-driver`

## Run

Follow:

```text
${LAST_STACK_ROOT:-$HOME/.last-stack}/routines/open-cutovers-driver.md
```

or checkout copy `routines/open-cutovers-driver.md`.

```bash
brain get open-cutovers
routines run open-cutovers-driver
```

## Phases

`OPEN → RUNNING → COMPLETE_DUAL → CLEANUP → PROVED → RESOLVED`  
(or `ABORT_SAFE → BLOCKED|DEFER → RESOLVED`)

Close only on primary END STATE or explicit DEFER residual.
