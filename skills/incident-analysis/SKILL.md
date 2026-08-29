---
name: incident-analysis
description: |
  Explain what happened in an incident with an evidence-backed Five Whys
  analysis. Use for "what happened," "incident analysis," "incident review,"
  "postmortem," "root cause analysis," "failure analysis," "five whys," or
  "5 whys" requests. Use another skill for a recovery-only request that does
  not ask for analysis.
allowed-tools:
  - Bash
  - Read
  - Grep
---

# incident-analysis — explain what happened

Produce a factual causal account. Do not start from a preferred cause. Do not
force the evidence to support one simple chain.

## Scope and authority

- Treat the request as analysis unless the user also asks for containment or repair.
- Read live state when it is in scope and safe to read.
- Respect active Situations fences and the workspace rules.
- Do not restart a shared service or change live state without authority.
- Follow the workspace policy for Brain and board writes.
- Mask secrets in commands, evidence, and the report.

Containment can stop current harm. It does not prove or correct the root cause.

## Procedure

### 1. Frame the incident

State these facts before the causal analysis:

- The failed result or wrong behavior.
- The impact and affected scope.
- The start time, end time, and current status.
- The exact signal that exposed the incident.
- The known unknowns.

Use a time zone for every timestamp. Use `Unknown` when the evidence does not
provide a fact.

### 2. Check prior context

For a shared operational system, check the current posture first:

```bash
situations list --json
situations notices --since 1h
```

A notice can explain expected fallout. A notice does not prove the cause of a
new symptom.

If Brain is available, search for the exact failure signature first:

```bash
brain ask "<failure signature and affected component>"
brain get <useful-slug>
```

Do not use `brain list` as a census. Treat a prior report as a lead until
current evidence confirms it.

### 3. Build the evidence set and timeline

Collect direct evidence from the incident window:

- Logs with timestamps and request or run identifiers.
- Metrics before, during, and after the incident.
- Relevant code, configuration, and recent changes.
- User-visible errors and failed checks.
- Recovery actions and their observed results.

Assign each item an evidence identifier, such as `E1`. Record its source and
timestamp. Separate an observation from an inference.

A comment, document, or previous diagnosis is a claim. Confirm it with current
code or a direct measurement.

For each proposed cause, ask this question:

> Would this evidence look different if the cause were false?

If the answer is no, the evidence does not test that cause.

### 4. Write the Five Whys chain

Write exactly five numbered why entries. Each entry must contain:

- **Question:** Why did the previous verified event occur?
- **Answer:** A mechanism, or `Unknown`.
- **Evidence:** One or more evidence identifiers.
- **Confidence:** `confirmed`, `supported`, or `unknown`.
- **Disproof:** An observation that would make the answer false.

The answer to one why must become the subject of the next why. Do not write
five versions of the original symptom.

If one link is unknown, stop the causal claim at that link. For later entries,
state which evidence must exist before the analysis can continue. Do not invent
an answer to complete the count.

Use a separate Five Whys chain for each independent causal branch. Do not merge
two branches into one answer.

### 5. Name each cause layer

Separate these parts:

- **Trigger:** The event that started the failure.
- **Root cause:** The system condition that made the failure possible.
- **Contributing factors:** Conditions that increased the impact or duration.
- **Detection gap:** The reason the system did not detect the problem sooner.
- **Response gap:** The reason containment or recovery took too long.
- **Non-causes:** Plausible causes that the evidence disproved.

Do not use `human error` as the root cause. Name the missing control, unsafe
interface, weak process, or system condition that allowed the action to cause harm.

Write `Root cause: unknown` when the verified chain does not reach a root cause.

### 6. Map corrective actions

Map each action to a verified cause or gap:

| Cause or gap | Action | Owner | Proof | Status |
|---|---|---|---|---|
| `<verified cause>` | `<specific change>` | `<owner or unknown>` | `<test or live signal>` | `proposed` |

Prefer a producer-side prevention for the root cause. Add detection and recovery
actions only for the gaps they address.

Do not claim that an action fixed the incident until its proof passes. If the
user asks to land the permanent repair, use the `fix-it` skill after this analysis.

## Required report

Use this report shape:

```markdown
# Incident analysis: <title>

## Verdict
<One sentence. State the cause and confidence, or state that the cause is unknown.>

## Impact and status
- Impact: <who or what was affected>
- Window: <start to end, with time zone>
- Status: <active, contained, or resolved>

## Timeline
| Time | Observation | Evidence |
|---|---|---|
| <time> | <direct observation> | E1 |

## Five Whys

### Why 1
- Question:
- Answer:
- Evidence:
- Confidence:
- Disproof:

### Why 2
- Question:
- Answer:
- Evidence:
- Confidence:
- Disproof:

### Why 3
- Question:
- Answer:
- Evidence:
- Confidence:
- Disproof:

### Why 4
- Question:
- Answer:
- Evidence:
- Confidence:
- Disproof:

### Why 5
- Question:
- Answer:
- Evidence:
- Confidence:
- Disproof:

## Root cause and contributors
- Trigger:
- Root cause:
- Contributing factors:
- Detection gap:
- Response gap:
- Non-causes:

## Corrective actions
| Cause or gap | Action | Owner | Proof | Status |
|---|---|---|---|---|

## Unknowns
- <unanswered question and the evidence needed>

## Evidence
- E1 — <source, timestamp, and relevant result>
```

## Quality gate

Before delivery, confirm each condition:

- Each causal claim cites evidence or carries the `supported` or `unknown` label.
- The timeline uses one stated time zone.
- Each why asks about the previous answer.
- The root cause explains the observed scope and important exceptions.
- The report separates the trigger, root cause, contributors, and gaps.
- Each action maps to a verified cause or gap.
- The verdict names conflicts and unknowns.
- The report contains no secret value.

If a condition fails, correct the report or state the limitation. Do not present
an unsupported chain as a completed root-cause analysis.
