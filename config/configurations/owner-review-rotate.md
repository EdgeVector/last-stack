# Owner Review Rotation — EdgeVector

Project configuration for the `owner-review-rotate` thin trigger. This document
is the authoritative registry; Brain charters remain the source of purpose and
rationale, not registry membership.

- **schedule**: daily at 08:45 local
- **charter_sections**: `Owns`, `Purpose`, `Invariants`, `Open papercuts`
- **papercut_sources**: charter `Open papercuts` plus bounded `brain search`
  discovery; every candidate is confirmed with `brain get`
- **excluded_self_reviewing_charters**: `owner-lastdb-operations`,
  `owner-lastdb-cloud-sync`, `owner-lastdb-data-lifecycle`
- **log_record**: `owner-review-rotate-log`
- **timebox**: 20 minutes for the selected owner

## Recipe: owner-review

Run this recipe with the selected entry's `area`, `charter`, `repos`, and
`owned_paths` fields.

1. Read `sop-routine-shared-contract`, then point-read `charter` and read its
   configured `Owns`, `Purpose`, `Invariants`, and `Open papercuts` sections.
2. Build a bounded candidate set from `papercut-*` slugs in `Open papercuts`
   and recent charter appendices. Add discovery samples from
   `brain search "owner:<area>" --type papercut` and
   `brain search "papercut owner <area>" --type papercut`. Never issue a
   whole-type enumeration for owner or papercut membership.
3. Point-read every candidate with `brain get <slug>`. Keep only open records
   owned by the selected area or still explicitly listed by the charter.
4. Inspect the actual configured repo/path surface before judging a finding.
   Classify each reached candidate exactly once: FIX (enrich or file one
   deduped pickup-ready card), CLOSE (archive with verified rationale), or
   ESCALATE (retag and append the routing reason). Papercut records stay in
   Brain; never file a papercut card directly.
5. Append a targeted last-reviewed note to the charter and one summary line to
   `owner-review-rotate-log`. Stop opening candidates after the timebox and log
   the remainder for the next rotation.

`pass =` the selected charter and real owned code were read, every reached
candidate has one recorded outcome, the charter/log were advanced, and the run
used zero whole-type Brain enumeration calls.

### owner-fold
track: repository owner review
area: fold
charter: owner-fold
repos: EdgeVector/fold
owned_paths: lastdb_node/, lastdb_host/, lastdb_identity/, lastdb_uds/, fold_db/, schema_service/, exemem_service/, app_identity_crypto/, lastdb_app_sdk/, apps/, folddb_profile/
cadence: 1d
recipe: owner-review
isolation: read current code only; never mutate primary LastDB data or a live worktree

### owner-fkanban
track: repository owner review
area: fkanban
charter: owner-fkanban
repos: EdgeVector/fkanban
owned_paths: bin/, src/, vendor/, fkanban.app.json
cadence: 1d
recipe: owner-review
isolation: read current code only; never mutate primary LastDB data or a live worktree

### owner-routines
track: repository owner review
area: routines
charter: owner-routines
repos: EdgeVector/routines
owned_paths: bin/, src/, scripts/
cadence: 1d
recipe: owner-review
isolation: read current code only; never mutate primary LastDB data or a live worktree

### owner-last-stack
track: repository owner review
area: last-stack
charter: owner-last-stack
repos: EdgeVector/last-stack
owned_paths: bin/, hooks/, instructions/, routines/, setup/, skills/, templates/
cadence: 1d
recipe: owner-review
isolation: read current code only; never mutate primary LastDB data or a live worktree

### owner-lastgit
track: repository owner review
area: lastgit
charter: owner-lastgit
repos: EdgeVector/lastgit
owned_paths: bin/, src/, vendor/
cadence: 1d
recipe: owner-review
isolation: read current code only; never mutate primary LastDB data or a live worktree

### owner-exemem
track: repository owner review
area: exemem
charter: owner-exemem
repos: EdgeVector/exemem-workspace, EdgeVector/exemem-infra
owned_paths: apps/, autoresearch-ingestion/, config/, cdk/, lambdas/, scripts/
cadence: 1d
recipe: owner-review
isolation: read current code only; never mutate primary LastDB data or a live worktree

### owner-dogfood-infra
track: domain owner review
area: dogfood-infra
charter: owner-dogfood-infra
repos: EdgeVector/last-stack
owned_paths: dogfood/smoke scripts, machine-hygiene, rotation registries
cadence: 1d
recipe: owner-review
isolation: read current code only; never mutate primary LastDB data or a live worktree

### owner-agent-harness
track: domain owner review
area: agent-harness
charter: owner-agent-harness
repos: EdgeVector/last-stack
owned_paths: setup/, bin/, hooks/
cadence: 1d
recipe: owner-review
isolation: read current code only; never mutate primary LastDB data or a live worktree

### owner-fold-ci
track: domain owner review
area: fold-ci
charter: owner-fold-ci
repos: EdgeVector/fold
owned_paths: CI, Forgejo Actions, runners, build cache, ci-required gate
cadence: 1d
recipe: owner-review
isolation: read current code only; never mutate primary LastDB data or a live worktree

### owner-fbrain
track: domain owner review
area: fbrain
charter: owner-fbrain
repos: EdgeVector/brain, EdgeVector/fold
owned_paths: brain CLI/MCP, schema registry, socket transport
cadence: 1d
recipe: owner-review
isolation: read current code only; never mutate primary LastDB data or a live worktree

### owner-lastdb-desktop
track: domain owner review
area: lastdb-desktop
charter: owner-lastdb-desktop
repos: EdgeVector/fold
owned_paths: embedded node, onboarding, release gate, telemetry, desktop UI
cadence: 1d
recipe: owner-review
isolation: read current code only; never mutate primary LastDB data or a live worktree

### owner-unassigned
track: unassigned papercut review
area: unassigned
charter: owner-unassigned
repos: resolved from the owner routing fields above
owned_paths: unassigned or untagged candidate papercuts only
cadence: 1d
recipe: owner-review
isolation: read current code only; never mutate primary LastDB data or a live worktree

<!-- rotation-log:start | auto-maintained by owner-review-rotate -->
| feature | last_run | result | cards filed |
|---|---|---|---|
| owner-fold | never | -- | -- |
| owner-fkanban | never | -- | -- |
| owner-routines | never | -- | -- |
| owner-last-stack | never | -- | -- |
| owner-lastgit | never | -- | -- |
| owner-exemem | never | -- | -- |
| owner-dogfood-infra | never | -- | -- |
| owner-agent-harness | never | -- | -- |
| owner-fold-ci | never | -- | -- |
| owner-fbrain | never | -- | -- |
| owner-lastdb-desktop | never | -- | -- |
| owner-unassigned | never | -- | -- |
<!-- rotation-log:end -->
