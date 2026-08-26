---
name: sentry-triage
cadence: daily
description: Pull unresolved issues from every configured Sentry project, dedupe against the brain ledger and live board, and file actionable kanban cards. Triage-only; never ships fixes.
---

# Sentry Triage Routine

You are running an unattended daily routine in the workspace. Objective: triage
the Sentry error inbox and file kanban cards for real, actionable issues. You
file work onto the board; you do not ship fixes.

Read the shared routine contract first:

```bash
brain get sop-routine-shared-contract --type sop
```

Honor its heartbeat, primary-brain guardrail, file-don't-ship card contract,
dedupe-before-filing, scheduled-shell discipline, and verify-vs-origin-main
rules. If this prompt conflicts with the shared contract, the contract wins.

## Setup

Normalize the scheduled shell:

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude"
"$last_stack/bin/last-stack-cli-preflight" git curl jq brain kanban
```

Read `signal-sources` for the Sentry org/API/auth/projects/ignore-list,
repo-mapping, and ledger config:

```bash
brain get signal-sources --type reference
```

Use the `### sentry` `scopes` line in `signal-sources` as the source of truth
for project slugs. Parse every `edge-vector/<project>` scope from that line; do
not hard-code only `rust` and `javascript-react`. If a project appears in
`signal-sources`, it is in scope unless explicitly excluded by the ignore
policy.

## Step 1 - Pull Unresolved Issues

For each project slug parsed from `signal-sources` Sentry scopes:

```bash
url="https://sentry.io/api/0/projects/edge-vector/<slug>/issues/?query=is:unresolved&statsPeriod=14d&limit=100"
headers_file="/tmp/sentry.headers.$$"
page_file="/tmp/sentry.page.$$"
while [ -n "$url" ]; do
  curl -sS -D "$headers_file" -o "$page_file" \
    -H "Authorization: Bearer $TOKEN" "$url" || true
  # Append this page, then continue only when the Link rel="next" entry has results="true".
  url="$(SENTRY_HEADERS="$headers_file" python3 - <<'PY'
import os
import re
text = open(os.environ["SENTRY_HEADERS"], encoding="utf-8", errors="replace").read()
for line in text.splitlines():
    if not line.lower().startswith("link:"):
        continue
    for part in re.split(r",\s*(?=<)", line.split(":", 1)[1].strip()):
        m = re.match(r"<([^>]+)>\s*;(.*)$", part.strip())
        if m and 'rel="next"' in m.group(2) and 'results="true"' in m.group(2):
            print(m.group(1))
            raise SystemExit
PY
)"
done
rm -f "$headers_file" "$page_file"
```

Valid `statsPeriod` values are only ``, `24h`, and `14d`.
Do not cap triage at the first page; keep following Sentry pagination until the
`next` link reports no further results.

Capture per issue: `id`, `title`, `level`, `count`, `userCount`, `firstSeen`,
`lastSeen`, `permalink`, and `metadata`.

## Step 2 - Drop Noise

Drop Sentry sample events first. Sentry seeds one sample event into every new
project, so each project you add to the `signal-sources` matrix otherwise mints
one bad card. Fetch the latest event and drop the issue when either holds:

- the event has the tag `sample_event` set (authoritative and
  language-independent — prefer this test), or
- the event `message` matches `this is an example` case-insensitively.

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://sentry.io/api/0/organizations/edge-vector/issues/<id>/events/latest/" \
  >/tmp/sentry.latest.$$.json
jq -r '[.tags[]? | select(.key == "sample_event") | .value] | join(",")' \
  /tmp/sentry.latest.$$.json
```

A sample event carries `culprit = ../../sentry/scripts/views.js in poll` and
`url = http://example.com/foo`. Those are corroboration, not the test.

Then exclude any issue whose title or metadata indicates a test or wiring probe:
match case-insensitively on `smoke test`, `synthetic`, `telemetry wiring`,
`DSN validation`, `(ignore)`, and `verification`.

Drop `level:info` and `level:debug` unless volume is high and clearly a real
defect.

Steps 2 and 3 are one decision. Run the helper instead of re-deriving the rules
by hand — it is the executable form of this policy and it is regression-tested
(`tests/last-stack-sentry-triage-classify.sh`):

