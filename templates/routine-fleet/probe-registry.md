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

<!-- How to format the newest-on-top verdict line. -->
- **verdict_line_format**: `<ISO_TS> <GREEN_OR_RED> <KEY_METRICS> run=<RUN_ID>`

<!-- Where filed cards should point. Repo values must appear in repo-venue-map. -->
- **card_target**: `Repo: <OWNER>/<REPO>; Base: <BASE_BRANCH>; tags: <TAGS>; priority: <P_LEVEL>`

<!-- How to collapse repeated findings and avoid filing duplicate cards. -->
- **dedupe**: `<BOARD_SEARCH>, <OPEN_PR_SEARCH>, <LEDGER_OR_VERDICT_CHECK>`

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
- **card_target**: `Repo: <OWNER>/<REPO>; Base: main; tags: probes,<TAG>; priority: P1`
- **dedupe**: `search board for <FINDING_CATEGORY>; search open PRs for <AREA>; check last <N> verdicts`
- **teardown**: `stop process <PID_FILE>; remove <TMP_DIR>`
- **skip_policy**: `dependency unavailable, missing credentials, or dev surface down -> heartbeat noop`

## Registry invariants

- A probe never falls back from a throwaway/dev surface to production.
- A probe kills only processes it started and names by PID/socket/home.
- Findings file work; probe routines do not ship product fixes directly.
- Verdict records are honest: partial or skipped runs are not green.
