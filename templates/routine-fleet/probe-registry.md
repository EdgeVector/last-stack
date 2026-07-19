---
type: project
slug: probe-registry
title: Probe Registry - <PROJECT_NAME>
status: active
tags: index, driving-layer, probes, portability
---
# Probe Registry - <PROJECT_NAME>

Registry of continuous sentinel recipes. Each scheduled probe routine should be
a thin trigger: read this registry, run one named entry, write a verdict, file
deduped cards when the assertion fails. Probe knowledge lives here so the
routine prompt and engine skill stay generic.

## Entry schema

<!-- Stable entry name used by the scheduled trigger. -->
### `<PROBE_NAME>` - cadence: `<CADENCE>` - verdict: `<VERDICT_RECORD_SLUG_OR_NONE>`

<!-- What user/product/system invariant this probe protects. -->
- **purpose**: `<ONE_SENTENCE_INVARIANT>`

<!-- Exact harness command, script path, or manual API sequence. Use placeholders
for project paths and never embed secrets. -->
- **harness**: `<COMMAND_OR_SCRIPT_RECIPE>`

<!-- Boolean assertion that makes the probe pass. Be explicit enough that an
agent cannot treat a partial run as green. -->
- **pass_assertion**: `<PASS_CONDITION>`

<!-- Where the probe may run. Use throwaway/dev/staging unless a human explicitly
authorizes production. -->
- **isolation**: `<THROWAWAY_OR_DEV_SURFACE>`

<!-- What to write when the probe completes. Use "none" for report-only probes. -->
- **verdict_record**: `<VERDICT_RECORD_SLUG_OR_NONE>`

<!-- How the routine should classify partial or timeboxed probe legs. A bounded
finding that is filed or already tracked is successful probe output, not a
routine harness failure. -->
- **result_classification**: `ok when findings are filed/tracked; noop when
  findings are known duplicates or external dependencies are unavailable; error
  only when the probe cannot preserve evidence, teardown, or heartbeat`

<!-- How to format the newest-on-top verdict line. -->
- **verdict_line_format**: `<ISO_TS> <GREEN_OR_RED> <KEY_METRICS> run=<RUN_ID>`

<!-- Where filed cards should point. Repo values must appear in repo-venue-map. -->
- **card_target**: `Repo: <OWNER>/<REPO>; Base: <BASE_BRANCH>; tags: <TAGS>; priority: <P_LEVEL>`

<!-- How to collapse repeated findings and avoid filing duplicate cards. -->
- **dedupe**: `<BOARD_SEARCH>, <OPEN_PR_SEARCH>, <LEDGER_OR_VERDICT_CHECK>`

<!-- Exact board filing contract. Include standalone structured headers in the
card body and use the current board CLI flags so pickup-readiness can parse the
card without repair. -->
- **card_filing**: `pipe Markdown body on stdin; include standalone Repo:
  <OWNER>/<REPO> and Base: <BASE_BRANCH> lines near the top; pass --repo
  <OWNER>/<REPO> --base <BASE_BRANCH> --kind pr --tags comma,separated`

<!-- Cleanup that always runs, especially for throwaway processes and data dirs. -->
- **teardown**: `<TEARDOWN_STEPS>`

<!-- Known reasons to skip without filing a product bug. -->
- **skip_policy**: `<NOOP_CONDITIONS>`

## Example entry

### `<PROBE_NAME>` - cadence: `<EVERY_6H>` - verdict: `<PROBE_VERDICT_SLUG>`

- **purpose**: `<PROBE_PROTECTS_THIS_INVARIANT>`
- **harness**: `<PATH_TO_SCRIPT> --workspace <WORKSPACE_ROOT> --json`
- **pass_assertion**: `exit=0 and findings=0 and required_leg=<PASS>`
- **isolation**: `throwaway data dir under <TMP_DIR>; never <PRIMARY_DATA_DIR>`
- **verdict_record**: `<PROBE_VERDICT_SLUG>`
- **verdict_line_format**: `<ISO_TS> <GREEN|RED> findings=<N> errors=<N> run=<RUN_ID>`
- **result_classification**: `ok when this run files or updates a card for a
  real finding; noop when an existing live card already tracks the same finding;
  error only for probe/harness failure before evidence and heartbeat`
- **card_target**: `Repo: <OWNER>/<REPO>; Base: main; tags: probes,<TAG>; priority: P1`
- **dedupe**: `search board for <FINDING_CATEGORY>; search open PRs for <AREA>; check last <N> verdicts`
- **card_filing**: `body begins with Repo: <OWNER>/<REPO> and Base: main;
  fkanban add <slug> --column todo --repo <OWNER>/<REPO> --base main --kind pr
  --tags probes,<TAG>`
- **teardown**: `stop process <PID_FILE>; remove <TMP_DIR>`
- **skip_policy**: `dependency unavailable, missing credentials, or dev surface down -> heartbeat noop`

## Registry invariants

- A probe never falls back from a throwaway/dev surface to production.
- A probe kills only processes it started and names by PID/socket/home.
- Findings file work; probe routines do not ship product fixes directly.
- Verdict records are honest: partial or skipped runs are not green.
- Timeboxed probe legs that preserve evidence and file or identify a live card
  are `ok` or `noop` routine outcomes. Reserve `error` for probe failures that
  prevent evidence capture, teardown, or the final heartbeat.
- Filed board cards must be pickup-ready at creation time: structured `Repo:`
  and `Base:` body headers plus matching `--repo`, `--base`, `--kind`, and
  comma-separated `--tags` CLI metadata.
