---
type: reference
slug: signal-sources
title: Signal Sources - <PROJECT_NAME>
status: active
tags: routines, portability, config, signals
---
# Signal Sources - <PROJECT_NAME>

External error, usage, and alert feeds consumed by triage and briefing routines.
Keep raw credentials out of this record; store only secret locators and
non-secret routing policy.

## Source template

<!-- Stable source name. Examples: sentry, posthog, datadog, stripe, pagerduty. -->
### `<SOURCE_NAME>`

<!-- API base URL or console URL. -->
- **api_url**: `<SOURCE_API_URL>`

<!-- Secret locator only. Example: lastsecrets://sentry-read-token. -->
- **auth_ref**: `<SOURCE_AUTH_SECRET_REF>`

<!-- Projects, apps, services, environments, or datasets to scan. -->
- **scopes**: `<SOURCE_SCOPE_1>, <SOURCE_SCOPE_2>`

<!-- Which severities, volume thresholds, environments, or freshness windows
should produce work. -->
- **triage_policy**: `<TRIAGE_POLICY>`

<!-- Repo routing for issues from this source. Values must appear in
repo-venue-map. -->
- **repo_mapping**: `<SOURCE_SCOPE_OR_PATTERN> -> <OWNER>/<REPO>`

<!-- Ledger record used to avoid duplicate filings. Use "none" only if the
source has its own durable dedupe. -->
- **dedupe_ledger**: `<LEDGER_SLUG_OR_NONE>`

<!-- Known noisy issues to suppress. Include the reason and expiry when possible. -->
- **ignore_policy**: `<IGNORE_RULES>`

<!-- Exact command or API query a routine should use. Keep it non-secret. -->
- **read_recipe**: `<NON_SECRET_COMMAND_OR_QUERY>`

## Example

### sentry

- **api_url**: `<SENTRY_API_URL>`
- **auth_ref**: `<SENTRY_TOKEN_REF>`
- **scopes**: `<SENTRY_ORG>/<SENTRY_PROJECT_1>, <SENTRY_ORG>/<SENTRY_PROJECT_2>`
- **triage_policy**: `fresh <FRESHNESS_WINDOW>, severity >= <MIN_SEVERITY>, events >= <MIN_EVENT_COUNT>`
- **repo_mapping**: `<SENTRY_PROJECT_1> -> <OWNER>/<REPO>`
- **dedupe_ledger**: `<SENTRY_LEDGER_SLUG>`
- **ignore_policy**: `<PROJECT_OR_ISSUE_TO_IGNORE> until <DATE_OR_CONDITION>`
- **read_recipe**: `curl <SENTRY_API_URL>/projects/<ORG>/<PROJECT>/issues/?statsPeriod=<WINDOW>`

## Validation

- Every `auth_ref` is a secret locator, not a raw token.
- Every mapped repo appears in `repo-venue-map`.
- Every source has a dedupe ledger or a documented source-native dedupe key.
