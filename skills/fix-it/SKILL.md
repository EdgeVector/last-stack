---
name: fix-it
description: |
  Find and land the permanent fix for a defect, papercut, failing signal, or
  leftover temporary repair. A permanent fix is a producer-side change that
  makes the whole class unable to recur, with residue removed and the original
  live signal rechecked. Use when the user says "what's the permanent fix",
  "fix it properly", "don't bandage this", "stop treating the symptom",
  "/fix-it", "make this stay fixed", or when an agent would otherwise add a
  retry, special case, downstream check, docs-only patch, or file a papercut
  and walk away.
allowed-tools:
  - Bash
  - Read
  - Grep
  - Edit
  - Write
triggers:
  - what's the permanent fix
  - what is the permanent fix
  - fix it properly
  - don't bandage
  - stop treating the symptom
  - make this stay fixed
---

# fix-it — land the permanent fix

The question this skill answers: **where does the bad output get made, and
what change there makes the whole class unable to recur?**

Do not wrap the symptom. Do not add a special case. Do not write a check
that only catches this instance. Do not file a papercut and stop.

## Permanent fix (all four must hold)

A change is a permanent fix only if:

1. **Producer.** The place that *makes* the bad output can no longer make it.
2. **Class.** A sibling instance of the same class is already covered. No new
   enumerated special case is required for the next cousin.
3. **Residue.** Every temporary repair, retry wrapper, downstream-only check,
   and leftover comment-as-fix for this class is gone from the tree you ship.
4. **Live signal.** The original failing observation, in the original
   environment, cannot recur. Prove it with a negative test *and* a live
   recheck of that signal. Green CI on a fixture is not enough.

If any predicate fails, you have a temporary repair. Say so. Do not present
it as the fix.

## Not this skill

| Request | Owner |
|---|---|
| Factory pickup/merge stall class A–E | `why-shipping-stopped` |
| LastDB node wedged/slow | `brain-doctor` |
| Explain current state | `eli5` |
| Drive a card to merged | `kanban-agent` |
| Cluster papercuts into cards | `papercut-reconciler` (never file a papercut kanban card here) |

This skill *diagnoses and specifies* the permanent fix, presents the
**final state**, and lands the change when the user asked for the fix (not
only the diagnosis). Merge mechanics stay with `kanban-agent`.

## Bleed-stop is allowed. It is not the deliverable.

If the live system is losing data or serving wrong answers *right now*, you
may apply a labeled temporary repair to stop the bleeding. Stamp it:

- `TEMPORARY:` what it does
- `EXPIRES:` when it must come out
- the permanent-fix work that replaces it (card or this same turn)

The session is not done until the four predicates hold, or a pickup-ready
card exists that will make them hold.

## Procedure

### 1. Ground the symptom

Do not diagnose from memory. In this turn, collect:

- The exact live signal (command, log line, failing check, user-visible
  wrong answer).
- When it last happened.
- The previous temporary repairs (git history, papercuts, skill/docs
  patches). Use `brain ask` then `brain get <slug>`; `kanban show <slug>`.
  Do not run `brain list` as a census.

State the target in one line: "I am fixing \<signal\> in \<env\>."

### 2. Name the class, not the instance

Write one sentence: "This is the class of \<X\>, of which this instance is
\<Y\>."

Generalize along a predictable dimension (all delimited files, not `.csv`;
all harness skill links, not `diagram`). Do not over-generalize.

The class-coverage test: if the next cousin appeared tomorrow, would
today's change already cover it? If no, you are minting a special case.

### 3. Find the producer

Ask: **where is the bad output made?** Not where it is noticed.

| Layer | Question |
|---|---|
| Producer | The function/CLI/prompt/schema that *emits* the wrong fact |
| Consumer | The caller that sees it and currently papers over it |
| Detector | A check added after the fact |

The permanent fix lives at the producer. Consumer wrappers and detectors
are residue unless the producer is third-party and you cannot change it —
in that case the producer-of-record is *your* adapter that accepted the
bad contract; fix the adapter's contract, not every caller.

### 4. Reject anti-fixes

Refuse these as "the fix" (they may be bleed-stops only):

| Anti-fix | Why it fails |
|---|---|
| Retry / sleep / "try again" around a flaky producer | The producer still fails; the class still exists |
| Downstream check that catches this one instance | Next cousin bypasses it |
| Hard-coded special case that must be listed everywhere | Enumeration is not a mechanism |
| Docs, comments, or skill text as the only change | The producer still emits the bad output |
| File a papercut and walk away | A mention is not a filing, and a filing is not a fix |
| Mark preexisting failure "out of scope" / "same as main" | The live signal remains |
| Restart a daemon because an error named a port | Load/lock ≠ down |
| Close a papercut by burying extra findings in it | Other claims become invisible |

### 5. Design the producer-side class fix

One mechanism. State:

- What the producer will do instead (the **final state**).
- Why a sibling is already covered.
- What residue comes out.
- The exact VERIFY: original live signal + negative case.

If this needs product judgment you cannot make, stop. Present the final
state options. Do not land a guess.

### 6. Remove residue

Delete the temporary repair in the same change that lands the producer
fix. A leftover wrapper is proof the fix is not permanent.

If a kanban card has `## LEGACY RESIDUE`, honor that gate
(`last-stack-legacy-residue-probe`) before calling the work done.

### 7. Prove it

- Negative test: the class cannot be produced the old way.
- Live recheck of the original signal in the original environment
  (see kanban-agent "Live symptom recheck"). Fixture-only is not enough.
- If you cannot recheck live this turn, the work is not done. Leave it
  open with `PROOF: pending live recheck of <signal> on <env>`.

### 8. Present the final state (mandatory)

Lead with what is true after the fix. Then the problem. Then the path.
Use this shape every time:

```
## Final state
<one paragraph: what the system does now, at the producer>

## Class
<one sentence>

## Producer
<path or component that owns the fact>

## Rejected anti-fixes
- <thing we did not do, and why>

## Permanent fix
<the mechanism>

## Residue removed
<what came out, or "none — first repair">

## Proof
- Negative: <test>
- Live signal: <command + result in original env>

## Recurrence test
<the cousin that is already covered>
```

## Land it

Diagnosis-only if the user asked "what's the permanent fix" and stopped
there: present the report, do not open a PR unless they asked to land it.

If they asked to fix it (or this skill was invoked to land):

1. Work in an isolated git worktree, never a shared checkout.
2. Follow **kanban-agent** to open and merge the PR/CR. Do not invent a
   second merge loop.
3. File brain papercuts for friction you hit (`brain papercut file`).
   Never file a papercut kanban card. Search first; append evidence to a
   live record instead of minting a near-duplicate.
4. Close-out: full brain report of what was done.

If the change is larger than one atomic PR, land the producer-side slice
that makes the live signal unable to recur, and file follow-up cards for
remaining residue — with `kanban dep add` so pickup cannot grab them
out of order.

## Guardrails

- Do not restart a LastDB node you did not start.
- Do not treat `service_timeout` / "too many concurrent reads" as down.
- Do not use `brain list` as a census; point-get.
- Do not chain `sleep` to wait.
- Do not skip the live original signal.
