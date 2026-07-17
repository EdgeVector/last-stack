---
name: sec-review-later
description: >-
  Run the deferred security review of code that landed on fold's main flagged
  `[sec-review-later]`. Discovers the backlog, groups it into sprint buckets,
  fans out one adversarial security-reviewer agent per attack-surface dimension
  (the hand-authored "you are a senior security reviewer auditing the X sprint"
  fan-out, codified), dedupes + adversarially verifies findings, files an
  kanban card per confirmed real issue, and records a reviewed-through
  checkpoint. Use when asked to "do the sec-review-later pass", "review the
  security-flagged commits", "audit the [sec-review-later] backlog", "run the
  deferred security review", or after a security-sensitive sprint lands on main.
---

# sec-review-later — deferred security-review fan-out

Security-sensitive PRs land on fold's `main` with their title prefixed
`[sec-review-later]` (the `app-security-model-pr` routine instructs workers to
tag them; see `feedback`/`project` memory on the app-platform program). The
*review itself* was, until this skill, done by hand each sprint: spawn 4–6
"senior security reviewer" agents, each with a hand-written prompt naming the
sprint, the PR list, a git range, the primary files, and a per-dimension
adversarial hunt list. This skill codifies that fan-out.

This is **read + review + file-cards**, NOT a code-fixer. It produces confirmed
findings and kanban cards; the `kanban-pickup` → `kanban-agent` pipeline
ships the fixes. Never push fixes from this skill.

## What you do NOT duplicate
- `code-review` / built-in `/security-review`: review the *current branch diff*.
  This skill reviews *landed-on-main, flagged* commits across a whole sprint.
- `app-security-model-pr`: *files program cards & tags* PRs for later review.
  This skill *is* the later review.

## Step 0 — discover the backlog

```bash
~/.claude/skills/sec-review-later/scan.sh           # since last checkpoint (or 14d)
~/.claude/skills/sec-review-later/scan.sh --all     # full 30d backlog
~/.claude/skills/sec-review-later/scan.sh --theme app-isolation   # one bucket
```

The digest groups flagged commits into sprint buckets
(`at-rest-encryption`, `app-isolation`, `wasm-transforms`,
`app-identity-uses`, `other`) and prints per bucket: a **review range**
(`<oldest-flagged>^..<newest-flagged>`), the **PR list**, the **commits**, and
the **union of changed files**. The checkpoint lives at
`~/.claude/skills/sec-review-later/.reviewed-through` (a sha); it starts unset,
so the first run shows everything — pick the sprint(s) that landed since the
last human review and scope to them with `--theme` / `--since`.

If asked for a specific sprint, scope to it. Otherwise review the **newest
bucket(s) with commits since the checkpoint** — don't re-review a 30d backlog
that's already been passed over unless asked.

## Step 1 — turn each sprint bucket into review dimensions

For the chosen bucket, read the actual changed files (don't review from the
commit subjects). Decompose the surface into 3–6 **dimensions** — independent
attack surfaces, one reviewer each. Pick dimensions from what the diff touches;
typical sets:

- **at-rest-encryption** → KEY LIFECYCLE (derivation/wrapping/zeroize/rotation);
  AT-REST STORAGE (envelope codec, AAD, nonce reuse, plaintext-fallback, legacy
  sweep); CRYPTO SEAM (Argon2 params floor, SIV/nonce, alloc caps, key-id
  overflow); LOCK/UNLOCK seam (423 node_locked shape, KeyState transitions).
- **app-isolation** → TCP-LOOPBACK OWNER-BYPASS CLOSURE (session-token mint /
  storage / forgeability / constant-time compare / replay; `InProcess` posture
  spoofing); UDS TRANSPORT (socket perms, accept-loop DoS, peer-cred eval, body
  framing/limits, deadline); CALLER ATTESTATION (code-signature posture, header
  spoof); AUTHORIZATION (per-namespace consent ACL chokepoint, fail-closed,
  default-deny, owner-verb gate completeness); REMOTE/DISCOVERY (isolated-ns
  export exclusion, DNS-rebinding / host-header, inbound data_share write
  confinement + envelope replay/expiry).
- **wasm-transforms** → GUEST MEMORY SAFETY (OOB ptr/len, linear-memory cap,
  module-size + cache bounds, panic→error); ABI/ERROR CONTRACT (fail-closed
  when wasm gated off); REGISTRY RESOLUTION (content-hash trust, unresolvable
  hash fails closed); CLASSIFICATION ENFORCEMENT (MEASURED/NMI tier enforced at
  query time on cross-app reads).
