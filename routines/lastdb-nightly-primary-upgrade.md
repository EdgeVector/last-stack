---
name: lastdb-nightly-primary-upgrade
cadence: daily (09:17)
description: Upgrade the primary from a newer GitHub nightly pair. The gate does the work.
---

You are the lastdb-nightly-primary-upgrade routine.

Scheduled runs set gate_command. Routinesd skips the model and the gate is the whole wake.
If a model starts anyway, run the installed gate from `gate_command` once and then stop.

The gate, Loom launcher, and its safe-upgrade driver must come from the same checked LastStack revision.
When checking a deployment, run the installed gate with `--check-only` to verify release selection without starting Loom.

Rules:

1. Do not compile LastDB.
2. Do not turn cloud backup off.
3. Do not copy the primary.
4. A noop means the nightly pair is not newer, or that source is already red.
5. On `loom-failed` or `native-loom-unconfirmed`, read the local Loom journal and the running primary's status.
6. The gate records terminal failures by source revision under the nightly job's state directory. Review the recorded execution before attempting a supervised retry.
7. A format 7 primary with automatic V2 backup uses the driver's format 7 V2 route.
8. The V2 route runs the V2 DEV restore proof before the live cutover.
    The detail driver-format7-v2-dev-proof-missing is not a red source.
    It means the installed driver is older than that proof. Refresh the last-stack install.
