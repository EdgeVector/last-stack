---
name: fkanban-grooming
description: Compatibility shim for old fkanban-grooming prompts. Use the kanban-grooming skill for current board grooming guidance.
---

# fkanban-grooming compatibility

`fkanban-grooming` was renamed to `kanban-grooming`.

For dependency-stub reconciliation, malformed header cleanup, review/doing lane
hygiene, and pickup-readiness accounting, use the `kanban-grooming` skill. New
prompts should say `kanban-grooming`; this file exists so older automations that
still request `fkanban-grooming` resolve to a real skill file after setup.
