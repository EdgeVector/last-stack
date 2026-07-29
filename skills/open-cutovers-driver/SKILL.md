---
name: open-cutovers-driver
description: >
  Drive every live open-cutovers ledger line toward END STATE (ops resume,
  promote cleanup cards, close resolved lines). Use when Tom says "drive open
  cutovers", "finish partial migrations", "drain open-cutovers", or when the
  scheduled open-cutovers-driver routine fires. Reconcile/ops role — not a
  free-form product builder.
---

# open-cutovers-driver

Drive half-live system state to done. Inventory is Brain
`open-cutovers`; this skill is the agent playbook (same contract as
`routines/open-cutovers-driver.md`).

## When to use

- "Drive the open cutovers" / "finish the partial migrations"
- Morning: non-empty open-cutovers and Tom wants progress, not just a report
- Scheduled routine wake

## Contract (won't-undo)

1. **Only** advance lines from `brain get open-cutovers` with `status=open`.
2. **One step per cutover per pass** (cap 3).
3. **Close only on primary END STATE**, not PR merge.
4. Situation fence for long primary jobs
   ([[preference-primary-long-job-situation-fence]]).
5. No empty Kind:pr shells; no primary restarts; no safe-upgrade through mid
   dual-write without fence + preflight.

## Run

Follow the full procedure in:

```text
${LAST_STACK_ROOT:-$HOME/.last-stack}/routines/open-cutovers-driver.md
```

Or the copy in this last-stack checkout: `routines/open-cutovers-driver.md`.

Quick path:

```bash
brain get open-cutovers --type reference
# then per live CUTOVER: resume ops / promote card / re-measure / resolve
```

## Related

- Ledger: `brain get open-cutovers`
- NS: `north-star-open-cutovers-drained`
- Morning digest surfaces live lines only (does not advance them)