```bash
"$last_stack/bin/last-stack-sentry-triage-classify" \
  --issue /tmp/sentry.issue.$$.json \
  --latest-event /tmp/sentry.latest.$$.json --json
```

It prints `{"verdict": "drop|P1|P2|P3", "reason": ..., "file": true|false}`.
File the issue only when `file` is true. If the helper is unavailable, apply the
rules below by hand and keep the same order.

## Step 3 - Triage And Prioritize

Evaluate these rules in order per surviving issue. The first rule that matches
wins. Evaluate the suppression rule BEFORE the `P1` rule: a priority ladder that
tests `P1` first can never reach the suppression rule.

1. **Suppress as `P3`, do not file:** `count == 1` and `lastSeen` is older than
   60 days. Exception: file it when the issue indicates a crash, data-loss, or
   corruption risk.
2. **`P1`:** `level` is `error` or `fatal`, and one of `count >= 25`,
   `userCount >= 5`, or `lastSeen` within 24h.
3. **`P2`:** every other surviving `error` or `fatal` issue.
4. **`P3`:** everything else that survived Step 2. Do not file individually.

Do not use `userCount >= 1` as the `P1` volume test. Almost every real issue has
at least one affected user, so that clause makes `P1` match everything and makes
every later rule unreachable. Rules 1 and 2 use measured thresholds instead.

Order P1 before P2. Cap at the top 8 issues per run and note any deferred.

## Step 4 - Dedupe

Check both dedupe guards before filing:

1. Brain ledger: `brain get sentry-triage-ledger --type reference`. Skip any
   issue id already listed.
2. Live board: search every column for `Sentry-Issue: <id>`. Skip if a card
   already exists anywhere.

An issue in the ledger that is still firing weeks later may be a regression;
note it in the report, but do not auto-refile it.

## Step 5 - File Cards

Fetch issue details for trace/culprit when available:

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://sentry.io/api/0/organizations/edge-vector/issues/<id>/"
```

Optionally fetch the latest event for JS stack frames:

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://sentry.io/api/0/organizations/edge-vector/issues/<id>/events/latest/"
```

File one `todo` card per surviving issue. The body must include, in order:

1. `North Star: <slug>`.
2. `Sentry-Issue: <id>` and `Sentry: <permalink>`.
3. Triage details: level, total count, `userCount`, `firstSeen`, `lastSeen`,
   priority.
4. Evidence: exception message, culprit, top stack frames, or title if no
   frames exist.
5. Suggested investigation/fix grounded in the message and repo mapping.
6. VERIFY: re-query this issue after the fix ships and assert recurrence stops,
   plus any unit/regression test.

Use the `repo_mapping` from `signal-sources` to route the card. If no clear
North Star exists, use the canonical fallback `North Star: north-star` and note
that a dedicated reliability North Star may be worth creating.

## Step 6 - Update Ledger

Append one line per issue filed or consciously skipped as noise:

```text
<sentry-issue-id> <ISO-ts> <project> <P1|P2|noise> <card-slug-or-skipped> <short title>
```

Read the full ledger first, prepend new lines under the intro, trim to roughly
300 lines, and write via stdin. Never pass ledger bodies through command-line
arguments.

## Hard Constraints

- No Sentry writes: no resolve, assign, mute, or config changes.
- Dev-only. Never deploy and never touch prod.
- No destructive git operations, process killing, or background agents.
- Brain/board timeouts mean load. Retry bounded idempotent reads/writes; do not
  run doctor/init or restart nodes.
- Idempotent: if every unresolved issue is noise or already deduped, file
  nothing and report clean.

## Heartbeat

Heartbeat last, always:

```bash
sentry-triage <ISO-ts> <ok|noop|error> <one-line outcome>
```

`noop` means a clean run filed nothing. `error` means Sentry API or token access
failed. Include compact per-project unresolved counts, for example:

```text
projects=rust:0,javascript-react:3,lastdb-mini:1
```

## Output

End with:

- Table of every issue triaged: project, level, count, users, lastSeen,
  priority/noise.
- Cards filed: slugs plus Sentry ids.
- Skips: noise, already-on-board, already-in-ledger, or deferred past the cap.
- Any P1 requiring a human config/secret/infra decision.
