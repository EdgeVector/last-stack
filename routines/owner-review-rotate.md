---
name: owner-review-rotate
cadence: daily (08:45 local)
description: Thin trigger for the Config-backed owner review registry
---

Run the `registry-rotator` skill with these inputs:

- `registry=configurations://owner-review-rotate`
- `routine=owner-review-rotate`
- `mode=run`

The Config document is authoritative for the owner set, per-owner cadence,
charter sections, discovery sources, exclusions, recipe, and rotation log. Read
it with `configurations get owner-review-rotate --json`; do not fall back to a
same-named or legacy Brain roster.

Honor `sop-routine-shared-contract`. The rotator owns selection, recipe
dispatch, log stamping, close-out, and the final heartbeat.