- **app-identity-uses** → CAPABILITY/`[uses]` SCOPING (granted cross-app output
  only, raw source denied); REVOCATION (revoke drops output, fail-closed on
  corrupt ledger row, revoke→re-grant restores); PRINCIPAL ISOLATION (scoped
  per-app principal denied owner secrets/verbs, no owner short-circuit);
  KILL-SWITCH (`APP_IDENTITY_ENFORCE` is not an isolation bypass).

## Step 2 — fan out one reviewer per dimension (Workflow)

Use a `Workflow` to run the reviewers in parallel and adversarially verify their
findings. Each reviewer gets the canonical prompt shape (this is the
hand-authored prompt, parameterized):

> You are a senior security reviewer auditing the EdgeVector **`<bucket>`**
> sprint flagged `[sec-review-later]`. Your dimension: **`<DIMENSION>`**.
> Repo: `/Users/tomtang/code/edgevector/fold` (cd there; cargo workspace).
> Review range: `<range from digest>`. PRs: `<pr list>`.
> PRIMARY FILES (read the full current file AND the diff): `<files for this dimension>`.
> HUNT FOR (adversarial — assume a hostile local process / malicious peer):
> `<dimension-specific hazard list — forgeable tokens, default-allow paths,
> spoofable postures, replay, nonce reuse, panics-as-DoS, fail-open on error,
> bypass routes that skip the gate>`.
> For EACH finding: SEVERITY (crit/high/med/low) / TITLE / LOCATION file:line /
> WHAT / IMPACT-EXPLOIT (concrete attacker steps) / FIX SKETCH. If you find
> nothing real in your dimension, say so explicitly — do not invent findings.

Then **adversarially verify** each finding with a second agent prompted to
*refute* it (is the cited line actually reachable over the claimed transport? is
there already a guard upstream? default to "not a real finding" if uncertain).
Drop findings the verifier refutes. This mirrors the review→verify pattern and
keeps plausible-but-wrong findings out of the board.

A ready-to-run workflow scaffold is at
`~/.claude/skills/sec-review-later/review-workflow.js` — read it, fill in the
bucket/range/PRs/dimensions from the digest, and run it with
`Workflow({scriptPath: ".../review-workflow.js"})`.

## Step 3 — file a card per confirmed finding

For each verified finding, file a kanban card (use the `kanban` skill / CLI)
so the fix pipeline picks it up:

```bash
cd ~/code/edgevector/kanban
bun run src/cli.ts add <slug> --title "[sec] <short title>" --column todo \
  --tags fold,security,sec-review-later \
  --body "$(cat <bodyfile>)"
```

Card body must be COLD-agent-ready (the kanban-agent worker has no context):
`Repo:`/`Base:`/`Branch:` header lines, the kanban-agent trigger header, and a
GOAL / CONTEXT(file:line) / STEPS / VERIFY / DONE-WHEN / OUT-OF-SCOPE spec.
Instruct the worker to prefix its PR title `[sec-review-later] ` so the fix
itself rounds back into the next pass. Don't blind-overwrite an existing card
(`add --body` REPLACES the whole body — dump+concat first). If a finding is
crit/high, say so in the title and tag `needs-human` rather than auto-queuing a
risky fix.

If the whole bucket comes back clean, file nothing.

## Step 4 — record the checkpoint + report

Mark everything reviewed so the next run starts from here:

```bash
~/.claude/skills/sec-review-later/scan.sh --mark origin/main
```

(Only `--mark` after you actually reviewed through `origin/main`; if you scoped
to one older bucket, don't advance past unreviewed newer commits — re-run scan
to confirm what's left.)

Then report: buckets reviewed, dimensions run, confirmed findings (severity +
title + card slug), refuted/dropped findings, and the new checkpoint sha.

## Notes
- Read `origin/main` truth: `git fetch origin -q` first (scan.sh does this).
- Don't touch the primary LastDB brain (Tom's brain) or push anything; this is review-only.
- Scope the fleet to the sprint: a small fix sprint → 3 reviewers, single-vote
  verify; a large/crit one (the tcp-loopback closure) → 5–6 reviewers, 2–3 vote
  adversarial verify.
