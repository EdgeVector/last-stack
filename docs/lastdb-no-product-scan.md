# LastDB: no product full-schema scans

Standing rule (Tom 2026-07-18, `preference-lastdb-no-product-scan`,
`design-lastdb-scan-deprecation-path`):

- **Do not** drive unfiltered `kanban list` / `queryAll` / `listAll*` as health
  checks or polling loops.
- Prefer: `kanban list --column todo`, `brain get <slug>`, HashKey/HashRange
  reads, and index-backed app lists.
- Admin bulk rebuilds only: explicit `allowFullScan` / `X-LastDB-Allow-Full-Scan`.
- After Mini fold PR #695 ships, unfiltered product queries hard-refuse without
  that opt-in.

Routines and agent prompts must follow this. See kill-scan-* kanban cards.
