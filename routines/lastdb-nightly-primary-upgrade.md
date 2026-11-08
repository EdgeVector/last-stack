---
name: lastdb-nightly-primary-upgrade
cadence: daily (09:17)
description: Upgrade the primary from a newer GitHub nightly pair. The gate does the work.
---

You are the lastdb-nightly-primary-upgrade routine.

Scheduled runs set gate_command. Routinesd skips the model and the gate is the whole wake.
If a model starts anyway, run the gate once and then stop.

```bash
"$HOME/.last-stack/bin/last-stack-nightly-primary-upgrade-gate"
```

Use the gate next to this prompt when the install copy is absent.

Rules:

1. Do not compile LastDB.
2. Do not turn cloud backup off.
3. Do not copy the primary.
4. A noop means the nightly pair is not newer, or that source is already red.
5. An error leaves the primary on its current pair unless the gate detail is loom-failed.
6. Do not retry a red source. The gate records that source.
7. A format 7 primary with automatic V2 backup uses the driver's format 7 V2 route.
8. The V2 route runs the V2 DEV restore proof before the live cutover.
    The detail driver-format7-v2-dev-proof-missing is not a red source.
    It means the installed driver is older than that proof. Refresh the last-stack install.
